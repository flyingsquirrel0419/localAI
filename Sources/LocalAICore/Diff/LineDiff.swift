import Foundation

public enum DiffLineKind: String, Sendable, Equatable, Codable {
    case context
    case added
    case removed
}

/// One line in a rendered diff, with 1-based line numbers on each side
/// (nil where the line does not exist on that side).
public struct DiffLine: Sendable, Equatable, Codable {
    public let kind: DiffLineKind
    public let text: String
    public let oldLineNumber: Int?
    public let newLineNumber: Int?

    public init(kind: DiffLineKind, text: String, oldLineNumber: Int?, newLineNumber: Int?) {
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// A contiguous group of changes plus surrounding context lines.
public struct DiffHunk: Sendable, Equatable, Codable {
    /// 1-based start line of the hunk in the old text.
    public let oldStart: Int
    /// Number of old-text lines the hunk spans (context + removed).
    public let oldCount: Int
    /// 1-based start line of the hunk in the new text.
    public let newStart: Int
    /// Number of new-text lines the hunk spans (context + added).
    public let newCount: Int
    public let lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct DiffStats: Sendable, Equatable, Codable {
    public let added: Int
    public let removed: Int
}

/// Myers line diff. Produces hunks with a configurable amount of context.
public enum LineDiff {
    /// Compute the diff between two texts as hunks with `context` lines of
    /// context around each change group (default 3, unified-diff style).
    public static func diff(old: String, new: String, context: Int = 3) -> [DiffHunk] {
        let oldLines = splitLines(old)
        let newLines = splitLines(new)
        let ops = myers(old: oldLines, new: newLines)
        return buildHunks(ops: ops, oldLines: oldLines, newLines: newLines, context: context)
    }

    public static func stats(hunks: [DiffHunk]) -> DiffStats {
        var added = 0
        var removed = 0
        for hunk in hunks {
            for line in hunk.lines {
                switch line.kind {
                case .added: added += 1
                case .removed: removed += 1
                case .context: break
                }
            }
        }
        return DiffStats(added: added, removed: removed)
    }

    static func splitLines(_ text: String) -> [String] {
        // Split keeping semantic line boundaries; a trailing newline does not
        // produce a phantom empty final line.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let last = lines.last, last.isEmpty, text.hasSuffix("\n") {
            lines.removeLast()
        }
        if text.isEmpty { return [] }
        return lines
    }

    // MARK: - Myers algorithm

    private enum EditOp {
        case keep(oldIndex: Int, newIndex: Int)
        case delete(oldIndex: Int)
        case insert(newIndex: Int)
    }

    /// Myers O(ND) diff over the two line arrays. Returns the minimal edit script.
    private static func myers(old: [String], new: [String]) -> [EditOp] {
        let n = old.count
        let m = new.count
        if n == 0 && m == 0 { return [] }
        if n == 0 { return (0..<m).map { .insert(newIndex: $0) } }
        if m == 0 { return (0..<n).map { .delete(oldIndex: $0) } }

        let max = n + m
        var v = [Int](repeating: 0, count: 2 * max + 1)
        var trace: [[Int]] = []
        let offset = max

        outer: for d in 0...max {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n && y < m && old[x] == new[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n && y >= m { break outer }
                k += 2
            }
        }

        // Backtrack. trace[i] holds the frontier at the START of step i, i.e.
        // after i-1 steps; backtracking step d therefore reads trace[d].
        var ops: [EditOp] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 1, by: -1) {
            let vPrev = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vPrev[offset + k - 1] < vPrev[offset + k + 1]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = vPrev[offset + prevK]
            let prevY = prevX - prevK
            while x > prevX && y > prevY {
                ops.append(.keep(oldIndex: x - 1, newIndex: y - 1))
                x -= 1
                y -= 1
            }
            if x == prevX + 1 && y == prevY {
                ops.append(.delete(oldIndex: x - 1))
                x -= 1
            } else if y == prevY + 1 && x == prevX {
                ops.append(.insert(newIndex: y - 1))
                y -= 1
            }
        }
        while x > 0 && y > 0 {
            ops.append(.keep(oldIndex: x - 1, newIndex: y - 1))
            x -= 1
            y -= 1
        }
        return ops.reversed()
    }

    // MARK: - Hunk construction

    private static func buildHunks(
        ops: [EditOp],
        oldLines: [String],
        newLines: [String],
        context: Int
    ) -> [DiffHunk] {
        // Group ops into change clusters separated by > 2*context keep lines.
        var clusters: [[EditOp]] = []
        var current: [EditOp] = []
        var keepRun = 0
        for op in ops {
            switch op {
            case .keep:
                keepRun += 1
                current.append(op)
                if keepRun > 2 * context {
                    // Close the current cluster, trimming trailing keeps to `context`.
                    let trimmed = Array(current.dropLast(keepRun - context))
                    if trimmed.contains(where: { isChange($0) }) {
                        clusters.append(trimmed)
                    }
                    current = [op]
                    keepRun = 1
                }
            case .delete, .insert:
                keepRun = 0
                current.append(op)
            }
        }
        if current.contains(where: { isChange($0) }) {
            clusters.append(current)
        }

        return clusters.map { cluster in
            // Trim leading keeps to at most `context`.
            var leading = 0
            while leading < cluster.count, case .keep = cluster[leading] { leading += 1 }
            let start = max(0, leading - context)
            // Trim trailing keeps to at most `context`.
            var trailing = 0
            var idx = cluster.count - 1
            while idx >= 0, case .keep = cluster[idx] { trailing += 1; idx -= 1 }
            let end = cluster.count - max(0, trailing - context)
            let slice = Array(cluster[start..<end])

            var lines: [DiffLine] = []
            var oldStart = 0
            var newStart = 0
            var oldCount = 0
            var newCount = 0
            for op in slice {
                switch op {
                case .keep(let oi, let ni):
                    if lines.isEmpty { oldStart = oi + 1; newStart = ni + 1 }
                    lines.append(DiffLine(kind: .context, text: oldLines[oi],
                                          oldLineNumber: oi + 1, newLineNumber: ni + 1))
                    oldCount += 1
                    newCount += 1
                case .delete(let oi):
                    if lines.isEmpty { oldStart = oi + 1; newStart = oi + 1 }
                    lines.append(DiffLine(kind: .removed, text: oldLines[oi],
                                          oldLineNumber: oi + 1, newLineNumber: nil))
                    oldCount += 1
                case .insert(let ni):
                    if lines.isEmpty { oldStart = ni + 1; newStart = ni + 1 }
                    lines.append(DiffLine(kind: .added, text: newLines[ni],
                                          oldLineNumber: nil, newLineNumber: ni + 1))
                    newCount += 1
                }
            }
            if lines.isEmpty {
                // Shouldn't happen, but keep the model total.
                oldStart = 1
                newStart = 1
            }
            return DiffHunk(oldStart: oldStart, oldCount: oldCount,
                            newStart: newStart, newCount: newCount, lines: lines)
        }
    }

    private static func isChange(_ op: EditOp) -> Bool {
        switch op {
        case .keep: return false
        case .delete, .insert: return true
        }
    }
}
