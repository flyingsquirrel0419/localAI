import Foundation

public enum PatchError: Error, Equatable, Sendable {
    /// Context or removed lines did not match the target text near the hunk's
    /// declared position (after fuzz search).
    case contextMismatch(path: String, hunkOldStart: Int)
    case ambiguousOldString(occurrences: Int)
    case oldStringNotFound
    case emptyOldString
}

/// Applies unified diffs and search/replace edits to text in memory.
public enum PatchApplier {
    /// Maximum line offset the fuzz search will try on each side of a hunk's
    /// declared position.
    public static let fuzzRadius = 50

    /// Apply a single-file patch (already parsed hunks) to `text`.
    /// Returns the patched text. Throws `PatchError.contextMismatch` when a
    /// hunk cannot be located even with fuzz.
    public static func apply(hunks: [DiffHunk], to text: String) throws -> String {
        var lines = LineDiff.splitLines(text)
        // Track cumulative shift so later hunks' line numbers stay meaningful.
        var shift = 0
        for hunk in hunks {
            let anchor = hunk.oldStart - 1 + shift // 0-based index into `lines`
            let expected = hunk.lines.compactMap { line -> String? in
                switch line.kind {
                case .context, .removed: return line.text
                case .added: return nil
                }
            }
            guard let position = locate(expected: expected, in: lines, near: anchor) else {
                throw PatchError.contextMismatch(path: "", hunkOldStart: hunk.oldStart)
            }
            // Build replacement lines: context + added.
            var replacement: [String] = []
            for line in hunk.lines {
                switch line.kind {
                case .context, .added: replacement.append(line.text)
                case .removed: break
                }
            }
            lines.replaceSubrange(position..<(position + expected.count), with: replacement)
            shift += replacement.count - expected.count
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + (text.hasSuffix("\n") ? "\n" : "")
    }

    /// Apply a unified diff (possibly multi-file) to a mapping of path → text.
    /// Returns a new mapping with patched contents. Paths not present in
    /// `contents` must exist as empty-string targets (creation) or the call throws.
    public static func apply(unifiedDiff: String, to contents: [String: String]) throws -> [String: String] {
        let files = try UnifiedDiff.parse(unifiedDiff)
        var result = contents
        for file in files {
            let path = file.newPath
            let original = result[path] ?? (file.oldPath == "/dev/null" || file.oldPath == "dev/null" ? "" : result[file.oldPath] ?? "")
            do {
                result[path] = try apply(hunks: file.hunks, to: original)
            } catch let PatchError.contextMismatch(_, hunkOldStart) {
                throw PatchError.contextMismatch(path: path, hunkOldStart: hunkOldStart)
            }
        }
        return result
    }

    /// Find where `expected` occurs in `lines`, searching outward from `near`
    /// up to `fuzzRadius` lines in each direction, then the whole file as a
    /// last resort only when `near` is out of bounds.
    private static func locate(expected: [String], in lines: [String], near: Int) -> Int? {
        guard !expected.isEmpty else { return min(max(near, 0), lines.count) }
        func matches(at start: Int) -> Bool {
            guard start >= 0, start + expected.count <= lines.count else { return false }
            for (i, exp) in expected.enumerated() where lines[start + i] != exp {
                return false
            }
            return true
        }
        if matches(at: near) { return near }
        for delta in 1...fuzzRadius {
            if matches(at: near + delta) { return near + delta }
            if matches(at: near - delta) { return near - delta }
        }
        return nil
    }

    // MARK: - Search/replace edit

    /// Replace `oldString` with `newString` in `text`. `oldString` must be
    /// non-empty and occur exactly once; otherwise an error is thrown. This is
    /// friendlier for small LLMs than producing unified diffs.
    public static func searchReplace(text: String, oldString: String, newString: String) throws -> String {
        guard !oldString.isEmpty else { throw PatchError.emptyOldString }
        var occurrences = 0
        var searchStart = text.startIndex
        while let range = text.range(of: oldString, range: searchStart..<text.endIndex) {
            occurrences += 1
            searchStart = range.upperBound
            if occurrences > 1 { throw PatchError.ambiguousOldString(occurrences: occurrences) }
        }
        guard occurrences == 1 else { throw PatchError.oldStringNotFound }
        return text.replacingOccurrences(of: oldString, with: newString)
    }
}

/// A search/replace edit operation (model-friendly alternative to diffs).
public struct SearchReplaceEdit: Sendable, Equatable {
    public let oldString: String
    public let newString: String

    public init(oldString: String, newString: String) {
        self.oldString = oldString
        self.newString = newString
    }

    public func apply(to text: String) throws -> String {
        try PatchApplier.searchReplace(text: text, oldString: oldString, newString: newString)
    }
}
