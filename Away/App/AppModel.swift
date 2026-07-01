import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class AppModel {
    enum QueuedPromptAttachRetryDecision: Equatable {
        case none
        case schedule(attempt: Int)
        case exhausted
    }

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected:
                "Disconnected"
            case .connecting:
                "Connecting"
            case .connected:
                "Connected"
            case .failed(let message):
                message
            }
        }
    }

    var connectionState: ConnectionState = .disconnected
    var sessions: [SessionSummary] = []
    var activeSessionID: String?
    var messagesBySession: [String: [ChatMessage]] = [:]
    var earlierMessagesBySession: [String: [ChatMessage]] = [:]
    var runtimeBySession: [String: SessionRuntime] = [:]
    var draftBySession: [String: String] = [:]
    var scenePhase: ScenePhase = .active
    var demoBackgroundKeepaliveEnabled = false
    var errorMessage: String?

    @ObservationIgnored private var client: ACPClient?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?
    @ObservationIgnored private var notificationFlushTask: Task<Void, Never>?
    @ObservationIgnored private var pendingNotifications: [ACPNotification] = []
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var liveRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var openSessionTokens: [String: UUID] = [:]
    @ObservationIgnored private var queuedPromptsBySession: [String: [QueuedPrompt]] = [:]
    @ObservationIgnored private var drainingQueuedPromptSessionIDs: Set<String> = []
    @ObservationIgnored private var queuedPromptDrainRetrySessionIDs: Set<String> = []
    @ObservationIgnored private var queuedPromptAttachRetrySessionIDs: Set<String> = []
    @ObservationIgnored private var queuedPromptAttachRetryAttemptsBySession: [String: Int] = [:]
    @ObservationIgnored private var silentReplaySessionIDs: Set<String> = []
    @ObservationIgnored private var outboundPromptSessionIDs: Set<String> = []
    @ObservationIgnored private var locallyStartedRunSessionIDs: Set<String> = []
    @ObservationIgnored private var shortBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var lastNotifiedMessageIDs: Set<String> = []
    @ObservationIgnored private let connectionConfig: RemoteConnectionConfig
    @ObservationIgnored private let notificationCoordinator = NotificationCoordinator.shared
    @ObservationIgnored private let backgroundKeepalive = DemoBackgroundKeepaliveService()
    @ObservationIgnored private let exportTailMessageLimit = 16
    @ObservationIgnored private let loadDelay = Duration.milliseconds(450)
    @ObservationIgnored private let liveRefreshInterval = Duration.seconds(2)
    @ObservationIgnored private let maxQueuedPromptAttachRetryAttempts = 3

    init(connectionConfig: RemoteConnectionConfig = .demo) {
        self.connectionConfig = connectionConfig
        self.demoBackgroundKeepaliveEnabled = connectionConfig.demoBackgroundKeepaliveEnabled
    }

    var activeSession: SessionSummary? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    func start() async {
        guard client == nil else { return }
        if demoBackgroundKeepaliveEnabled {
            backgroundKeepalive.start()
        }
        await notificationCoordinator.requestAuthorization()
        await connect()
    }

    func stop() async {
        backgroundKeepalive.stop()
        endShortBackgroundTask()
        cancelLiveRefreshLoop()
        connectionTask?.cancel()
        connectionTask = nil
        await closeCurrentClient()
        connectionState = .disconnected
    }

    func updateScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
        switch phase {
        case .active:
            endShortBackgroundTask()
            Task {
                if connectionState == .connected {
                    await refreshSessions()
                    if connectionState != .connected {
                        await connect()
                    }
                } else {
                    await connect()
                }
                if connectionState == .connected, let activeSessionID {
                    await openSession(activeSessionID)
                }
                startLiveRefreshLoopIfNeeded()
            }
        case .background:
            cancelLiveRefreshLoop()
            beginShortBackgroundTask()
        default:
            break
        }
    }

    func connect() async {
        if let connectionTask {
            await connectionTask.value
            return
        }

        let task = Task { @MainActor in
            await performConnect()
        }
        connectionTask = task
        await task.value
        connectionTask = nil
    }

    private func performConnect() async {
        await closeCurrentClient()
        connectionState = .connecting
        errorMessage = nil

        do {
            let transport = try RemoteConnectionProvider().makeTransport(config: connectionConfig)
            let client = ACPClient(transport: transport)
            self.client = client
            observeNotifications(from: client)
            try await client.connect()
            connectionState = .connected
            await refreshSessions()
            startLiveRefreshLoopIfNeeded()
        } catch {
            connectionState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            await closeCurrentClient()
        }
    }

    func refreshSessions() async {
        guard let client else {
            await connect()
            return
        }

        do {
            let listed = try await client.listSessions()
            publish(listedSessions: listed)
            errorMessage = nil
            connectionState = .connected
        } catch {
            connectionState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            await closeCurrentClient()
        }
    }

    private func refreshSessionsForLiveRefresh() async -> Bool {
        guard let client else { return false }

        do {
            let listed = try await client.listSessions()
            publish(listedSessions: listed)
            errorMessage = nil
            connectionState = .connected
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func publish(listedSessions: [SessionSummary]) {
        let archivedSessionIDs = Set(listedSessions.compactMap { session in
            session.archivedAt == nil ? nil : session.id
        })
        clearStateForArchivedSessions(archivedSessionIDs)
        let activeSessions = listedSessions.filter { $0.archivedAt == nil }
        let currentSessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let merged = activeSessions.map { listed in
            var session = listed
            let runtime = runtimeBySession[session.id]
            let hasLocalActivity = runtime?.activeRunID != nil
                || runtime?.streamingMessageID != nil
                || outboundPromptSessionIDs.contains(session.id)
            if hasLocalActivity, let current = currentSessionsByID[session.id] {
                session.subtitle = current.subtitle ?? session.subtitle
                session.updatedAt = later(current.updatedAt, session.updatedAt)
                session.lastMessageAt = later(current.lastMessageAt, session.lastMessageAt)
            }
            if runtime?.activeRunID != nil {
                session.isWorking = true
            }
            return session
        }
        sessions = merged.sorted(by: SessionSummary.isMoreRecent)
    }

    private func clearStateForArchivedSessions(_ sessionIDs: Set<String>) {
        guard !sessionIDs.isEmpty else { return }

        for sessionID in sessionIDs {
            runtimeBySession.removeValue(forKey: sessionID)
            messagesBySession.removeValue(forKey: sessionID)
            earlierMessagesBySession.removeValue(forKey: sessionID)
            draftBySession.removeValue(forKey: sessionID)
            queuedPromptsBySession.removeValue(forKey: sessionID)
            openSessionTokens.removeValue(forKey: sessionID)
            queuedPromptAttachRetrySessionIDs.remove(sessionID)
            queuedPromptAttachRetryAttemptsBySession.removeValue(forKey: sessionID)
            drainingQueuedPromptSessionIDs.remove(sessionID)
            queuedPromptDrainRetrySessionIDs.remove(sessionID)
            silentReplaySessionIDs.remove(sessionID)
            outboundPromptSessionIDs.remove(sessionID)
            locallyStartedRunSessionIDs.remove(sessionID)
        }
        pendingNotifications.removeAll { sessionIDs.contains($0.sessionID) }

        if let activeSessionID, sessionIDs.contains(activeSessionID) {
            self.activeSessionID = nil
        }
    }

    private func later(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case (.some(let left), .some(let right)):
            return max(left, right)
        case (.some(let left), .none):
            return left
        case (.none, .some(let right)):
            return right
        case (.none, .none):
            return nil
        }
    }

    private func startLiveRefreshLoopIfNeeded() {
        guard liveRefreshTask == nil, scenePhase == .active else { return }

        let interval = liveRefreshInterval
        liveRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                await self.performLiveRefreshTick()
            }
        }
    }

    private func cancelLiveRefreshLoop() {
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
    }

    private func performLiveRefreshTick() async {
        guard scenePhase == .active,
              connectionState == .connected,
              client != nil
        else {
            return
        }

        guard await refreshSessionsForLiveRefresh() else { return }
        await refreshActiveSessionTranscriptIfNeeded()
    }

    private func refreshActiveSessionTranscriptIfNeeded() async {
        guard let sessionID = activeSessionID,
              let client,
              scenePhase == .active,
              connectionState == .connected,
              !silentReplaySessionIDs.contains(sessionID),
              !outboundPromptSessionIDs.contains(sessionID),
              !locallyStartedRunSessionIDs.contains(sessionID)
        else {
            return
        }

        let runtime = runtimeBySession[sessionID]
        guard runtime?.isOpening != true,
              runtime?.isReplaying != true,
              runtime?.hasAuthoritativeReplay == true || messagesBySession[sessionID]?.isEmpty == false
        else {
            return
        }

        silentReplaySessionIDs.insert(sessionID)
        do {
            let cwd = sessions.first(where: { $0.id == sessionID })?.cwd
            try await client.loadSession(sessionID: sessionID, cwd: cwd ?? connectionConfig.defaultCWD)
            silentReplaySessionIDs.remove(sessionID)
            guard activeSessionID == sessionID else {
                dropPendingNotifications(for: sessionID)
                return
            }
            flushPendingNotifications(authoritativeReplaySessionID: sessionID)
            runtimeBySession[sessionID, default: SessionRuntime()].errorMessage = nil
        } catch {
            silentReplaySessionIDs.remove(sessionID)
            dropPendingNotifications(for: sessionID)
            guard activeSessionID == sessionID else { return }
            runtimeBySession[sessionID, default: SessionRuntime()].errorMessage = error.localizedDescription
        }
    }

    func openSession(_ sessionID: String, preservingExistingMessages: Bool = false) async {
        if !preservingExistingMessages,
           runtimeBySession[sessionID]?.hasAuthoritativeReplay == true,
           messagesBySession[sessionID]?.isEmpty == false {
            activeSessionID = sessionID
            var runtime = runtimeBySession[sessionID] ?? SessionRuntime()
            runtime.isOpening = false
            runtime.isReplaying = false
            runtime.errorMessage = nil
            runtimeBySession[sessionID] = runtime
            return
        }

        var openToken = preparedOpenToken(
            for: sessionID,
            preservingExistingMessages: preservingExistingMessages
        ) ?? prepareOpenSessionState(
            sessionID,
            preservingExistingMessages: preservingExistingMessages
        )

        if client == nil {
            await connect()
            openToken = UUID()
            openSessionTokens[sessionID] = openToken
        }

        guard let client else {
            runtimeBySession[sessionID, default: SessionRuntime()].isOpening = false
            runtimeBySession[sessionID, default: SessionRuntime()].isReplaying = false
            runtimeBySession[sessionID, default: SessionRuntime()].errorMessage = errorMessage ?? "Connection is unavailable."
            return
        }

        await Task.yield()

        let exportTask = Task.detached(priority: .userInitiated) { [client, exportTailMessageLimit] () -> ExportedSessionSnapshot? in
            do {
                let json = try await client.exportSession(sessionID: sessionID)
                return try ExportedSessionSnapshot.parse(json: json, tailLimit: exportTailMessageLimit)
            } catch {
                return nil
            }
        }

        if let snapshot = await snapshot(from: exportTask, before: loadDelay),
           isCurrentOpen(sessionID: sessionID, token: openToken),
           (messagesBySession[sessionID] ?? []).isEmpty {
            publish(snapshot: snapshot, for: sessionID)
            await Task.yield()
        }

        guard isCurrentOpen(sessionID: sessionID, token: openToken) else {
            clearOpeningStateIfNoLongerCurrent(sessionID: sessionID)
            return
        }
        runtimeBySession[sessionID, default: SessionRuntime()].isOpening = false
        runtimeBySession[sessionID, default: SessionRuntime()].isReplaying = true

        if (messagesBySession[sessionID] ?? []).isEmpty {
            publishLateSnapshot(from: exportTask, sessionID: sessionID, token: openToken)
        }

        do {
            let cwd = sessions.first(where: { $0.id == sessionID })?.cwd
            try await client.loadSession(sessionID: sessionID, cwd: cwd ?? connectionConfig.defaultCWD)
            guard isCurrentOpen(sessionID: sessionID, token: openToken) else {
                clearOpeningStateIfNoLongerCurrent(sessionID: sessionID)
                return
            }
            flushPendingNotifications(authoritativeReplaySessionID: sessionID)
            queuedPromptAttachRetryAttemptsBySession[sessionID] = nil
            await sendQueuedPrompts(for: sessionID, openToken: openToken)
        } catch {
            guard isCurrentOpen(sessionID: sessionID, token: openToken) else {
                clearOpeningStateIfNoLongerCurrent(sessionID: sessionID)
                return
            }
            runtimeBySession[sessionID, default: SessionRuntime()].isReplaying = false
            runtimeBySession[sessionID, default: SessionRuntime()].isOpening = false
            flushPendingNotifications()
            let queuedPromptCount = queuedPromptsBySession[sessionID]?.count ?? 0
            runtimeBySession[sessionID, default: SessionRuntime()].queuedPromptCount = queuedPromptCount
            runtimeBySession[sessionID, default: SessionRuntime()].errorMessage = queuedPromptCount > 0
                ? "\(error.localizedDescription) Queued messages remain pending."
                : error.localizedDescription
            if queuedPromptCount > 0 {
                scheduleQueuedPromptAttachRetry(for: sessionID)
            }
        }
    }

    func prepareSessionForNavigation(_ sessionID: String) {
        if runtimeBySession[sessionID]?.hasAuthoritativeReplay == true,
           messagesBySession[sessionID]?.isEmpty == false {
            activeSessionID = sessionID
            var runtime = runtimeBySession[sessionID] ?? SessionRuntime()
            runtime.isOpening = false
            runtime.isReplaying = false
            runtime.errorMessage = nil
            runtimeBySession[sessionID] = runtime
            return
        }

        guard preparedOpenToken(for: sessionID, preservingExistingMessages: false) == nil else {
            activeSessionID = sessionID
            return
        }

        prepareOpenSessionState(sessionID, preservingExistingMessages: false)
    }

    @discardableResult
    func prepareOpenSessionState(
        _ sessionID: String,
        preservingExistingMessages: Bool
    ) -> UUID {
        let openToken = UUID()
        openSessionTokens[sessionID] = openToken
        activeSessionID = sessionID
        if !preservingExistingMessages {
            queuedPromptAttachRetryAttemptsBySession[sessionID] = nil
            messagesBySession[sessionID] = []
            earlierMessagesBySession[sessionID] = []
            runtimeBySession[sessionID] = SessionRuntime(isOpening: true)
        } else {
            var runtime = runtimeBySession[sessionID] ?? SessionRuntime()
            runtime.isOpening = true
            runtime.isReplaying = false
            runtime.errorMessage = nil
            runtime.activeRunID = nil
            runtime.streamingMessageID = nil
            runtimeBySession[sessionID] = runtime
        }
        return openToken
    }

    private func preparedOpenToken(
        for sessionID: String,
        preservingExistingMessages: Bool
    ) -> UUID? {
        guard !preservingExistingMessages,
              let openToken = openSessionTokens[sessionID],
              runtimeBySession[sessionID]?.isOpening == true,
              runtimeBySession[sessionID]?.isReplaying == false,
              messagesBySession[sessionID]?.isEmpty == true,
              earlierMessagesBySession[sessionID]?.isEmpty == true
        else {
            return nil
        }

        return openToken
    }

    func sendDraft(for sessionID: String) async {
        let text = (draftBySession[sessionID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draftBySession[sessionID] = ""
        let messageID = UUID().uuidString
        appendLocalUserMessage(id: messageID, sessionID: sessionID, text: text)
        await send(messageID: messageID, text: text, in: sessionID)
    }

    func sendNotificationReply(sessionID: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let messageID = UUID().uuidString
        appendLocalUserMessage(id: messageID, sessionID: sessionID, text: trimmed)
        await send(messageID: messageID, text: trimmed, in: sessionID)
    }

    func revealEarlierMessages(for sessionID: String) {
        guard let earlierMessages = earlierMessagesBySession[sessionID], !earlierMessages.isEmpty else {
            return
        }
        earlierMessagesBySession[sessionID] = []
        messagesBySession[sessionID] = earlierMessages + (messagesBySession[sessionID] ?? [])
    }

    func toggleDemoBackgroundKeepalive() {
        demoBackgroundKeepaliveEnabled.toggle()
        if demoBackgroundKeepaliveEnabled {
            backgroundKeepalive.start()
        } else {
            backgroundKeepalive.stop()
        }
    }

    private func snapshot(
        from task: Task<ExportedSessionSnapshot?, Never>,
        before delay: Duration
    ) async -> ExportedSessionSnapshot? {
        await withTaskGroup(of: ExportedSessionSnapshot?.self) { group in
            group.addTask {
                await task.value
            }
            group.addTask {
                try? await Task.sleep(for: delay)
                return nil
            }

            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func publishLateSnapshot(
        from task: Task<ExportedSessionSnapshot?, Never>,
        sessionID: String,
        token: UUID
    ) {
        Task { @MainActor [weak self] in
            guard let snapshot = await task.value,
                  let self,
                  self.isCurrentOpen(sessionID: sessionID, token: token),
                  (self.messagesBySession[sessionID] ?? []).isEmpty
            else {
                return
            }

            self.publish(snapshot: snapshot, for: sessionID)
        }
    }

    private func publish(snapshot: ExportedSessionSnapshot, for sessionID: String) {
        guard !snapshot.visibleMessages.isEmpty else { return }

        messagesBySession[sessionID] = snapshot.visibleMessages
        earlierMessagesBySession[sessionID] = snapshot.earlierMessages
        runtimeBySession[sessionID, default: SessionRuntime()].hasTailSnapshot = true
        runtimeBySession[sessionID, default: SessionRuntime()].hasAuthoritativeReplay = false
        runtimeBySession[sessionID, default: SessionRuntime()].snapshotMessageIDs = Set(
            (snapshot.visibleMessages + snapshot.earlierMessages).map(\.id)
        )

        if let lastText = snapshot.visibleMessages.compactMap(\.plainText).last {
            updateSessionActivity(sessionID: sessionID, subtitle: sessionPreview(from: lastText))
        }
    }

    private func sessionPreview(from text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let limit = 240
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private func isCurrentOpen(sessionID: String, token: UUID) -> Bool {
        openSessionTokens[sessionID] == token
    }

    private func clearOpeningStateIfNoLongerCurrent(sessionID: String) {
        guard openSessionTokens[sessionID] == nil else { return }
        runtimeBySession[sessionID, default: SessionRuntime()].isOpening = false
        runtimeBySession[sessionID, default: SessionRuntime()].isReplaying = false
    }

    private func observeNotifications(from client: ACPClient) {
        notificationTask?.cancel()
        notificationTask = Task { [weak self] in
            for await notification in client.notifications {
                self?.enqueue(notification)
            }
        }
    }

    private func closeCurrentClient() async {
        cancelLiveRefreshLoop()
        notificationTask?.cancel()
        notificationTask = nil
        notificationFlushTask?.cancel()
        notificationFlushTask = nil
        pendingNotifications.removeAll()
        openSessionTokens.removeAll()
        queuedPromptAttachRetrySessionIDs.removeAll()
        queuedPromptAttachRetryAttemptsBySession.removeAll()
        silentReplaySessionIDs.removeAll()
        outboundPromptSessionIDs.removeAll()
        locallyStartedRunSessionIDs.removeAll()
        if let client {
            await client.close()
        }
        client = nil
    }

    private func enqueue(_ notification: ACPNotification) {
        pendingNotifications.append(notification)
        let runtime = runtimeBySession[notification.sessionID]
        if runtime?.isOpening == true
            || runtime?.isReplaying == true
            || silentReplaySessionIDs.contains(notification.sessionID) {
            return
        }
        scheduleNotificationFlush()
    }

    private func scheduleNotificationFlush() {
        guard notificationFlushTask == nil else { return }
        notificationFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            await MainActor.run {
                self?.flushPendingNotifications()
            }
        }
    }

    private func flushPendingNotifications(authoritativeReplaySessionID: String? = nil) {
        notificationFlushTask?.cancel()
        notificationFlushTask = nil

        let replayingSessionIDs = Set(
            runtimeBySession.compactMap { entry in
                entry.value.isOpening || entry.value.isReplaying ? entry.key : nil
            }
        ).union(silentReplaySessionIDs)
        var notifications: [ACPNotification] = []
        var deferredNotifications: [ACPNotification] = []
        for notification in pendingNotifications {
            if notification.sessionID == authoritativeReplaySessionID
                || !replayingSessionIDs.contains(notification.sessionID) {
                notifications.append(notification)
            } else {
                deferredNotifications.append(notification)
            }
        }
        pendingNotifications = deferredNotifications
        guard !notifications.isEmpty || authoritativeReplaySessionID != nil else { return }

        var assistantNotifications: [(sessionID: String, notification: AssistantNotification)] = []
        let grouped = Dictionary(grouping: notifications, by: \.sessionID)
        var sessionIDs = Set(grouped.keys)
        if let authoritativeReplaySessionID {
            sessionIDs.insert(authoritativeReplaySessionID)
        }

        for sessionID in sessionIDs {
            let sessionNotifications = grouped[sessionID] ?? []
            var mergedResult = TranscriptApplyResult()

            if sessionID == authoritativeReplaySessionID {
                let existingMessages = messagesBySession[sessionID] ?? []
                let existingRuntime = runtimeBySession[sessionID] ?? SessionRuntime()
                let optimisticMessages = existingMessages.filter { message in
                    existingRuntime.optimisticUserMessageIDs.contains(message.id)
                }
                let replay = ChatTranscriptReducer.authoritativeReplay(
                    notifications: sessionNotifications,
                    preservingLocalPrompts: queuedPromptsBySession[sessionID] ?? [],
                    preservingOptimisticMessages: optimisticMessages
                )
                queuedPromptsBySession[sessionID] = replay.queuedPrompts
                if replay.messages.isEmpty, !existingMessages.isEmpty {
                    messagesBySession[sessionID] = existingMessages
                    var runtime = replay.runtime
                    runtime.hasTailSnapshot = existingRuntime.hasTailSnapshot
                    runtime.hasAuthoritativeReplay = false
                    runtime.snapshotMessageIDs = existingRuntime.snapshotMessageIDs
                    runtime.queuedPromptCount = replay.queuedPrompts.count
                    runtimeBySession[sessionID] = runtime
                } else {
                    messagesBySession[sessionID] = replay.messages
                    earlierMessagesBySession[sessionID] = []
                    runtimeBySession[sessionID] = replay.runtime
                }
                mergedResult = replay.result
            } else {
                var reducer = ChatTranscriptReducer(
                    messages: messagesBySession[sessionID] ?? [],
                    runtime: runtimeBySession[sessionID] ?? SessionRuntime()
                )

                for notification in sessionNotifications {
                    let result = reducer.apply(notification)
                    mergedResult.merge(result)
                    if let assistantNotification = result.assistantNotification {
                        assistantNotifications.append((sessionID, assistantNotification))
                    }
                }

                messagesBySession[sessionID] = reducer.messages
                runtimeBySession[sessionID] = reducer.runtime
            }
            patchSessionMetadata(sessionID: sessionID, from: mergedResult)
            if mergedResult.didCompleteRun {
                locallyStartedRunSessionIDs.remove(sessionID)
            }
        }

        postBackgroundNotifications(assistantNotifications)
    }

    private func dropPendingNotifications(for sessionID: String) {
        pendingNotifications.removeAll { $0.sessionID == sessionID }
    }

    private func postBackgroundNotifications(
        _ assistantNotifications: [(sessionID: String, notification: AssistantNotification)]
    ) {
        guard scenePhase != .active else { return }

        for (sessionID, assistantNotification) in assistantNotifications
        where !lastNotifiedMessageIDs.contains(assistantNotification.messageID) {
            lastNotifiedMessageIDs.insert(assistantNotification.messageID)
            ContinuedProcessingDemoService.shared.noteACPActivity(
                title: title(for: sessionID),
                subtitle: assistantNotification.preview
            )
            Task {
                await notificationCoordinator.postAssistantMessage(
                    sessionID: sessionID,
                    title: title(for: sessionID),
                    body: assistantNotification.preview
                )
            }
        }
    }

    @discardableResult
    private func send(
        messageID: String,
        text: String,
        in sessionID: String,
        allowQueue: Bool = true
    ) async -> Bool {
        let runtime = runtimeBySession[sessionID]
        if allowQueue,
           (runtime?.queuedPromptCount ?? 0) > 0
            || ((runtime?.isOpening == true || runtime?.isReplaying == true)
                && runtime?.hasAuthoritativeReplay != true) {
            queuePrompt(id: messageID, text: text, for: sessionID)
            scheduleQueuedPromptWorkIfNeeded(for: sessionID)
            return true
        }

        do {
            if client == nil {
                await connect()
            }
            guard let client else { return false }

            outboundPromptSessionIDs.insert(sessionID)
            defer {
                outboundPromptSessionIDs.remove(sessionID)
            }

            let activeRunID = runtimeBySession[sessionID]?.activeRunID
            if let activeRunID {
                let newRunID = try await client.steer(sessionID: sessionID, expectedRunID: activeRunID, text: text)
                runtimeBySession[sessionID, default: SessionRuntime()].activeRunID = newRunID
                locallyStartedRunSessionIDs.insert(sessionID)
            } else {
                try await client.sendPrompt(sessionID: sessionID, messageID: messageID, text: text)
                locallyStartedRunSessionIDs.insert(sessionID)
            }
            return true
        } catch {
            runtimeBySession[sessionID, default: SessionRuntime()].errorMessage = error.localizedDescription
            return false
        }
    }

    private func appendLocalUserMessage(id: String, sessionID: String, text: String) {
        var reducer = ChatTranscriptReducer(
            messages: messagesBySession[sessionID] ?? [],
            runtime: runtimeBySession[sessionID] ?? SessionRuntime()
        )
        reducer.appendLocalUserMessage(id: id, text: text)
        messagesBySession[sessionID] = reducer.messages
        runtimeBySession[sessionID] = reducer.runtime
        updateSessionActivity(sessionID: sessionID, subtitle: text)
    }

    private func queuePrompt(id: String, text: String, for sessionID: String) {
        queuedPromptsBySession[sessionID, default: []].append(QueuedPrompt(id: id, text: text))
        if runtimeBySession[sessionID]?.hasAuthoritativeReplay != true {
            queuedPromptAttachRetryAttemptsBySession[sessionID] = nil
        }
        runtimeBySession[sessionID, default: SessionRuntime()].queuedPromptCount = queuedPromptsBySession[sessionID]?.count ?? 0
    }

    private func scheduleQueuedPromptWorkIfNeeded(for sessionID: String) {
        let runtime = runtimeBySession[sessionID]
        if runtime?.hasAuthoritativeReplay == true,
           let token = openSessionTokens[sessionID] {
            scheduleQueuedPromptDrain(for: sessionID, token: token)
            return
        }

        guard runtime?.isOpening != true, runtime?.isReplaying != true else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.openSession(sessionID, preservingExistingMessages: true)
        }
    }

    private func scheduleQueuedPromptAttachRetry(for sessionID: String) {
        guard !queuedPromptAttachRetrySessionIDs.contains(sessionID) else { return }

        guard case .schedule = consumeNextQueuedPromptAttachRetryDecision(for: sessionID) else {
            return
        }

        queuedPromptAttachRetrySessionIDs.insert(sessionID)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            self.queuedPromptAttachRetrySessionIDs.remove(sessionID)
            guard self.queuedPromptsBySession[sessionID]?.isEmpty == false else {
                self.queuedPromptAttachRetryAttemptsBySession[sessionID] = nil
                return
            }
            guard self.activeSessionID == sessionID else {
                self.queuedPromptAttachRetryAttemptsBySession[sessionID] = nil
                return
            }
            guard self.runtimeBySession[sessionID]?.hasAuthoritativeReplay != true else {
                self.queuedPromptAttachRetryAttemptsBySession[sessionID] = nil
                return
            }
            await self.openSession(sessionID, preservingExistingMessages: true)
        }
    }

    @discardableResult
    func consumeNextQueuedPromptAttachRetryDecision(for sessionID: String) -> QueuedPromptAttachRetryDecision {
        guard queuedPromptsBySession[sessionID]?.isEmpty == false else {
            queuedPromptAttachRetryAttemptsBySession[sessionID] = nil
            return .none
        }

        let attempt = (queuedPromptAttachRetryAttemptsBySession[sessionID] ?? 0) + 1
        queuedPromptAttachRetryAttemptsBySession[sessionID] = attempt
        guard attempt <= maxQueuedPromptAttachRetryAttempts else {
            let currentErrorMessage = runtimeBySession[sessionID]?.errorMessage
            let exhaustedMessage = "Queued messages remain pending after \(maxQueuedPromptAttachRetryAttempts) attach retries."
            let message: String
            if let currentErrorMessage, !currentErrorMessage.isEmpty {
                message = "\(currentErrorMessage) \(exhaustedMessage)"
            } else {
                message = exhaustedMessage
            }
            runtimeBySession[sessionID, default: SessionRuntime()].errorMessage = message
            return .exhausted
        }

        return .schedule(attempt: attempt)
    }

    private func scheduleQueuedPromptDrain(
        for sessionID: String,
        token: UUID,
        after delay: Duration? = nil
    ) {
        Task { @MainActor [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard let self, self.isCurrentOpen(sessionID: sessionID, token: token) else {
                return
            }
            await self.sendQueuedPrompts(for: sessionID, openToken: token)
        }
    }

    private func sendQueuedPrompts(for sessionID: String, openToken: UUID) async {
        guard !drainingQueuedPromptSessionIDs.contains(sessionID) else {
            queuedPromptDrainRetrySessionIDs.insert(sessionID)
            return
        }
        drainingQueuedPromptSessionIDs.insert(sessionID)
        var shouldRetryAfterDrain = false
        defer {
            drainingQueuedPromptSessionIDs.remove(sessionID)
            let retryWasRequested = queuedPromptDrainRetrySessionIDs.remove(sessionID) != nil
            if (retryWasRequested || shouldRetryAfterDrain),
               queuedPromptsBySession[sessionID]?.isEmpty == false,
               runtimeBySession[sessionID]?.hasAuthoritativeReplay == true,
               let currentToken = openSessionTokens[sessionID] {
                scheduleQueuedPromptDrain(for: sessionID, token: currentToken, after: .seconds(1))
            }
        }

        while let prompt = queuedPromptsBySession[sessionID]?.first {
            guard isCurrentOpen(sessionID: sessionID, token: openToken) else {
                shouldRetryAfterDrain = true
                return
            }
            let didSend = await send(messageID: prompt.id, text: prompt.text, in: sessionID, allowQueue: false)
            guard didSend else {
                shouldRetryAfterDrain = true
                runtimeBySession[sessionID, default: SessionRuntime()].queuedPromptCount = queuedPromptsBySession[sessionID]?.count ?? 0
                return
            }
            guard queuedPromptsBySession[sessionID]?.first?.id == prompt.id else {
                runtimeBySession[sessionID, default: SessionRuntime()].queuedPromptCount = queuedPromptsBySession[sessionID]?.count ?? 0
                continue
            }
            queuedPromptsBySession[sessionID]?.removeFirst()
            runtimeBySession[sessionID, default: SessionRuntime()].queuedPromptCount = queuedPromptsBySession[sessionID]?.count ?? 0
        }
    }

    private func patchSessionMetadata(sessionID: String, from result: TranscriptApplyResult) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if let title = result.sessionTitle {
            sessions[index].title = title
        }
        if let subtitle = result.subtitle {
            sessions[index].subtitle = subtitle
        }
        let now = Date()
        sessions[index].updatedAt = now
        sessions[index].lastMessageAt = now
        sessions[index].isWorking = runtimeBySession[sessionID]?.activeRunID != nil
    }

    private func updateSessionActivity(sessionID: String, subtitle: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].subtitle = subtitle
        let now = Date()
        sessions[index].updatedAt = now
        sessions[index].lastMessageAt = now
    }

    private func title(for sessionID: String) -> String {
        sessions.first(where: { $0.id == sessionID })?.displayTitle ?? "Away"
    }

    private func beginShortBackgroundTask() {
        guard shortBackgroundTaskID == .invalid else { return }
        shortBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "ACP notification window") { [weak self] in
            Task { @MainActor in
                self?.endShortBackgroundTask()
            }
        }
    }

    private func endShortBackgroundTask() {
        guard shortBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(shortBackgroundTaskID)
        shortBackgroundTaskID = .invalid
    }
}

