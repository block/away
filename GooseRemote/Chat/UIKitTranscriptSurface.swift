#if os(iOS)
import SwiftUI
import UIKit

struct UIKitTranscriptSurface: UIViewRepresentable {
    let rows: [TranscriptSurfaceRow]
    let earlierMessageCount: Int
    let scrollIntent: TranscriptScrollIntent?
    let onReachTop: () -> Void
    let onNearBottomChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onReachTop: onReachTop,
            onNearBottomChanged: onNearBottomChanged
        )
    }

    func makeUIView(context: Context) -> UITableView {
        let tableView = TranscriptTableViewFactory.make(
            dataSource: context.coordinator.dataSource,
            delegate: context.coordinator
        )
        tableView.onBoundsSizeChanged = { [weak coordinator = context.coordinator] tableView, oldSize, newSize in
            coordinator?.tableViewBoundsDidChange(tableView, oldSize: oldSize, newSize: newSize)
        }
        return tableView
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.onReachTop = onReachTop
        context.coordinator.onNearBottomChanged = onNearBottomChanged
        context.coordinator.update(
            tableView: tableView,
            rows: rows,
            earlierMessageCount: earlierMessageCount,
            scrollIntent: scrollIntent
        )
    }

    final class Coordinator: NSObject, UITableViewDelegate {
        let dataSource = TranscriptTableViewDataSource()
        var onReachTop: () -> Void
        var onNearBottomChanged: (Bool) -> Void

        private var appliedScrollSequence: Int?
        private var lastReportedNearBottom = true
        private var currentEarlierMessageCount = 0
        private var lastTriggeredEarlierMessageCount = 0
        private var didInitialBottomScroll = false
        private var isApplyingProgrammaticScroll = false
        private var programmaticScrollGeneration = 0

        init(
            onReachTop: @escaping () -> Void,
            onNearBottomChanged: @escaping (Bool) -> Void
        ) {
            self.onReachTop = onReachTop
            self.onNearBottomChanged = onNearBottomChanged
        }

        func update(
            tableView: UITableView,
            rows newRows: [TranscriptSurfaceRow],
            earlierMessageCount: Int,
            scrollIntent: TranscriptScrollIntent?
        ) {
            let oldRows = dataSource.rows
            let oldIDs = oldRows.map(\.id)
            let newIDs = newRows.map(\.id)
            let wasNearBottom = isNearBottom(tableView)
            let anchor = wasNearBottom ? nil : visibleAnchor(in: tableView, rows: oldRows)
            let shouldApplyScrollIntent = shouldApply(scrollIntent, wasNearBottom: wasNearBottom)
            currentEarlierMessageCount = earlierMessageCount

            dataSource.rows = newRows

            let didChangeRenderedRows: Bool
            if oldIDs != newIDs {
                UIView.performWithoutAnimation {
                    tableView.reloadData()
                    tableView.layoutIfNeeded()
                }
                didChangeRenderedRows = true
                if !wasNearBottom, !shouldApplyScrollIntent, let anchor {
                    restore(anchor, in: tableView)
                }
            } else {
                didChangeRenderedRows = reloadChangedVisibleRows(oldRows: oldRows, newRows: newRows, in: tableView)
            }

            if shouldApplyScrollIntent, let scrollIntent {
                if apply(scrollIntent, in: tableView) {
                    appliedScrollSequence = scrollIntent.sequence
                    if case .bottom = scrollIntent.target {
                        didInitialBottomScroll = true
                    }
                }
            } else if !didInitialBottomScroll, !newRows.isEmpty {
                didInitialBottomScroll = true
                _ = scrollToBottom(in: tableView, animated: false)
            } else if wasNearBottom, didChangeRenderedRows {
                _ = scrollToBottom(in: tableView, animated: false)
            }

            reportNearBottomIfNeeded(tableView)
            triggerEarlierRevealIfNeeded(earlierMessageCount: earlierMessageCount, tableView: tableView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let tableView = scrollView as? UITableView else { return }
            reportNearBottomIfNeeded(tableView)
            triggerEarlierRevealIfNeeded(
                earlierMessageCount: currentEarlierMessageCount,
                tableView: tableView
            )
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isApplyingProgrammaticScroll = false
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            isApplyingProgrammaticScroll = false
        }

        func tableViewBoundsDidChange(_ tableView: UITableView, oldSize: CGSize, newSize: CGSize) {
            guard oldSize.height != newSize.height, !dataSource.rows.isEmpty else { return }
            guard isNearBottom(tableView, visibleHeight: oldSize.height) else {
                reportNearBottomIfNeeded(tableView)
                return
            }

            _ = scrollToBottom(in: tableView, animated: false)
        }

        private func shouldApply(_ scrollIntent: TranscriptScrollIntent?, wasNearBottom: Bool) -> Bool {
            guard let scrollIntent else { return false }
            guard appliedScrollSequence != scrollIntent.sequence else { return false }
            guard case .bottom = scrollIntent.target, didInitialBottomScroll else { return true }
            return wasNearBottom
        }

        private func apply(_ scrollIntent: TranscriptScrollIntent, in tableView: UITableView) -> Bool {
            switch scrollIntent.target {
            case .message(let id):
                guard let row = dataSource.rows.firstIndex(where: { $0.id == "message:\(id)" }) else { return false }
                return scrollToRow(row, anchor: scrollIntent.anchor, animated: scrollIntent.animated, in: tableView)
            case .bottom:
                return scrollToBottom(in: tableView, animated: scrollIntent.animated)
            }
        }

        private func scrollToBottom(in tableView: UITableView, animated: Bool) -> Bool {
            guard !dataSource.rows.isEmpty else { return false }
            return scrollToRow(dataSource.rows.count - 1, anchor: .bottom, animated: animated, in: tableView)
        }

        private func scrollToRow(
            _ row: Int,
            anchor: TranscriptScrollAnchor,
            animated: Bool,
            in tableView: UITableView
        ) -> Bool {
            guard row >= 0, row < dataSource.rows.count else { return false }
            let indexPath = IndexPath(row: row, section: 0)
            let position: UITableView.ScrollPosition
            switch anchor {
            case .top:
                position = .top
            case .center:
                position = .middle
            case .bottom:
                position = .bottom
            }

            isApplyingProgrammaticScroll = true
            programmaticScrollGeneration += 1
            let scrollGeneration = programmaticScrollGeneration
            tableView.layoutIfNeeded()
            tableView.scrollToRow(at: indexPath, at: position, animated: animated)
            guard !animated else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak tableView] in
                    guard let self,
                          let tableView,
                          self.isApplyingProgrammaticScroll,
                          self.programmaticScrollGeneration == scrollGeneration
                    else {
                        return
                    }
                    self.isApplyingProgrammaticScroll = false
                self.triggerEarlierRevealIfNeeded(
                    earlierMessageCount: self.currentEarlierMessageCount,
                    tableView: tableView
                )
            }
                return true
            }

            DispatchQueue.main.async { [weak self, weak tableView] in
                guard let self,
                      let tableView
                else {
                    return
                }
                guard self.programmaticScrollGeneration == scrollGeneration else {
                    return
                }
                defer { self.isApplyingProgrammaticScroll = false }
                guard indexPath.row < self.dataSource.rows.count else {
                    return
                }

                tableView.layoutIfNeeded()
                tableView.scrollToRow(at: indexPath, at: position, animated: false)
                self.reportNearBottomIfNeeded(tableView)
                self.triggerEarlierRevealIfNeeded(
                    earlierMessageCount: self.currentEarlierMessageCount,
                    tableView: tableView
                )
            }
            return true
        }

        private func reloadChangedVisibleRows(
            oldRows: [TranscriptSurfaceRow],
            newRows: [TranscriptSurfaceRow],
            in tableView: UITableView
        ) -> Bool {
            let changedVisibleIndexPaths = tableView.indexPathsForVisibleRows?.filter { indexPath in
                guard indexPath.row < oldRows.count, indexPath.row < newRows.count else {
                    return false
                }
                return oldRows[indexPath.row] != newRows[indexPath.row]
            } ?? []

            guard !changedVisibleIndexPaths.isEmpty else { return false }
            UIView.performWithoutAnimation {
                tableView.reloadRows(at: changedVisibleIndexPaths, with: .none)
                tableView.layoutIfNeeded()
            }
            return true
        }

        private struct VisibleAnchor {
            var rowID: String
            var offsetFromRowTop: CGFloat
        }

        private func visibleAnchor(in tableView: UITableView, rows: [TranscriptSurfaceRow]) -> VisibleAnchor? {
            guard let indexPath = tableView.indexPathsForVisibleRows?.first,
                  indexPath.row < rows.count
            else {
                return nil
            }

            let rect = tableView.rectForRow(at: indexPath)
            return VisibleAnchor(
                rowID: rows[indexPath.row].id,
                offsetFromRowTop: tableView.contentOffset.y - rect.minY
            )
        }

        private func restore(_ anchor: VisibleAnchor, in tableView: UITableView) {
            guard let row = dataSource.rows.firstIndex(where: { $0.id == anchor.rowID }) else {
                return
            }

            tableView.layoutIfNeeded()
            let rect = tableView.rectForRow(at: IndexPath(row: row, section: 0))
            tableView.setContentOffset(
                CGPoint(x: 0, y: rect.minY + anchor.offsetFromRowTop),
                animated: false
            )
        }

        private func isNearBottom(_ tableView: UITableView) -> Bool {
            isNearBottom(tableView, visibleHeight: tableView.bounds.height)
        }

        private func isNearBottom(_ tableView: UITableView, visibleHeight: CGFloat) -> Bool {
            let threshold: CGFloat = 160
            let visibleBottom = tableView.contentOffset.y + visibleHeight - tableView.adjustedContentInset.bottom
            return tableView.contentSize.height - visibleBottom <= threshold
        }

        private func isNearTop(_ tableView: UITableView) -> Bool {
            tableView.contentOffset.y + tableView.adjustedContentInset.top <= 120
        }

        private func reportNearBottomIfNeeded(_ tableView: UITableView) {
            let nearBottom = isNearBottom(tableView)
            guard nearBottom != lastReportedNearBottom else { return }
            lastReportedNearBottom = nearBottom
            DispatchQueue.main.async { [onNearBottomChanged] in
                onNearBottomChanged(nearBottom)
            }
        }

        private func triggerEarlierRevealIfNeeded(
            earlierMessageCount: Int,
            tableView: UITableView
        ) {
            guard earlierMessageCount > 0 else {
                lastTriggeredEarlierMessageCount = 0
                return
            }
            guard earlierMessageCount != lastTriggeredEarlierMessageCount else { return }
            guard isNearTop(tableView), !isApplyingProgrammaticScroll else { return }

            lastTriggeredEarlierMessageCount = earlierMessageCount
            DispatchQueue.main.async { [onReachTop] in
                onReachTop()
            }
        }
    }
}

