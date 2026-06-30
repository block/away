import XCTest
@testable import Away
#if os(iOS)
import UIKit
#endif

final class TranscriptSurfaceTests: XCTestCase {
    func testRowsHideEmptyLoadingSessionUntilTranscriptRowsAreReady() {
        let session = SessionSummary(id: "s1", title: "Large Session", messageCount: 4_000)

        let rows = TranscriptSurfaceRows.make(
            session: session,
            messages: [],
            isLoading: true,
            hasAuthoritativeReplay: false,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows, [])
    }

    func testRowsHideProvisionalSnapshotWhileLoading() {
        let session = SessionSummary(id: "s1", title: "Large Session", messageCount: 4_000)
        let messages = [
            ChatMessage(id: "snapshot-1", role: .assistant, content: [.text("Provisional tail")])
        ]

        let rows = TranscriptSurfaceRows.make(
            session: session,
            messages: messages,
            isLoading: true,
            hasAuthoritativeReplay: false,
            snapshotMessageIDs: ["snapshot-1"],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows, [])
    }

    func testRowsKeepOptimisticMessagesVisibleWhileSnapshotIsLoading() {
        let session = SessionSummary(id: "s1", title: "Large Session", messageCount: 4_000)
        let snapshot = ChatMessage(id: "snapshot-1", role: .assistant, content: [.text("Provisional tail")])
        let optimistic = ChatMessage(id: "local-1", role: .user, content: [.text("Queued prompt")])

        let rows = TranscriptSurfaceRows.make(
            session: session,
            messages: [snapshot, optimistic],
            isLoading: true,
            hasAuthoritativeReplay: false,
            snapshotMessageIDs: ["snapshot-1"],
            optimisticUserMessageIDs: ["local-1"]
        )

        XCTAssertEqual(rows, [.message(optimistic)])
    }

    func testRowsShowSnapshotAfterLoadingCompletes() {
        let session = SessionSummary(id: "s1", title: "Large Session", messageCount: 4_000)
        let snapshot = ChatMessage(id: "snapshot-1", role: .assistant, content: [.text("Fallback tail")])

        let rows = TranscriptSurfaceRows.make(
            session: session,
            messages: [snapshot],
            isLoading: false,
            hasAuthoritativeReplay: false,
            snapshotMessageIDs: ["snapshot-1"],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows, [.message(snapshot)])
    }

