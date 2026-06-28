import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
final class AppModel {
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
    @ObservationIgnored private var shortBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var lastNotifiedMessageIDs: Set<String> = []
    @ObservationIgnored private let connectionConfig: RemoteConnectionConfig
    @ObservationIgnored private let notificationCoordinator = NotificationCoordinator.shared
    @ObservationIgnored private let backgroundKeepalive = DemoBackgroundKeepaliveService()

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
            }
        case .background:
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
            sessions = listed.sorted(by: SessionSummary.isMoreRecent)
            errorMessage = nil
            connectionState = .connected
        } catch {
            connectionState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            await closeCurrentClient()
        }
    }

    func openSession(_ sessionID: String) async {
        activeSessionID = sessionID
        messagesBySession[sessionID] = []
        runtimeBySession[sessionID] = SessionRuntime(isReplaying: true)

        if client == nil {
            await connect()
        }

        guard let client else {
            runtimeBySession[sessionID, default: SessionRuntime()].isReplaying = false
            runtimeBySession[sessionID, default: SessionRuntime()].errorMessage = errorMessage ?? "Connection is unavailable."
            return
        }

        do {
            let cwd = sessions.first(where: { $0.id == sessionID })?.cwd
            try await client.loadSession(sessionID: sessionID, cwd: cwd ?? connectionConfig.defaultCWD)
            flushPendingNotifications()
            runtimeBySession[sessionID, default: SessionRuntime()].isReplaying = false
        } catch {
            flushPendingNotifications()
            runtimeBySession[sessionID, default: SessionRuntime()].isReplaying = false
            runtimeBySession[sessionID, default: SessionRuntime()].errorMessage = error.localizedDescription
        }
    }

    func sendDraft(for sessionID: String) async {
        let text = (draftBySession[sessionID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draftBySession[sessionID] = ""
        appendLocalUserMessage(sessionID: sessionID, text: text)
        await send(text, in: sessionID)
    }

    func sendNotificationReply(sessionID: String, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendLocalUserMessage(sessionID: sessionID, text: trimmed)
        await send(trimmed, in: sessionID)
    }

    func toggleDemoBackgroundKeepalive() {
        demoBackgroundKeepaliveEnabled.toggle()
        if demoBackgroundKeepaliveEnabled {
            backgroundKeepalive.start()
        } else {
            backgroundKeepalive.stop()
        }
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
        notificationTask?.cancel()
        notificationTask = nil
        notificationFlushTask?.cancel()
        notificationFlushTask = nil
        pendingNotifications.removeAll()
        if let client {
            await client.close()
        }
        client = nil
    }

    private func enqueue(_ notification: ACPNotification) {
        pendingNotifications.append(notification)
        if runtimeBySession[notification.sessionID]?.isReplaying == true {
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

    private func flushPendingNotifications() {
        notificationFlushTask?.cancel()
        notificationFlushTask = nil

        let notifications = pendingNotifications
        pendingNotifications.removeAll(keepingCapacity: true)
        guard !notifications.isEmpty else { return }

        var assistantNotifications: [(sessionID: String, notification: AssistantNotification)] = []
        let grouped = Dictionary(grouping: notifications, by: \.sessionID)

        for (sessionID, sessionNotifications) in grouped {
            var reducer = ChatTranscriptReducer(
                messages: messagesBySession[sessionID] ?? [],
                runtime: runtimeBySession[sessionID] ?? SessionRuntime()
            )
            var mergedResult = TranscriptApplyResult()

            for notification in sessionNotifications {
                let result = reducer.apply(notification)
                mergedResult.merge(result)
                if let assistantNotification = result.assistantNotification {
                    assistantNotifications.append((sessionID, assistantNotification))
                }
            }

            messagesBySession[sessionID] = reducer.messages
            runtimeBySession[sessionID] = reducer.runtime
            patchSessionMetadata(sessionID: sessionID, from: mergedResult)
        }

        postBackgroundNotifications(assistantNotifications)
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

    private func send(_ text: String, in sessionID: String) async {
        do {
            if client == nil {
                await connect()
            }
            guard let client else { return }

            let activeRunID = runtimeBySession[sessionID]?.activeRunID
            if let activeRunID {
                let newRunID = try await client.steer(sessionID: sessionID, expectedRunID: activeRunID, text: text)
                runtimeBySession[sessionID, default: SessionRuntime()].activeRunID = newRunID
            } else {
                try await client.sendPrompt(sessionID: sessionID, text: text)
            }
        } catch {
            runtimeBySession[sessionID, default: SessionRuntime()].errorMessage = error.localizedDescription
        }
    }

    private func appendLocalUserMessage(sessionID: String, text: String) {
        var reducer = ChatTranscriptReducer(
            messages: messagesBySession[sessionID] ?? [],
            runtime: runtimeBySession[sessionID] ?? SessionRuntime()
        )
        reducer.appendLocalUserMessage(id: UUID().uuidString, text: text)
        messagesBySession[sessionID] = reducer.messages
        runtimeBySession[sessionID] = reducer.runtime
        updateSessionActivity(sessionID: sessionID, subtitle: text)
    }

    private func patchSessionMetadata(sessionID: String, from result: TranscriptApplyResult) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if let title = result.sessionTitle {
            sessions[index].title = title
        }
        if let subtitle = result.subtitle {
            sessions[index].subtitle = subtitle
        }
        sessions[index].updatedAt = Date()
        sessions[index].isWorking = runtimeBySession[sessionID]?.activeRunID != nil
    }

    private func updateSessionActivity(sessionID: String, subtitle: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].subtitle = subtitle
        sessions[index].updatedAt = Date()
    }

    private func title(for sessionID: String) -> String {
        sessions.first(where: { $0.id == sessionID })?.displayTitle ?? "Goose"
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