@MainActor
enum TranscriptTableViewFactory {
    static func make(
        dataSource: UITableViewDataSource,
        delegate: UITableViewDelegate
    ) -> TranscriptTableView {
        let tableView = TranscriptTableView(frame: .zero, style: .plain)
        configure(tableView, dataSource: dataSource, delegate: delegate)
        return tableView
    }

    static func configure(
        _ tableView: UITableView,
        dataSource: UITableViewDataSource,
        delegate: UITableViewDelegate
    ) {
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: TranscriptTableViewDataSource.cellIdentifier)
        tableView.dataSource = dataSource
        tableView.delegate = delegate
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 140
        tableView.keyboardDismissMode = .interactive
        tableView.alwaysBounceVertical = true
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.showsVerticalScrollIndicator = true
    }
}

final class TranscriptTableView: UITableView {
    var onBoundsSizeChanged: ((TranscriptTableView, CGSize, CGSize) -> Void)?

    private var lastLaidOutBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        let oldSize = lastLaidOutBoundsSize
        super.layoutSubviews()

        let newSize = bounds.size
        defer { lastLaidOutBoundsSize = newSize }
        guard oldSize != .zero, oldSize != newSize else { return }
        onBoundsSizeChanged?(self, oldSize, newSize)
    }
}

final class TranscriptTableViewDataSource: NSObject, UITableViewDataSource {
    static let cellIdentifier = "TranscriptCell"

    var rows: [TranscriptSurfaceRow] = []
    private(set) var createdCellCount = 0

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        createdCellCount += 1
        configure(cell, row: rows[indexPath.row])
        return cell
    }

    private func configure(_ cell: UITableViewCell, row: TranscriptSurfaceRow) {
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        cell.contentConfiguration = UIHostingConfiguration {
            TranscriptSurfaceRowView(row: row)
        }
        .margins(.all, 0)
    }
}
#endif
