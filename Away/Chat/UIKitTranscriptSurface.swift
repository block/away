#if os(iOS)
import SwiftUI
import UIKit

struct UIKitTranscriptSurface: UIViewRepresentable {
    let rows: [TranscriptSurfaceRow]
    let isLoading: Bool
    let optimisticUserMessageIDs: Set<String>
    let earlierMessageCount: Int
    let scrollIntent: TranscriptScrollIntent?
    let onReachTop: () -> Void
    let onNearBottomChanged: (Bool) -> Void
    let onToggleToolGroup: (String) -> Void

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
        tableView.onContentSizeChanged = { [weak coordinator = context.coordinator] tableView, oldSize, newSize in
            coordinator?.tableViewContentSizeDidChange(tableView, oldSize: oldSize, newSize: newSize)
        }
        return tableView
    }

    func updateUIView(_ tableView: UITableView, context: Context) {
        context.coordinator.onReachTop = onReachTop
        context.coordinator.onNearBottomChanged = onNearBottomChanged
        context.coordinator.dataSource.onToggleToolGroup = onToggleToolGroup
        context.coordinator.update(
            tableView: tableView,
            rows: rows,
            isLoading: isLoading,
            optimisticUserMessageIDs: optimisticUserMessageIDs,
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
        private var hiddenBottomSettleGeneration = 0
        private var wasLoading = false
        private var measuredHeightsByRowID: [String: CGFloat] = [:]
        private var pendingAnimatedBottomFollow = false
        private var pendingBottomEntranceRowIDs: Set<String> = []

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
            isLoading: Bool = false,
            optimisticUserMessageIDs: Set<String> = [],
            earlierMessageCount: Int,
            scrollIntent: TranscriptScrollIntent?
        ) {
            let oldRows = dataSource.rows
            let oldIDs = oldRows.map(\.id)
            let newIDs = newRows.map(\.id)
            let wasNearBottom = isNearBottom(tableView)
            let wasLoadingBeforeUpdate = wasLoading
            let anchor = wasNearBottom ? nil : visibleAnchor(in: tableView, rows: oldRows)
            let shouldApplyScrollIntent = shouldApply(scrollIntent, wasNearBottom: wasNearBottom)
            let rowChange = TranscriptAnimationPolicy.rowChange(oldRows: oldRows, newRows: newRows)
            let shouldAnimateStreamingBottomFollow = TranscriptAnimationPolicy.shouldAnimateStreamingBottomFollow(
                oldRows: oldRows,
                newRows: newRows,
                isLoading: isLoading,
                wasNearBottom: wasNearBottom
            )
            let bottomEntranceRowIDs = TranscriptAnimationPolicy.bottomEntranceInsertedRowIDs(
                oldRows: oldRows,
                newRows: newRows,
                optimisticUserMessageIDs: optimisticUserMessageIDs,
                wasNearBottom: wasNearBottom
            )
            let animatedToolContentIDsByRowID = TranscriptAnimationPolicy.newToolContentIDsByRowID(
                oldRows: oldRows,
                newRows: newRows,
                wasNearBottom: wasNearBottom
            )
            let shouldAnimateContentSizeBottomFollow = shouldAnimateStreamingBottomFollow
                || !animatedToolContentIDsByRowID.isEmpty
            let shouldHideForInitialSettle = shouldHideForInitialBottomSettle(
                oldRows: oldRows,
                newRows: newRows,
                isLoading: isLoading,
                wasLoading: wasLoadingBeforeUpdate,
                tableView: tableView
            )
            wasLoading = isLoading
            currentEarlierMessageCount = earlierMessageCount
            pruneMeasuredHeights(oldRows: oldRows, newRows: newRows)
            if shouldHideForInitialSettle {
                beginHiddenBottomSettle(in: tableView)
            }
            pendingAnimatedBottomFollow = shouldAnimateContentSizeBottomFollow && !shouldHideForInitialSettle
            dataSource.prepareAnimatedContent(animatedToolContentIDsByRowID)

            let didChangeRenderedRows: Bool
            var didApplyAnimatedIdentityChange = false
            switch rowChange {
            case .unchanged:
                dataSource.rows = newRows
                didChangeRenderedRows = reloadChangedVisibleRows(
                    oldRows: oldRows,
                    newRows: newRows,
                    in: tableView
                )
            case .tailAppend(let startIndex, let count)
                where !oldRows.isEmpty:
                dataSource.rows = newRows
                didChangeRenderedRows = applyTailAppend(
                    oldRows: oldRows,
                    newRows: newRows,
                    startIndex: startIndex,
                    count: count,
                    bottomEntranceRowIDs: bottomEntranceRowIDs,
                    in: tableView
                )
                if !wasNearBottom, !shouldApplyScrollIntent, let anchor {
                    restore(anchor, in: tableView)
                }
            case .tailReplacement(let startIndex, let deletedCount, let insertedCount)
                where !oldRows.isEmpty:
                dataSource.rows = newRows
                didChangeRenderedRows = applyTailReplacement(
                    oldRows: oldRows,
                    newRows: newRows,
                    startIndex: startIndex,
                    deletedCount: deletedCount,
                    insertedCount: insertedCount,
                    bottomEntranceRowIDs: bottomEntranceRowIDs,
                    in: tableView
                )
                if !wasNearBottom, !shouldApplyScrollIntent, let anchor {
                    restore(anchor, in: tableView)
                }
            case .tailAppend, .tailReplacement, .nonTailChange:
                if TranscriptRowAnimationPolicy.canAnimateIdentityChange(oldRows: oldRows, newRows: newRows) {
                    didChangeRenderedRows = applyAnimatedRowIdentityChange(
                        oldRows: oldRows,
                        newRows: newRows,
                        in: tableView
                    )
                    didApplyAnimatedIdentityChange = true
                    if !wasNearBottom, !shouldApplyScrollIntent, let anchor {
                        restore(anchor, in: tableView)
                    }
                } else {
                    dataSource.rows = newRows
                    if oldRows.isEmpty {
                        pendingBottomEntranceRowIDs.formUnion(bottomEntranceRowIDs)
                    }
                    UIView.performWithoutAnimation {
                        tableView.reloadData()
                        tableView.layoutIfNeeded()
                    }
                    if oldRows.isEmpty {
                        schedulePendingBottomEntranceCleanup(rowIDs: bottomEntranceRowIDs)
                        animateVisiblePendingBottomEntranceRows(in: tableView)
                    }
                    didChangeRenderedRows = oldIDs != newIDs || oldRows != newRows
                    if !wasNearBottom, !shouldApplyScrollIntent, let anchor {
                        restore(anchor, in: tableView)
                    }
                }
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
            } else if wasNearBottom, didChangeRenderedRows, !didApplyAnimatedIdentityChange {
                if shouldAnimateContentSizeBottomFollow {
                    scheduleAnimatedBottomFollow(in: tableView)
                } else {
                    _ = scrollToBottom(in: tableView, animated: false)
                }
            }

            reportNearBottomIfNeeded(tableView)
            triggerEarlierRevealIfNeeded(earlierMessageCount: earlierMessageCount, tableView: tableView)
            if shouldHideForInitialSettle {
                continueHiddenBottomSettle(
                    in: tableView,
                    generation: hiddenBottomSettleGeneration,
                    pass: 0,
                    previousContentHeight: tableView.contentSize.height
                )
            }
            schedulePreparedAnimatedContentCleanup()
        }

        func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
            guard indexPath.row < dataSource.rows.count else {
                return tableView.estimatedRowHeight
            }

            let row = dataSource.rows[indexPath.row]
            if let measuredHeight = measuredHeightsByRowID[row.id] {
                return measuredHeight
            }

            return TranscriptRowHeightEstimator.estimatedHeight(
                for: row,
                tableWidth: tableView.bounds.width
            )
        }

        func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
            guard indexPath.row < dataSource.rows.count, cell.bounds.height > 0 else { return }
            let rowID = dataSource.rows[indexPath.row].id
            measuredHeightsByRowID[rowID] = cell.bounds.height
            resetBottomEntranceAnimation(on: cell)
            if pendingBottomEntranceRowIDs.remove(rowID) != nil {
                animateCellFromBottom(cell)
            }
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
            pendingAnimatedBottomFollow = false
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

        func tableViewContentSizeDidChange(_ tableView: UITableView, oldSize: CGSize, newSize: CGSize) {
            guard oldSize.height != newSize.height, !dataSource.rows.isEmpty else { return }
            let wasNearBottom = isNearBottom(
                tableView,
                visibleHeight: tableView.bounds.height,
                contentHeight: oldSize.height
            )
            guard tableView.alpha == 0 || wasNearBottom else {
                reportNearBottomIfNeeded(tableView)
                return
            }

            if tableView.alpha == 0 {
                UIView.performWithoutAnimation {
                    pinToBottom(in: tableView)
                }
            } else if pendingAnimatedBottomFollow {
                scheduleAnimatedBottomFollow(in: tableView)
            } else {
                UIView.performWithoutAnimation {
                    pinToBottom(in: tableView)
                }
            }
            reportNearBottomIfNeeded(tableView)
        }

        private func scheduleAnimatedBottomFollow(in tableView: UITableView) {
            DispatchQueue.main.async { [weak self, weak tableView] in
                guard let self,
                      let tableView
                else {
                    return
                }
                self.consumePendingAnimatedBottomFollow(in: tableView)
            }
        }

        private func consumePendingAnimatedBottomFollow(in tableView: UITableView) {
            guard pendingAnimatedBottomFollow else { return }
            pendingAnimatedBottomFollow = false
            guard !tableView.isDragging, !tableView.isDecelerating else {
                reportNearBottomIfNeeded(tableView)
                return
            }
            _ = animateToBottom(in: tableView)
        }

        private func schedulePreparedAnimatedContentCleanup() {
            DispatchQueue.main.async { [weak self] in
                self?.dataSource.clearPreparedAnimatedContent()
            }
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
                guard let row = dataSource.rows.firstIndex(where: { $0.matchesMessageTarget(id) }) else { return false }
                return scrollToRow(row, anchor: scrollIntent.anchor, animated: scrollIntent.animated, in: tableView)
            case .bottom:
                return scrollToBottom(in: tableView, animated: scrollIntent.animated)
            }
        }

        private func scrollToBottom(in tableView: UITableView, animated: Bool) -> Bool {
            guard !dataSource.rows.isEmpty else { return false }
            return scrollToRow(dataSource.rows.count - 1, anchor: .bottom, animated: animated, in: tableView)
        }

        @discardableResult
        private func pinToBottom(in tableView: UITableView) -> Bool {
            guard !dataSource.rows.isEmpty else { return false }
            tableView.layoutIfNeeded()
            tableView.setContentOffset(bottomContentOffset(in: tableView), animated: false)
            return true
        }

        @discardableResult
        private func animateToBottom(in tableView: UITableView) -> Bool {
            guard !dataSource.rows.isEmpty else { return false }
            tableView.layoutIfNeeded()
            let targetOffset = bottomContentOffset(in: tableView)
            guard abs(tableView.contentOffset.y - targetOffset.y) > 0.5 else {
                return true
            }

            isApplyingProgrammaticScroll = true
            programmaticScrollGeneration += 1
            let scrollGeneration = programmaticScrollGeneration
            UIView.animate(
                withDuration: TranscriptAnimationTiming.duration(0.16),
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
            ) {
                tableView.setContentOffset(targetOffset, animated: false)
            } completion: { [weak self, weak tableView] _ in
                guard let self,
                      let tableView,
                      self.programmaticScrollGeneration == scrollGeneration
                else {
                    return
                }
                self.isApplyingProgrammaticScroll = false
                self.reportNearBottomIfNeeded(tableView)
                self.triggerEarlierRevealIfNeeded(
                    earlierMessageCount: self.currentEarlierMessageCount,
                    tableView: tableView
                )
            }
            return true
        }

        private func bottomContentOffset(in tableView: UITableView) -> CGPoint {
            let minimumOffsetY = -tableView.adjustedContentInset.top
            let maximumOffsetY = max(
                minimumOffsetY,
                tableView.contentSize.height - tableView.bounds.height + tableView.adjustedContentInset.bottom
            )
            return CGPoint(x: 0, y: maximumOffsetY)
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
                if anchor == .bottom, indexPath.row == self.dataSource.rows.count - 1 {
                    self.pinToBottom(in: tableView)
                } else {
                    tableView.scrollToRow(at: indexPath, at: position, animated: false)
                }
                self.reportNearBottomIfNeeded(tableView)
                self.triggerEarlierRevealIfNeeded(
                    earlierMessageCount: self.currentEarlierMessageCount,
                    tableView: tableView
                )
            }
            return true
        }

        private func pruneMeasuredHeights(
            oldRows: [TranscriptSurfaceRow],
            newRows: [TranscriptSurfaceRow]
        ) {
            let oldRowsByID = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.id, $0) })
            let newRowsByID = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, $0) })
            measuredHeightsByRowID = measuredHeightsByRowID.filter { rowID, _ in
                guard let oldRow = oldRowsByID[rowID],
                      let newRow = newRowsByID[rowID]
                else {
                    return false
                }

                return oldRow == newRow
            }
        }

        private func shouldHideForInitialBottomSettle(
            oldRows: [TranscriptSurfaceRow],
            newRows: [TranscriptSurfaceRow],
            isLoading: Bool,
            wasLoading: Bool,
            tableView: UITableView
        ) -> Bool {
            let isLoadingReveal = isLoading || wasLoading
            guard isLoadingReveal,
                  tableView.bounds.height > 0,
                  oldRows.isEmpty || oldRows.allSatisfy(\.isSessionShell),
                  newRows.contains(where: \.isTranscriptContent)
            else {
                return false
            }

            let estimatedHeight = newRows.reduce(CGFloat.zero) { partialResult, row in
                partialResult + TranscriptRowHeightEstimator.estimatedHeight(
                    for: row,
                    tableWidth: tableView.bounds.width
                )
            }
            return estimatedHeight > tableView.bounds.height * 1.15
        }

        private func beginHiddenBottomSettle(in tableView: UITableView) {
            hiddenBottomSettleGeneration += 1
            UIView.performWithoutAnimation {
                tableView.alpha = 0
            }
        }

        private func continueHiddenBottomSettle(
            in tableView: UITableView,
            generation: Int,
            pass: Int,
            previousContentHeight: CGFloat
        ) {
            DispatchQueue.main.async { [weak self, weak tableView] in
                guard let self,
                      let tableView,
                      self.hiddenBottomSettleGeneration == generation
                else {
                    return
                }

                UIView.performWithoutAnimation {
                    tableView.layoutIfNeeded()
                    self.pinToBottom(in: tableView)
                }

                let contentHeight = tableView.contentSize.height
                let contentSizeChanged = abs(contentHeight - previousContentHeight) > 0.5
                if pass < 90 || (pass < 120 && contentSizeChanged) {
                    self.continueHiddenBottomSettle(
                        in: tableView,
                        generation: generation,
                        pass: pass + 1,
                        previousContentHeight: contentHeight
                    )
                    return
                }

                UIView.performWithoutAnimation {
                    tableView.alpha = 1
                }
                self.reportNearBottomIfNeeded(tableView)
                self.triggerEarlierRevealIfNeeded(
                    earlierMessageCount: self.currentEarlierMessageCount,
                    tableView: tableView
                )
            }
        }

        private func reloadChangedVisibleRows(
            oldRows: [TranscriptSurfaceRow],
            newRows: [TranscriptSurfaceRow],
            in tableView: UITableView
        ) -> Bool {
            let changedVisibleIndexPaths = changedVisibleRows(
                oldRows: oldRows,
                newRows: newRows,
                in: tableView
            )

            guard !changedVisibleIndexPaths.isEmpty else { return false }
            let animatedIndexPaths = changedVisibleIndexPaths.filter { indexPath in
                TranscriptRowAnimationPolicy.reloadAnimation(
                    oldRow: oldRows[indexPath.row],
                    newRow: newRows[indexPath.row]
                ) != .none
            }
            let nonAnimatedIndexPaths = changedVisibleIndexPaths.filter { indexPath in
                !animatedIndexPaths.contains(indexPath)
            }

            if !nonAnimatedIndexPaths.isEmpty {
                UIView.performWithoutAnimation {
                    tableView.reloadRows(at: nonAnimatedIndexPaths, with: .none)
                    tableView.layoutIfNeeded()
                }
            }

            if !animatedIndexPaths.isEmpty {
                tableView.reloadRows(at: animatedIndexPaths, with: .fade)
                tableView.layoutIfNeeded()
            }
            return true
        }

        private func applyTailAppend(
            oldRows: [TranscriptSurfaceRow],
            newRows: [TranscriptSurfaceRow],
            startIndex: Int,
            count: Int,
            bottomEntranceRowIDs: Set<String>,
            in tableView: UITableView
        ) -> Bool {
            guard count > 0 else {
                return reloadChangedVisibleRows(oldRows: oldRows, newRows: newRows, in: tableView)
            }

            let changedVisibleIndexPaths = changedVisibleRows(
                oldRows: oldRows,
                newRows: newRows,
                in: tableView
            )
            let insertedIndexPaths = (startIndex..<(startIndex + count)).map {
                IndexPath(row: $0, section: 0)
            }
            pendingBottomEntranceRowIDs.formUnion(bottomEntranceRowIDs)
            let updates = {
                if !changedVisibleIndexPaths.isEmpty {
                    tableView.reloadRows(at: changedVisibleIndexPaths, with: .none)
                }
                tableView.insertRows(
                    at: insertedIndexPaths,
                    with: .none
                )
            }

            UIView.performWithoutAnimation {
                tableView.performBatchUpdates(updates)
                tableView.layoutIfNeeded()
            }
            schedulePendingBottomEntranceCleanup(rowIDs: bottomEntranceRowIDs)
            animateVisiblePendingBottomEntranceRows(in: tableView)
            return true
        }

        private func applyTailReplacement(
            oldRows: [TranscriptSurfaceRow],
            newRows: [TranscriptSurfaceRow],
            startIndex: Int,
            deletedCount: Int,
            insertedCount: Int,
            bottomEntranceRowIDs: Set<String>,
            in tableView: UITableView
        ) -> Bool {
            guard deletedCount > 0 || insertedCount > 0 else {
                return reloadChangedVisibleRows(oldRows: oldRows, newRows: newRows, in: tableView)
            }

            let changedVisibleIndexPaths = changedVisibleRows(
                oldRows: oldRows,
                newRows: newRows,
                in: tableView
            )
            .filter { $0.row < startIndex }
            let deletedIndexPaths = (startIndex..<(startIndex + deletedCount)).map {
                IndexPath(row: $0, section: 0)
            }
            let insertedIndexPaths = (startIndex..<(startIndex + insertedCount)).map {
                IndexPath(row: $0, section: 0)
            }
            pendingBottomEntranceRowIDs.formUnion(bottomEntranceRowIDs)

            let updates = {
                if !changedVisibleIndexPaths.isEmpty {
                    tableView.reloadRows(at: changedVisibleIndexPaths, with: .none)
                }
                if !deletedIndexPaths.isEmpty {
                    tableView.deleteRows(at: deletedIndexPaths, with: .none)
                }
                if !insertedIndexPaths.isEmpty {
                    tableView.insertRows(at: insertedIndexPaths, with: .none)
                }
            }

            UIView.performWithoutAnimation {
                tableView.performBatchUpdates(updates)
                tableView.layoutIfNeeded()
            }
            schedulePendingBottomEntranceCleanup(rowIDs: bottomEntranceRowIDs)
            animateVisiblePendingBottomEntranceRows(in: tableView)
            return true
        }

        private func animateCellFromBottom(_ cell: UITableViewCell) {
            cell.contentView.transform = CGAffineTransform(
                translationX: 0,
                y: TranscriptAnimationTiming.offset(28)
            )
            cell.contentView.alpha = 0
            DispatchQueue.main.async { [weak cell] in
                guard let cell else { return }
                UIView.animate(
                    withDuration: TranscriptAnimationTiming.duration(0.24),
                    delay: 0,
                    options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
                ) {
                    cell.contentView.transform = .identity
                    cell.contentView.alpha = 1
                }
            }
        }

        private func animateVisiblePendingBottomEntranceRows(in tableView: UITableView) {
            for cell in tableView.visibleCells {
                guard let indexPath = tableView.indexPath(for: cell),
                      indexPath.row < dataSource.rows.count
                else {
                    continue
                }

                let rowID = dataSource.rows[indexPath.row].id
                if pendingBottomEntranceRowIDs.remove(rowID) != nil {
                    animateCellFromBottom(cell)
                }
            }
        }

        private func schedulePendingBottomEntranceCleanup(rowIDs: Set<String>) {
            guard !rowIDs.isEmpty else { return }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + TranscriptAnimationTiming.duration(1.0)
            ) { [weak self] in
                self?.pendingBottomEntranceRowIDs.subtract(rowIDs)
            }
        }

        private func resetBottomEntranceAnimation(on cell: UITableViewCell) {
            cell.contentView.layer.removeAllAnimations()
            cell.contentView.transform = .identity
            cell.contentView.alpha = 1
        }

        private func changedVisibleRows(
            oldRows: [TranscriptSurfaceRow],
            newRows: [TranscriptSurfaceRow],
            in tableView: UITableView
        ) -> [IndexPath] {
            tableView.indexPathsForVisibleRows?.filter { indexPath in
                guard indexPath.row < oldRows.count, indexPath.row < newRows.count else {
                    return false
                }
                return oldRows[indexPath.row] != newRows[indexPath.row]
            } ?? []
        }

        private func applyAnimatedRowIdentityChange(
            oldRows: [TranscriptSurfaceRow],
            newRows: [TranscriptSurfaceRow],
            in tableView: UITableView
        ) -> Bool {
            let oldIDs = oldRows.map(\.id)
            let newIDs = newRows.map(\.id)
            let newIDSet = Set(newIDs)
            let oldIDSet = Set(oldIDs)
            let deletionIndexPaths = oldRows.enumerated().compactMap { index, row -> IndexPath? in
                newIDSet.contains(row.id) ? nil : IndexPath(row: index, section: 0)
            }
            let insertionIndexPaths = newRows.enumerated().compactMap { index, row -> IndexPath? in
                oldIDSet.contains(row.id) ? nil : IndexPath(row: index, section: 0)
            }
            let reloadPlan = TranscriptRowReloadPlan.sameIndexSurvivors(
                oldRows: oldRows,
                newRows: newRows
            )

            dataSource.rows = newRows
            tableView.performBatchUpdates {
                if !deletionIndexPaths.isEmpty {
                    tableView.deleteRows(at: deletionIndexPaths, with: .fade)
                }
                if !insertionIndexPaths.isEmpty {
                    tableView.insertRows(at: insertionIndexPaths, with: .fade)
                }
                if !reloadPlan.nonAnimatedIndexPaths.isEmpty {
                    tableView.reloadRows(at: reloadPlan.nonAnimatedIndexPaths, with: .none)
                }
                if !reloadPlan.animatedIndexPaths.isEmpty {
                    tableView.reloadRows(at: reloadPlan.animatedIndexPaths, with: .fade)
                }
            } completion: { [weak self, weak tableView] _ in
                guard let self,
                      let tableView
                else {
                    return
                }
                self.reloadChangedVisibleRowsByID(
                    oldRows: oldRows,
                    newRows: newRows,
                    excludingRowIDs: reloadPlan.rowIDs,
                    in: tableView
                )
            }
            tableView.layoutIfNeeded()
            return true
        }

        private func reloadChangedVisibleRowsByID(
            oldRows: [TranscriptSurfaceRow],
            newRows: [TranscriptSurfaceRow],
            excludingRowIDs: Set<String>,
            in tableView: UITableView
        ) {
            let reloadPlan = TranscriptRowReloadPlan.visibleSurvivorsByID(
                oldRows: oldRows,
                newRows: newRows,
                visibleIndexPaths: tableView.indexPathsForVisibleRows ?? [],
                excludingRowIDs: excludingRowIDs
            )

            if !reloadPlan.nonAnimatedIndexPaths.isEmpty {
                UIView.performWithoutAnimation {
                    tableView.reloadRows(at: reloadPlan.nonAnimatedIndexPaths, with: .none)
                    tableView.layoutIfNeeded()
                }
            }

            if !reloadPlan.animatedIndexPaths.isEmpty {
                tableView.reloadRows(at: reloadPlan.animatedIndexPaths, with: .fade)
                tableView.layoutIfNeeded()
            }
        }

        private struct VisibleAnchor {
            var rowID: String
            var messageID: String?
            var rowOrdinalWithinMessage: Int?
            var offsetFromRowTop: CGFloat
        }

        private func visibleAnchor(in tableView: UITableView, rows: [TranscriptSurfaceRow]) -> VisibleAnchor? {
            guard let indexPath = tableView.indexPathsForVisibleRows?.first,
                  indexPath.row < rows.count
            else {
                return nil
            }

            let row = rows[indexPath.row]
            let rect = tableView.rectForRow(at: indexPath)
            return VisibleAnchor(
                rowID: row.id,
                messageID: row.anchorMessageID,
                rowOrdinalWithinMessage: row.anchorMessageID.map { messageID in
                    rows[..<indexPath.row].filter { $0.matchesMessageTarget(messageID) }.count
                },
                offsetFromRowTop: tableView.contentOffset.y - rect.minY
            )
        }

        private func restore(_ anchor: VisibleAnchor, in tableView: UITableView) {
            let anchoredRow = dataSource.rows.firstIndex { $0.id == anchor.rowID }
                ?? anchor.messageID.flatMap { messageID in
                    restoreFallbackRow(
                        messageID: messageID,
                        rowOrdinalWithinMessage: anchor.rowOrdinalWithinMessage
                    )
                }

            guard let row = anchoredRow else {
                return
            }

            tableView.layoutIfNeeded()
            let rect = tableView.rectForRow(at: IndexPath(row: row, section: 0))
            tableView.setContentOffset(
                CGPoint(x: 0, y: rect.minY + anchor.offsetFromRowTop),
                animated: false
            )
        }

        private func restoreFallbackRow(
            messageID: String,
            rowOrdinalWithinMessage: Int?
        ) -> Int? {
            let matchingRows = dataSource.rows.indices.filter { dataSource.rows[$0].matchesMessageTarget(messageID) }
            guard !matchingRows.isEmpty else {
                return nil
            }
            guard let rowOrdinalWithinMessage else {
                return matchingRows.first
            }
            if rowOrdinalWithinMessage < matchingRows.count {
                return matchingRows[rowOrdinalWithinMessage]
            }
            return matchingRows.last
        }

        private func isNearBottom(_ tableView: UITableView) -> Bool {
            isNearBottom(tableView, visibleHeight: tableView.bounds.height)
        }

        private func isNearBottom(_ tableView: UITableView, visibleHeight: CGFloat) -> Bool {
            isNearBottom(tableView, visibleHeight: visibleHeight, contentHeight: tableView.contentSize.height)
        }

        private func isNearBottom(
            _ tableView: UITableView,
            visibleHeight: CGFloat,
            contentHeight: CGFloat
        ) -> Bool {
            let threshold: CGFloat = 160
            let visibleBottom = tableView.contentOffset.y + visibleHeight - tableView.adjustedContentInset.bottom
            return contentHeight - visibleBottom <= threshold
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

private extension TranscriptSurfaceRow {
    var isSessionShell: Bool {
        if case .sessionShell = self {
            return true
        }
        return false
    }

    var isMessage: Bool {
        if case .message = self {
            return true
        }
        return false
    }

    var isAssistantProgress: Bool {
        if case .assistantProgress = self {
            return true
        }
        return false
    }

    var isTranscriptContent: Bool {
        isMessage || isAssistantProgress || isToolPresentation
    }

    var isToolPresentation: Bool {
        switch self {
        case .toolGroup, .toolStep:
            return true
        case .sessionShell, .message, .assistantProgress:
            return false
        }
    }

    var anchorMessageID: String? {
        switch self {
        case .sessionShell:
            return nil
        case .message(let message):
            return message.id.transcriptBaseMessageID
        case .assistantProgress(let anchorMessageID):
            return anchorMessageID
        case .toolGroup(let group):
            return group.id.transcriptBaseMessageID
        case .toolStep(let step):
            return (step.groupID ?? step.id).transcriptBaseMessageID
        }
    }
}

private extension String {
    var transcriptBaseMessageID: String {
        guard let separator = range(of: "::") else {
            return self
        }
        return String(self[..<separator.lowerBound])
    }
}

enum TranscriptRowAnimationPolicy {
    private static let maximumAnimatedToolRowChanges = 32

    static func canAnimateIdentityChange(
        oldRows: [TranscriptSurfaceRow],
        newRows: [TranscriptSurfaceRow]
    ) -> Bool {
        guard !oldRows.isEmpty, !newRows.isEmpty else {
            return false
        }

        let oldIDs = oldRows.map(\.id)
        let newIDs = newRows.map(\.id)
        guard Set(oldIDs).count == oldIDs.count,
              Set(newIDs).count == newIDs.count
        else {
            return false
        }

        let oldIDSet = Set(oldIDs)
        let newIDSet = Set(newIDs)
        let insertedRows = newRows.filter { !oldIDSet.contains($0.id) }
        let deletedRows = oldRows.filter { !newIDSet.contains($0.id) }
        let changedCount = insertedRows.count + deletedRows.count
        guard changedCount > 0,
              changedCount <= maximumAnimatedToolRowChanges
        else {
            return false
        }

        let changedRows = insertedRows + deletedRows
        guard changedRows.allSatisfy(\.isToolPresentation) else {
            return false
        }

        let oldSurvivors = oldRows.map(\.id).filter(newIDSet.contains)
        let newSurvivors = newRows.map(\.id).filter(oldIDSet.contains)
        return oldSurvivors == newSurvivors
    }

    static func reloadAnimation(
        oldRow: TranscriptSurfaceRow,
        newRow: TranscriptSurfaceRow
    ) -> UITableView.RowAnimation {
        guard oldRow != newRow else {
            return .none
        }
        if oldRow.isToolPresentation || newRow.isToolPresentation {
            return .fade
        }
        return .none
    }
}

struct TranscriptRowReloadPlan: Equatable {
    var animatedIndexPaths: [IndexPath]
    var nonAnimatedIndexPaths: [IndexPath]
    var rowIDs: Set<String>

    static func sameIndexSurvivors(
        oldRows: [TranscriptSurfaceRow],
        newRows: [TranscriptSurfaceRow]
    ) -> TranscriptRowReloadPlan {
        let changedIndexPaths = oldRows.enumerated().compactMap { index, oldRow -> IndexPath? in
            guard index < newRows.count,
                  oldRow.id == newRows[index].id,
                  oldRow != newRows[index]
            else {
                return nil
            }
            return IndexPath(row: index, section: 0)
        }

        return plan(
            indexPaths: changedIndexPaths,
            oldRowForNewIndexPath: { indexPath in oldRows[indexPath.row] },
            newRows: newRows
        )
    }

    static func visibleSurvivorsByID(
        oldRows: [TranscriptSurfaceRow],
        newRows: [TranscriptSurfaceRow],
        visibleIndexPaths: [IndexPath],
        excludingRowIDs: Set<String>
    ) -> TranscriptRowReloadPlan {
        let oldRowsByID = Dictionary(uniqueKeysWithValues: oldRows.map { ($0.id, $0) })
        let changedIndexPaths = visibleIndexPaths.filter { indexPath in
            guard indexPath.row < newRows.count,
                  let oldRow = oldRowsByID[newRows[indexPath.row].id],
                  !excludingRowIDs.contains(newRows[indexPath.row].id)
            else {
                return false
            }
            return oldRow != newRows[indexPath.row]
        }

        return plan(
            indexPaths: changedIndexPaths,
            oldRowForNewIndexPath: { indexPath in
                oldRowsByID[newRows[indexPath.row].id]
            },
            newRows: newRows
        )
    }

    private static func plan(
        indexPaths: [IndexPath],
        oldRowForNewIndexPath: (IndexPath) -> TranscriptSurfaceRow?,
        newRows: [TranscriptSurfaceRow]
    ) -> TranscriptRowReloadPlan {
        let animatedIndexPaths = indexPaths.filter { indexPath in
            guard indexPath.row < newRows.count,
                  let oldRow = oldRowForNewIndexPath(indexPath)
            else {
                return false
            }
            return TranscriptRowAnimationPolicy.reloadAnimation(
                oldRow: oldRow,
                newRow: newRows[indexPath.row]
            ) != .none
        }
        let nonAnimatedIndexPaths = indexPaths.filter { indexPath in
            !animatedIndexPaths.contains(indexPath)
        }
        let rowIDs = Set(indexPaths.compactMap { indexPath in
            indexPath.row < newRows.count ? newRows[indexPath.row].id : nil
        })
        return TranscriptRowReloadPlan(
            animatedIndexPaths: animatedIndexPaths,
            nonAnimatedIndexPaths: nonAnimatedIndexPaths,
            rowIDs: rowIDs
        )
    }
}

enum TranscriptRowHeightEstimator {
    private static let rowHorizontalPadding: CGFloat = 28
    private static let messageRowVerticalPadding: CGFloat = 14
    private static let sessionRowVerticalPadding: CGFloat = 32
    private static let assistantTrailingSpacer: CGFloat = 24
    private static let userLeadingSpacer: CGFloat = 40
    private static let userBubbleMaxWidth: CGFloat = 310
    private static let userBubbleHorizontalPadding: CGFloat = 28
    private static let userBubbleVerticalPadding: CGFloat = 20
    private static let assistantBubbleVerticalPadding: CGFloat = 4
    private static let bodyLineHeight: CGFloat = 20
    private static let captionLineHeight: CGFloat = 16
    private static let contentSpacing: CGFloat = 8
    private static let averageBodyCharacterWidth: CGFloat = 7.0
    private static let minimumTextWidth: CGFloat = 120
    private static let textRenderLimit = 12_000
    private static let maximumEstimatedTextHeight: CGFloat = 7_200

    static func estimatedHeight(for row: TranscriptSurfaceRow, tableWidth: CGFloat) -> CGFloat {
        switch row {
        case .sessionShell(let session):
            return estimatedSessionShellHeight(session)
        case .message(let message):
            return estimatedMessageHeight(message, tableWidth: tableWidth)
        case .assistantProgress:
            return messageRowVerticalPadding + assistantBubbleVerticalPadding + captionLineHeight + 16
        case .toolGroup:
            return 34
        case .toolStep:
            return 30
        }
    }

    private static func estimatedSessionShellHeight(_ session: SessionSummary) -> CGFloat {
        var height = sessionRowVerticalPadding
        height += 22

        if let subtitle = session.subtitle, !subtitle.isEmpty {
            height += 8 + estimatedWrappedTextHeight(
                subtitle,
                availableWidth: 320,
                lineHeight: 18,
                averageCharacterWidth: 6.5,
                maximumHeight: 72
            )
        }

        if let cwd = session.cwd, !cwd.isEmpty {
            height += 8 + min(
                estimatedWrappedTextHeight(
                    cwd,
                    availableWidth: 320,
                    lineHeight: captionLineHeight,
                    averageCharacterWidth: 6.2,
                    maximumHeight: captionLineHeight * 2
                ),
                captionLineHeight * 2
            )
        }

        if session.messageCount > 0 || session.activityAt != nil {
            height += 8 + captionLineHeight
        }

        return max(height, 72)
    }

    private static func estimatedMessageHeight(_ message: ChatMessage, tableWidth: CGFloat) -> CGFloat {
        let availableTextWidth = textWidth(for: message.role, tableWidth: tableWidth)
        var contentHeight: CGFloat = 0

        for content in message.content {
            let height = estimatedContentHeight(content, availableTextWidth: availableTextWidth)
            if contentHeight > 0 {
                contentHeight += contentSpacing
            }
            contentHeight += height
        }

        if message.isStreaming, message.content.isEmpty {
            contentHeight = captionLineHeight
        }

        let bubbleVerticalPadding = message.role == .user ? userBubbleVerticalPadding : assistantBubbleVerticalPadding
        return max(messageRowVerticalPadding + bubbleVerticalPadding + contentHeight, 44)
    }

    private static func estimatedContentHeight(
        _ content: ChatContent,
        availableTextWidth: CGFloat
    ) -> CGFloat {
        switch content {
        case .text(let text):
            return estimatedTranscriptTextHeight(text, availableWidth: availableTextWidth)
        case .image:
            return 22
        case .tool(let tool):
            return estimatedToolHeight(tool, availableWidth: availableTextWidth)
        case .system(let text):
            return estimatedWrappedTextHeight(
                text,
                availableWidth: availableTextWidth,
                lineHeight: captionLineHeight,
                averageCharacterWidth: 6.2,
                maximumHeight: 600
            )
        }
    }

    private static func estimatedTranscriptTextHeight(
        _ text: String,
        availableWidth: CGFloat
    ) -> CGFloat {
        let displayText = String(text.prefix(textRenderLimit))
        var height = estimatedWrappedTextHeight(
            displayText,
            availableWidth: availableWidth,
            lineHeight: bodyLineHeight,
            averageCharacterWidth: averageBodyCharacterWidth,
            maximumHeight: maximumEstimatedTextHeight
        )

        if text.count > textRenderLimit {
            height += 6 + captionLineHeight
        }

        return height
    }

    private static func estimatedToolHeight(
        _: ToolActivity,
        availableWidth: CGFloat
    ) -> CGFloat {
        24
    }

    private static func textWidth(for role: ChatMessage.Role, tableWidth: CGFloat) -> CGFloat {
        let safeTableWidth = max(tableWidth, minimumTextWidth + rowHorizontalPadding + assistantTrailingSpacer)
        switch role {
        case .user:
            let bubbleWidth = min(
                userBubbleMaxWidth,
                safeTableWidth - rowHorizontalPadding - userLeadingSpacer
            )
            return max(bubbleWidth - userBubbleHorizontalPadding, minimumTextWidth)
        case .assistant, .system:
            return max(safeTableWidth - rowHorizontalPadding - assistantTrailingSpacer, minimumTextWidth)
        }
    }

    private static func estimatedWrappedTextHeight(
        _ text: String,
        availableWidth: CGFloat,
        lineHeight: CGFloat,
        averageCharacterWidth: CGFloat,
        maximumHeight: CGFloat
    ) -> CGFloat {
        let safeWidth = max(availableWidth, minimumTextWidth)
        let charactersPerLine = max(Int((safeWidth / averageCharacterWidth).rounded(.down)), 1)
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) { partialResult, line in
            partialResult + max(1, Int(ceil(Double(line.count) / Double(charactersPerLine))))
        }

        return min(max(CGFloat(lineCount) * lineHeight, lineHeight), maximumHeight)
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
    var onContentSizeChanged: ((TranscriptTableView, CGSize, CGSize) -> Void)?

    private var lastLaidOutBoundsSize: CGSize = .zero
    private var lastLaidOutContentSize: CGSize = .zero

    override func layoutSubviews() {
        let oldSize = lastLaidOutBoundsSize
        let oldContentSize = lastLaidOutContentSize
        super.layoutSubviews()

        let newSize = bounds.size
        let newContentSize = contentSize
        defer {
            lastLaidOutBoundsSize = newSize
            lastLaidOutContentSize = newContentSize
        }
        if oldSize != .zero, oldSize != newSize {
            onBoundsSizeChanged?(self, oldSize, newSize)
        }
        if oldContentSize != .zero, oldContentSize != newContentSize {
            onContentSizeChanged?(self, oldContentSize, newContentSize)
        }
    }
}

final class TranscriptTableViewDataSource: NSObject, UITableViewDataSource {
    static let cellIdentifier = "TranscriptCell"

    var rows: [TranscriptSurfaceRow] = []
    var onToggleToolGroup: (String) -> Void = { _ in }
    private(set) var createdCellCount = 0
    private var animatedContentIDsByRowID: [String: Set<String>] = [:]

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellIdentifier, for: indexPath)
        createdCellCount += 1
        configure(cell, row: rows[indexPath.row])
        return cell
    }

    func prepareAnimatedContent(_ contentIDsByRowID: [String: Set<String>]) {
        animatedContentIDsByRowID = contentIDsByRowID
    }

    func clearPreparedAnimatedContent() {
        animatedContentIDsByRowID.removeAll()
    }

    private func consumeAnimatedContentIDs(for rowID: String) -> Set<String> {
        animatedContentIDsByRowID.removeValue(forKey: rowID) ?? []
    }

    private func configure(_ cell: UITableViewCell, row: TranscriptSurfaceRow) {
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        let animatedContentIDs = consumeAnimatedContentIDs(for: row.id)
        cell.contentConfiguration = UIHostingConfiguration {
            TranscriptSurfaceRowView(
                row: row,
                animatedContentIDs: animatedContentIDs,
                onToggleToolGroup: onToggleToolGroup
            )
        }
        .margins(.all, 0)
    }
}
#endif
