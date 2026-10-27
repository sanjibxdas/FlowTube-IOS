import UIKit

/// The result of comparing two lists of identifiers: what to delete, insert, move and reload.
///
/// `UITableView` and `UICollectionView` need the operations as index paths, and iOS 12 has no
/// diffable data source, so this is the Myers-style diff the app applies itself. The algorithm is
/// a longest-common-subsequence walk over the identifiers, which is what keeps a refresh from
/// reloading every row and losing the scroll position.
struct FlowListDiff<Element: Hashable> {

    /// Indexes in the old list that no longer exist.
    let deletions: [Int]
    /// Indexes in the new list that did not exist before.
    let insertions: [Int]
    /// Pairs of (old index, new index) for elements that stayed but changed position.
    let moves: [(from: Int, to: Int)]
    /// Indexes in the new list whose element is present in both but was reported as changed.
    let reloads: [Int]

    var isEmpty: Bool {
        deletions.isEmpty && insertions.isEmpty && moves.isEmpty && reloads.isEmpty
    }

    /// Compares `old` with `new`, treating elements that appear in `changed` as needing a reload.
    static func between(old: [Element], new: [Element], changed: Set<Element> = []) -> FlowListDiff {
        let common = longestCommonSubsequence(old, new)
        let oldKept = Set(common.map { $0.oldIndex })
        let newKept = Set(common.map { $0.newIndex })

        var deletions: [Int] = []
        for index in old.indices where !oldKept.contains(index) {
            deletions.append(index)
        }
        var insertions: [Int] = []
        for index in new.indices where !newKept.contains(index) {
            insertions.append(index)
        }

        // A kept element that sits at a different ordinal among the kept elements has moved.
        var moves: [(from: Int, to: Int)] = []
        for (ordinal, pair) in common.enumerated() {
            if pair.oldIndex != pair.newIndex {
                moves.append((pair.oldIndex, pair.newIndex))
            }
            _ = ordinal
        }

        var reloads: [Int] = []
        if !changed.isEmpty {
            for (index, element) in new.enumerated() where changed.contains(element) {
                reloads.append(index)
            }
        }

        return FlowListDiff(
            deletions: deletions,
            insertions: insertions,
            moves: moves,
            reloads: reloads
        )
    }

    /// The index paths to hand to `deleteRows(at:with:)`.
    func deletionIndexPaths(section: Int = 0) -> [IndexPath] {
        deletions.map { IndexPath(row: $0, section: section) }
    }

    /// The index paths to hand to `insertRows(at:with:)`.
    func insertionIndexPaths(section: Int = 0) -> [IndexPath] {
        insertions.map { IndexPath(row: $0, section: section) }
    }

    /// The index paths to hand to `reloadRows(at:with:)`.
    func reloadIndexPaths(section: Int = 0) -> [IndexPath] {
        reloads.map { IndexPath(row: $0, section: section) }
    }

    // MARK: - Longest common subsequence

    private struct Match {
        let oldIndex: Int
        let newIndex: Int
    }

    /// The longest run of elements, in order, that both lists share. Ties resolve towards the
    /// earlier element in the old list, which keeps the diff stable across refreshes.
    private static func longestCommonSubsequence(_ old: [Element], _ new: [Element]) -> [Match] {
        guard !old.isEmpty, !new.isEmpty else { return [] }

        // The table is O(n*m) in memory. Lists here are feed pages, so the guard keeps a pathological
        // input from allocating hundreds of megabytes; past it, the diff degrades to "everything
        // changed", which is correct, merely less pretty.
        let cellCount = (old.count + 1) * (new.count + 1)
        if cellCount > 4_000_000 {
            return []
        }

        var table = [Int](repeating: 0, count: cellCount)
        let width = new.count + 1
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                if old[i] == new[j] {
                    table[i * width + j] = table[(i + 1) * width + j + 1] + 1
                } else {
                    let skipOld = table[(i + 1) * width + j]
                    let skipNew = table[i * width + j + 1]
                    table[i * width + j] = max(skipOld, skipNew)
                }
            }
        }

        var matches: [Match] = []
        var i = 0
        var j = 0
        while i < old.count && j < new.count {
            if old[i] == new[j] {
                matches.append(Match(oldIndex: i, newIndex: j))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matches
    }
}

extension UITableView {
    /// Applies a diff inside a single-section update, falling back to a full reload when the
    /// changes are so large that animating them would be slower than repainting.
    func applyDiff<Element: Hashable>(
        _ diff: FlowListDiff<Element>,
        in section: Int = 0,
        animation: UITableView.RowAnimation = .fade
    ) {
        let total = diff.deletions.count + diff.insertions.count + diff.moves.count
        guard total > 0 else {
            if !diff.reloads.isEmpty {
                reloadRows(at: diff.reloadIndexPaths(section: section), with: animation)
            }
            return
        }
        if total > 200 {
            reloadData()
            return
        }
        beginUpdates()
        if !diff.deletions.isEmpty {
            deleteRows(at: diff.deletionIndexPaths(section: section), with: animation)
        }
        if !diff.insertions.isEmpty {
            insertRows(at: diff.insertionIndexPaths(section: section), with: animation)
        }
        for move in diff.moves {
            moveRow(
                at: IndexPath(row: move.from, section: section),
                to: IndexPath(row: move.to, section: section)
            )
        }
        if !diff.reloads.isEmpty {
            reloadRows(at: diff.reloadIndexPaths(section: section), with: animation)
        }
        endUpdates()
    }
}

extension UICollectionView {
    /// Applies a diff inside a single-section update.
    func applyDiff<Element: Hashable>(
        _ diff: FlowListDiff<Element>,
        in section: Int = 0
    ) {
        let total = diff.deletions.count + diff.insertions.count + diff.moves.count
        guard total > 0 else {
            if !diff.reloads.isEmpty {
                reloadItems(at: diff.reloadIndexPaths(section: section))
            }
            return
        }
        if total > 200 {
            reloadData()
            return
        }
        performBatchUpdates({
            if !diff.deletions.isEmpty {
                deleteItems(at: diff.deletionIndexPaths(section: section))
            }
            if !diff.insertions.isEmpty {
                insertItems(at: diff.insertionIndexPaths(section: section))
            }
            for move in diff.moves {
                moveItem(
                    at: IndexPath(row: move.from, section: section),
                    to: IndexPath(row: move.to, section: section)
                )
            }
            if !diff.reloads.isEmpty {
                reloadItems(at: diff.reloadIndexPaths(section: section))
            }
        }, completion: nil)
    }
}