    func testRowsExposeAllFetchedMessagesToPlatformAdapter() {
        let messages = makeMessages(count: 5_000)

        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: messages,
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows.count, 5_000)
        XCTAssertEqual(rows.first?.id, "message:message-0")
        XCTAssertEqual(rows.last?.id, "message:message-4999")
    }

    func testRowsSplitLongAssistantTextIntoStableChunks() {
        let longText = String(repeating: "Large assistant transcript paragraph with enough text to require chunking. ", count: 180)
        let message = ChatMessage(id: "assistant-1", role: .assistant, content: [.text(longText)])

        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [message],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertGreaterThan(rows.count, 1)
        XCTAssertEqual(rows.first?.id, "message:assistant-1::chunk:0")
        let chunkedText = rows.compactMap { row -> String? in
            guard case .message(let message) = row,
                  case .text(let text) = message.content.first
            else {
                return nil
            }
            return text
        }
        XCTAssertEqual(chunkedText.joined(), longText)
        XCTAssertTrue(chunkedText.dropLast().allSatisfy { $0.count <= TranscriptTextChunker.defaultCharacterLimit + 1 })
    }

    func testRowsKeepLongUserTextAsSingleBubble() {
        let longText = String(repeating: "Large user prompt. ", count: 260)
        let message = ChatMessage(id: "user-1", role: .user, content: [.text(longText)])

        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: [message],
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        XCTAssertEqual(rows, [.message(message)])
    }

    func testBottomScrollPolicyRequestsOnlyWhenSettledAndNearBottom() {
        XCTAssertTrue(
            TranscriptBottomScrollPolicy.shouldRequestAfterInitialSettle(canSettleToBottom: true)
        )
        XCTAssertFalse(
            TranscriptBottomScrollPolicy.shouldRequestAfterInitialSettle(canSettleToBottom: false)
        )
        XCTAssertTrue(
            TranscriptBottomScrollPolicy.shouldRequestAfterMessageCountChanged(
                canSettleToBottom: true,
                isUserNearBottom: false,
                oldCount: 0
            )
        )
        XCTAssertTrue(
            TranscriptBottomScrollPolicy.shouldRequestAfterMessageCountChanged(
                canSettleToBottom: true,
                isUserNearBottom: true,
                oldCount: 12
            )
        )
        XCTAssertFalse(
            TranscriptBottomScrollPolicy.shouldRequestAfterMessageCountChanged(
                canSettleToBottom: true,
                isUserNearBottom: false,
                oldCount: 12
            )
        )
        XCTAssertFalse(
            TranscriptBottomScrollPolicy.shouldRequestAfterLastMessageChanged(
                canSettleToBottom: true,
                isUserNearBottom: false
            )
        )
    }

    #if os(iOS)
    @MainActor
    func testTableViewHostsOnlyVisibleCellsForLargeSyntheticTranscript() throws {
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 5_000),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        let dataSource = TranscriptTableViewDataSource()
        dataSource.rows = rows
        let delegate = NoOpTableDelegate()

        let tableView = TranscriptTableViewFactory.make(dataSource: dataSource, delegate: delegate)
        let window = try host(tableView)

        tableView.reloadData()
        tableView.layoutIfNeeded()

        XCTAssertEqual(dataSource.rows.count, 5_000)
        XCTAssertGreaterThan(tableView.visibleCells.count, 0)
        XCTAssertLessThan(tableView.visibleCells.count, 30)
        XCTAssertLessThan(dataSource.createdCellCount, 60)
        _ = window
    }

    func testEstimatedRowHeightScalesForLongAssistantMessages() {
        let shortRow = TranscriptSurfaceRow.message(
            ChatMessage(id: "short", role: .assistant, content: [.text("Short response.")])
        )
        let longRow = TranscriptSurfaceRow.message(
            ChatMessage(
                id: "long",
                role: .assistant,
                content: [.text(String(repeating: "Long transcript response with enough words to wrap across many lines. ", count: 420))]
            )
        )

        let shortHeight = TranscriptRowHeightEstimator.estimatedHeight(for: shortRow, tableWidth: 390)
        let longHeight = TranscriptRowHeightEstimator.estimatedHeight(for: longRow, tableWidth: 390)

        XCTAssertLessThan(shortHeight, 80)
        XCTAssertGreaterThan(longHeight, 1_000)
        XCTAssertGreaterThan(longHeight, shortHeight * 15)
    }

    func testEstimatedRowHeightAccountsForUserBubbleWidth() {
        let text = String(repeating: "Wrapping text. ", count: 120)
        let assistantRow = TranscriptSurfaceRow.message(
            ChatMessage(id: "assistant", role: .assistant, content: [.text(text)])
        )
        let userRow = TranscriptSurfaceRow.message(
            ChatMessage(id: "user", role: .user, content: [.text(text)])
        )

        let assistantHeight = TranscriptRowHeightEstimator.estimatedHeight(for: assistantRow, tableWidth: 390)
        let userHeight = TranscriptRowHeightEstimator.estimatedHeight(for: userRow, tableWidth: 390)

        XCTAssertGreaterThan(userHeight, assistantHeight)
    }

    @MainActor
    func testCoordinatorHidesOversizedInitialTranscriptUntilBottomSettles() throws {
        let harness = try makeCoordinatorHarness()
        let rows = [
            TranscriptSurfaceRow.message(
                ChatMessage(
                    id: "long",
                    role: .assistant,
                    content: [.text(String(repeating: "Large transcript row that should land pinned to the bottom after sizing. ", count: 520))]
                )
            )
        ]

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            isLoading: true,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )

        XCTAssertEqual(harness.tableView.alpha, 0)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        harness.tableView.layoutIfNeeded()

        XCTAssertEqual(harness.tableView.alpha, 1)
        XCTAssertLessThanOrEqual(distanceFromBottom(harness.tableView), 170)
    }

    @MainActor
    func testCoordinatorDoesNotHideShortInitialTranscript() throws {
        let harness = try makeCoordinatorHarness()
        let rows = [
            TranscriptSurfaceRow.message(
                ChatMessage(id: "short", role: .assistant, content: [.text("Short transcript.")])
            )
        ]

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            isLoading: true,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )

        XCTAssertEqual(harness.tableView.alpha, 1)
    }

    @MainActor
    func testCoordinatorScrollsToBottomInitiallyAndAfterAppendWhenNearBottom() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 80),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)

        XCTAssertLessThanOrEqual(distanceFromBottom(harness.tableView), 170)

        let appendedRows = rows + [
            .message(
                ChatMessage(
                    id: "message-80",
                    role: .assistant,
                    createdAt: Date(timeIntervalSince1970: 80),
                    content: [.text("Newest assistant response")]
                )
            )
        ]
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: appendedRows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 2)
        )
        pumpLayout(for: harness.tableView)

        XCTAssertLessThanOrEqual(distanceFromBottom(harness.tableView), 170)
        XCTAssertTrue(
            harness.tableView.indexPathsForVisibleRows?.contains(IndexPath(row: appendedRows.count - 1, section: 0)) == true
        )
    }

    @MainActor
    func testCoordinatorPreservesVisibleAnchorWhenEarlierRowsArePrepended() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 80),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)
        harness.tableView.scrollToRow(at: IndexPath(row: 30, section: 0), at: .top, animated: false)
        harness.tableView.layoutIfNeeded()

        let anchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        let anchoredRowID = rows[anchoredIndexPath.row].id
        let anchoredOffset = harness.tableView.contentOffset.y
            - harness.tableView.rectForRow(at: anchoredIndexPath).minY

        let prependedRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 10, idPrefix: "older") + makeMessages(count: 80),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: prependedRows,
            earlierMessageCount: 0,
            scrollIntent: nil
        )
        pumpLayout(for: harness.tableView)

        let newAnchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        let newAnchoredOffset = harness.tableView.contentOffset.y
            - harness.tableView.rectForRow(at: newAnchoredIndexPath).minY
        XCTAssertEqual(prependedRows[newAnchoredIndexPath.row].id, anchoredRowID)
        XCTAssertLessThan(abs(newAnchoredOffset - anchoredOffset), 2)
    }

    @MainActor
    func testCoordinatorAppliesMessageIntentAfterTargetRowAppears() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 30),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        let scrollIntent = TranscriptScrollIntent(
            target: .message("message-45"),
            anchor: .top,
            animated: false,
            sequence: 1
        )
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 0,
            scrollIntent: scrollIntent
        )
        pumpLayout(for: harness.tableView)

        let expandedRows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 60),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: expandedRows,
            earlierMessageCount: 0,
            scrollIntent: scrollIntent
        )
        pumpLayout(for: harness.tableView)

        XCTAssertEqual(harness.tableView.indexPathsForVisibleRows?.first, IndexPath(row: 45, section: 0))
    }

    @MainActor
    func testCoordinatorKeepsBottomPinnedWhenBoundsShrinkNearBottom() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 80),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)
        XCTAssertLessThanOrEqual(distanceFromBottom(harness.tableView), 170)

        harness.tableView.frame = CGRect(x: 0, y: 0, width: 390, height: 360)
        harness.tableView.setNeedsLayout()
        pumpLayout(for: harness.tableView)

        XCTAssertLessThanOrEqual(distanceFromBottom(harness.tableView), 170)
    }

    @MainActor
    func testCoordinatorIgnoresStaleBottomIntentAfterUserScrollsAway() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 80),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)

        harness.tableView.scrollToRow(at: IndexPath(row: 30, section: 0), at: .top, animated: false)
        harness.tableView.layoutIfNeeded()
        let anchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        let anchoredRowID = rows[anchoredIndexPath.row].id

        let appendedRows = rows + [
            .message(
                ChatMessage(
                    id: "message-80",
                    role: .assistant,
                    createdAt: Date(timeIntervalSince1970: 80),
                    content: [.text("Newest assistant response")]
                )
            )
        ]
        harness.coordinator.update(
            tableView: harness.tableView,
            rows: appendedRows,
            earlierMessageCount: 0,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 2)
        )
        pumpLayout(for: harness.tableView)

        let newAnchoredIndexPath = try XCTUnwrap(harness.tableView.indexPathsForVisibleRows?.first)
        XCTAssertEqual(appendedRows[newAnchoredIndexPath.row].id, anchoredRowID)
        XCTAssertGreaterThan(distanceFromBottom(harness.tableView), 170)
    }

    @MainActor
    func testCoordinatorDoesNotRevealEarlierMessagesDuringInitialProgrammaticBottomScrollWhenContentFits() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 1),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 10,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)

        XCTAssertEqual(harness.recorder.reachTopCount, 0)
    }

    @MainActor
    func testCoordinatorRevealsEarlierMessagesOnceWhenUserScrollsToTop() throws {
        let harness = try makeCoordinatorHarness()
        let rows = TranscriptSurfaceRows.make(
            session: nil,
            messages: makeMessages(count: 40),
            isLoading: false,
            hasAuthoritativeReplay: true,
            snapshotMessageIDs: [],
            optimisticUserMessageIDs: []
        )

        harness.coordinator.update(
            tableView: harness.tableView,
            rows: rows,
            earlierMessageCount: 10,
            scrollIntent: TranscriptScrollIntent(target: .bottom, anchor: .bottom, animated: false, sequence: 1)
        )
        pumpLayout(for: harness.tableView)
        XCTAssertEqual(harness.recorder.reachTopCount, 0)

        harness.tableView.setContentOffset(
            CGPoint(x: 0, y: -harness.tableView.adjustedContentInset.top),
            animated: false
        )
        harness.coordinator.scrollViewDidScroll(harness.tableView)
        pumpLayout(for: harness.tableView)
        XCTAssertEqual(harness.recorder.reachTopCount, 1)

        harness.coordinator.scrollViewDidScroll(harness.tableView)
        pumpLayout(for: harness.tableView)
        XCTAssertEqual(harness.recorder.reachTopCount, 1)
    }
    #endif

    private func makeMessages(count: Int, idPrefix: String = "message") -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(
                id: "\(idPrefix)-\(index)",
                role: index.isMultiple(of: 2) ? .assistant : .user,
                createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                content: [
                    .text("Synthetic message \(index)\n\nThis row intentionally has enough text to require normal chat cell layout.")
                ]
            )
        }
    }

    #if os(iOS)
    @MainActor
    private func makeCoordinatorHarness() throws -> CoordinatorHarness {
        let recorder = CallbackRecorder()
        let coordinator = UIKitTranscriptSurface.Coordinator(
            onReachTop: { recorder.reachTopCount += 1 },
            onNearBottomChanged: { recorder.nearBottomValues.append($0) }
        )
        let tableView = TranscriptTableViewFactory.make(
            dataSource: coordinator.dataSource,
            delegate: coordinator
        )
        tableView.onBoundsSizeChanged = { [weak coordinator] tableView, oldSize, newSize in
            coordinator?.tableViewBoundsDidChange(tableView, oldSize: oldSize, newSize: newSize)
        }
        tableView.onContentSizeChanged = { [weak coordinator] tableView, oldSize, newSize in
            coordinator?.tableViewContentSizeDidChange(tableView, oldSize: oldSize, newSize: newSize)
        }
        let window = try host(tableView)
        return CoordinatorHarness(
            window: window,
            tableView: tableView,
            coordinator: coordinator,
            recorder: recorder
        )
    }

    @MainActor
    private func host(_ tableView: UITableView) throws -> UIWindow {
        tableView.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let controller = UIViewController()
        controller.view.frame = tableView.frame
        controller.view.addSubview(tableView)
        let windowScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: windowScene)
        window.frame = tableView.frame
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return window
    }

    @MainActor
    private func pumpLayout(for tableView: UITableView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        tableView.layoutIfNeeded()
    }

    @MainActor
    private func distanceFromBottom(_ tableView: UITableView) -> CGFloat {
        let visibleBottom = tableView.contentOffset.y
            + tableView.bounds.height
            - tableView.adjustedContentInset.bottom
        return tableView.contentSize.height - visibleBottom
    }

    private final class NoOpTableDelegate: NSObject, UITableViewDelegate {}

    private final class CallbackRecorder {
        var reachTopCount = 0
        var nearBottomValues: [Bool] = []
    }

    private struct CoordinatorHarness {
        let window: UIWindow
        let tableView: UITableView
        let coordinator: UIKitTranscriptSurface.Coordinator
        let recorder: CallbackRecorder
    }
    #endif
}