#if DEBUG
extension AppModel {
    func publishListedSessionsForTesting(_ sessions: [SessionSummary]) {
        publish(listedSessions: sessions)
    }

    func publishSnapshotForTesting(_ snapshot: ExportedSessionSnapshot, for sessionID: String) {
        publish(snapshot: snapshot, for: sessionID)
    }

    func appendPendingNotificationsForTesting(_ notifications: [ACPNotification]) {
        pendingNotifications.append(contentsOf: notifications)
    }

    func enqueueNotificationForTesting(_ notification: ACPNotification) {
        enqueue(notification)
    }

    func setSilentReplayForTesting(_ isReplaying: Bool, sessionID: String) {
        if isReplaying {
            silentReplaySessionIDs.insert(sessionID)
        } else {
            silentReplaySessionIDs.remove(sessionID)
        }
    }

    func pendingNotificationCountForTesting(sessionID: String) -> Int {
        pendingNotifications.filter { $0.sessionID == sessionID }.count
    }

    func flushPendingNotificationsForTesting(authoritativeReplaySessionID: String?) {
        flushPendingNotifications(authoritativeReplaySessionID: authoritativeReplaySessionID)
    }

    func queuePromptForTesting(id: String, text: String, for sessionID: String) {
        queuePrompt(id: id, text: text, for: sessionID)
    }

    func setQueuedPromptsForTesting(_ prompts: [QueuedPrompt], for sessionID: String) {
        queuedPromptsBySession[sessionID] = prompts
        runtimeBySession[sessionID, default: SessionRuntime()].queuedPromptCount = prompts.count
    }

    func queuedPromptAttachRetryAttemptsForTesting(sessionID: String) -> Int? {
        queuedPromptAttachRetryAttemptsBySession[sessionID]
    }
}
#endif
