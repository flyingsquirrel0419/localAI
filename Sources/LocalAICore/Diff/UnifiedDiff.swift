import Foundation

/// Renders a per-file diff in unified format (`--- a/path`, `+++ b/path`,
/// `@@ -l,s +l,s @@`) and parses unified diffs back into hunks.
public enum UnifiedDiff {
    /// Render hunks for one file as a unified diff section.
    public static func render(
        oldPath: String,
        newPath: String,
        hunks: [DiffHunk]
    ) -> String {
        guard !hunks.isEmpty else { return "" }
        var out = ""
        out += "--- \(oldPath)\n"
        out += "+++ \(newPath)\n"
        for hunk in hunks {
            out += "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\n"
            for line in hunk.lines {
                switch line.kind {
                case .context: out += " \(line.text)\n"
                case .removed: out += "-\(line.text)\n"
                case .added: out += "+\(line.text)\n"
                }
            }
        }
        return out
    }

    /// Convenience: diff two texts and render as a unified diff for one file.
    public static func render(oldPath: String, newPath: String, old: String, new: String) -> String {
        render(oldPath: oldPath, newPath: newPath, hunks: LineDiff.diff(old: old, new: new))
    }

    public static func stats(hunks: [DiffHunk]) -> DiffStats {
        LineDiff.stats(hunks: hunks)
    }

    // MARK: - Parsing

    public struct ParsedFile: Sendable, Equatable {
        public let oldPath: String
        public let newPath: String
        public let hunks: [DiffHunk]
    }

    public enum ParseError: Error, Equatable, Sendable {
        case missingFileHeaders
        case malformedHunkHeader(String)
        case unexpectedLine(String)
    }

    /// Parse a unified diff (single or multi-file). Paths have any `a/`, `b/`
    /// prefix stripped.
    public static func parse(_ text: String) throws -> [ParsedFile] {
        var files: [ParsedFile] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0

        var oldPath: String?
        var newPath: String?
        var hunks: [DiffHunk] = []

        func flushFile() {
            if let o = oldPath, let n = newPath {
                files.append(ParsedFile(oldPath: o, newPath: n, hunks: hunks))
            }
            oldPath = nil
            newPath = nil
            hunks = []
        }

        func stripPrefix(_ p: String) -> String {
            if p.hasPrefix("a/") || p.hasPrefix("b/") { return String(p.dropFirst(2)) }
            return p
        }

        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("--- ") {
                // A new "--- " after hunks means a new file section.
                if oldPath != nil && newPath != nil && !hunks.isEmpty { flushFile() }
                let raw = String(line.dropFirst(4))
                oldPath = stripPrefix(raw.split(separator: "\t").first.map(String.init) ?? raw)
                i += 1
            } else if line.hasPrefix("+++ ") {
                let raw = String(line.dropFirst(4))
                newPath = stripPrefix(raw.split(separator: "\t").first.map(String.init) ?? raw)
                i += 1
            } else if line.hasPrefix("@@ ") {
                guard oldPath != nil, newPath != nil else { throw ParseError.missingFileHeaders }
                let (hunk, consumed) = try parseHunk(lines: lines, start: i)
                hunks.append(hunk)
                i = consumed
            } else if line.hasPrefix("diff ") || line.hasPrefix("index ") ||
                        line.hasPrefix("Index: ") || line.hasPrefix("===") ||
                        line.hasPrefix("new file") || line.hasPrefix("deleted file") {
                flushFile()
                i += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty && oldPath == nil {
                i += 1
            } else {
                // Unknown header noise outside hunks (e.g. commit message text); skip.
                i += 1
            }
        }
        flushFile()

        if files.isEmpty { throw ParseError.missingFileHeaders }
        return files
    }

    private static func parseHunk(lines: [String], start: Int) throws -> (DiffHunk, Int) {
        let header = lines[start]
        // @@ -oldStart[,oldCount] +newStart[,newCount] @@
        guard let closeRange = header.range(of: " @@", range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex)
                ?? (header.hasSuffix("@@") ? header.range(of: "@@", options: .backwards) : nil) else {
            throw ParseError.malformedHunkHeader(header)
        }
        let inner = header[header.index(header.startIndex, offsetBy: 3)..<closeRange.lowerBound]
        let parts = inner.split(separator: " ")
        guard parts.count == 2, parts[0].hasPrefix("-"), parts[1].hasPrefix("+") else {
            throw ParseError.malformedHunkHeader(header)
        }
        func parseRange(_ s: Substring) throws -> (Int, Int) {
            let body = s.dropFirst()
            let nums = body.split(separator: ",")
            guard let first = nums.first, let start = Int(first) else {
                throw ParseError.malformedHunkHeader(header)
            }
            let count = nums.count > 1 ? (Int(nums[1]) ?? 0) : 1
            return (start, count)
        }
        let (oldStart, oldCount) = try parseRange(parts[0])
        let (newStart, newCount) = try parseRange(parts[1])

        var hunkLines: [DiffLine] = []
        var oldLine = oldStart
        var newLine = newStart
        var i = start + 1
        var seenOld = 0
        var seenNew = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("@@ ") || line.hasPrefix("--- ") || line.hasPrefix("diff ") { break }
            if seenOld >= oldCount && seenNew >= newCount { break }
            guard let marker = line.first else {
                // Empty line inside a hunk = context line with empty text.
                hunkLines.append(DiffLine(kind: .context, text: "",
                                          oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1; newLine += 1; seenOld += 1; seenNew += 1
                i += 1
                continue
            }
            let body = String(line.dropFirst())
            switch marker {
            case " ":
                hunkLines.append(DiffLine(kind: .context, text: body,
                                          oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1; newLine += 1; seenOld += 1; seenNew += 1
            case "-":
                hunkLines.append(DiffLine(kind: .removed, text: body,
                                          oldLineNumber: oldLine, newLineNumber: nil))
                oldLine += 1; seenOld += 1
            case "+":
                hunkLines.append(DiffLine(kind: .added, text: body,
                                          oldLineNumber: nil, newLineNumber: newLine))
                newLine += 1; seenNew += 1
            case "\\":
                // "\ No newline at end of file" — annotation for previous line; ignore.
                break
            default:
                throw ParseError.unexpectedLine(line)
            }
            i += 1
        }
        return (DiffHunk(oldStart: oldStart, oldCount: oldCount,
                         newStart: newStart, newCount: newCount, lines: hunkLines), i)
    }
}
