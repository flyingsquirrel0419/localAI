import Foundation

public struct SearchOptions: Sendable, Equatable {
    /// Directory names always excluded unless `includeIgnored` is true.
    public var defaultExcludes: Set<String>
    /// When true, .gitignore rules and `defaultExcludes` are not applied.
    public var includeIgnored: Bool
    /// Maximum file size (bytes) considered by text search. Files larger are skipped.
    public var maxFileBytes: Int

    public init(
        defaultExcludes: Set<String> = [".git", "node_modules", "build", "dist", "DerivedData", ".build"],
        includeIgnored: Bool = false,
        maxFileBytes: Int = 1_048_576
    ) {
        self.defaultExcludes = defaultExcludes
        self.includeIgnored = includeIgnored
        self.maxFileBytes = maxFileBytes
    }

    public static let `default` = SearchOptions()
}

public struct FileSearchResult: Sendable, Equatable, Identifiable {
    public let relativePath: String
    public let fileName: String
    /// Higher is a better match (exact > prefix > substring).
    public let score: Int

    public var id: String { relativePath }
}

public struct TextSearchResult: Sendable, Equatable, Identifiable {
    public let relativePath: String
    public let line: Int
    public let column: Int
    public let preview: String

    public var id: String { "\(relativePath):\(line):\(column)" }
}

public enum SearchError: Error, Equatable, Sendable {
    case invalidRegex(String)
}

/// File-name and content search over a SandboxedFileSystem root, honouring
/// .gitignore rules and default directory excludes. All searches are async and
/// respond to task cancellation.
public struct RepositorySearch: Sendable {
    public let fileSystem: SandboxedFileSystem
    public let options: SearchOptions
    private let matcher: GitIgnoreMatcher

    public init(fileSystem: SandboxedFileSystem, options: SearchOptions = .default) {
        self.fileSystem = fileSystem
        self.options = options
        if options.includeIgnored {
            self.matcher = GitIgnoreMatcher()
        } else {
            self.matcher = GitIgnoreMatcher(fileSystem: fileSystem)
        }
    }

    /// All searchable repository-relative file paths (recursive, filtered).
    private func enumerateFiles() throws -> [String] {
        var results: [String] = []
        try enumerate(directory: ".", into: &results)
        return results
    }

    private func enumerate(directory: String, into results: inout [String]) throws {
        let children = try fileSystem.listDirectory(directory)
        for child in children {
            let rel = child.relativePath
            if child.isDirectory {
                if !options.includeIgnored {
                    if options.defaultExcludes.contains(child.name) { continue }
                    if matcher.isIgnored(relativePath: rel, isDirectory: true) { continue }
                }
                try enumerate(directory: rel, into: &results)
            } else {
                if !options.includeIgnored && matcher.isIgnored(relativePath: rel, isDirectory: false) {
                    continue
                }
                results.append(rel)
            }
        }
    }

    // MARK: - File name search

    /// Fuzzy/substring filename search, ranked: exact (case-insensitive) first,
    /// then prefix, then substring. `extensions` filters by file extension
    /// (without the dot, case-insensitive); empty means no filter.
    public func searchFiles(
        query: String,
        extensions: [String] = [],
        limit: Int = 100
    ) async throws -> [FileSearchResult] {
        let loweredExts = Set(extensions.map { $0.lowercased() })
        let q = query.lowercased()
        let files = try enumerateFiles()
        var matches: [FileSearchResult] = []
        for path in files {
            try Task.checkCancellation()
            let name = (path as NSString).lastPathComponent
            if !loweredExts.isEmpty {
                let ext = (name as NSString).pathExtension.lowercased()
                guard loweredExts.contains(ext) else { continue }
            }
            guard !q.isEmpty else {
                matches.append(FileSearchResult(relativePath: path, fileName: name, score: 1))
                continue
            }
            let lowered = name.lowercased()
            let score: Int
            if lowered == q {
                score = 100
            } else if lowered.hasPrefix(q) {
                score = 50
            } else if lowered.contains(q) {
                score = 25
            } else {
                continue
            }
            matches.append(FileSearchResult(relativePath: path, fileName: name, score: score))
        }
        return matches
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.relativePath < rhs.relativePath
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Text search

    /// Full-text search across repository files. Binary files (containing NUL in
    /// the first 8 KB) and files larger than `options.maxFileBytes` are skipped.
    public func searchText(
        pattern: String,
        isRegex: Bool = false,
        caseSensitive: Bool = false,
        extensions: [String] = [],
        limit: Int = 100
    ) async throws -> [TextSearchResult] {
        let regex: NSRegularExpression?
        if isRegex {
            let opts: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
            do {
                regex = try NSRegularExpression(pattern: pattern, options: opts)
            } catch {
                throw SearchError.invalidRegex(pattern)
            }
        } else {
            regex = nil
        }
        let loweredNeedle = caseSensitive ? pattern : pattern.lowercased()
        let loweredExts = Set(extensions.map { $0.lowercased() })

        let files = try enumerateFiles()
        var results: [TextSearchResult] = []
        for path in files {
            try Task.checkCancellation()
            if results.count >= limit { break }
            if !loweredExts.isEmpty {
                let ext = (path as NSString).pathExtension.lowercased()
                guard loweredExts.contains(ext) else { continue }
            }
            let stat: FileStat
            do {
                stat = try fileSystem.stat(path)
            } catch { continue }
            guard !stat.isDirectory, stat.size <= options.maxFileBytes else { continue }

            guard let url = try? fileSystem.resolve(path),
                  let data = try? Data(contentsOf: url) else { continue }
            if Self.looksBinary(data) { continue }
            guard let text = String(data: data, encoding: .utf8) else { continue }

            var lineNumber = 0
            for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                try Task.checkCancellation()
                lineNumber += 1
                if results.count >= limit { break }
                let line = String(rawLine)
                if let regex {
                    let range = NSRange(line.startIndex..., in: line)
                    for match in regex.matches(in: line, range: range) {
                        if results.count >= limit { break }
                        guard let r = Range(match.range, in: line) else { continue }
                        let column = line.distance(from: line.startIndex, to: r.lowerBound) + 1
                        results.append(TextSearchResult(
                            relativePath: path, line: lineNumber, column: column,
                            preview: Self.preview(of: line)
                        ))
                    }
                } else {
                    let haystack = caseSensitive ? line : line.lowercased()
                    var searchStart = haystack.startIndex
                    while let r = haystack.range(of: loweredNeedle, range: searchStart..<haystack.endIndex) {
                        if results.count >= limit { break }
                        let column = haystack.distance(from: haystack.startIndex, to: r.lowerBound) + 1
                        results.append(TextSearchResult(
                            relativePath: path, line: lineNumber, column: column,
                            preview: Self.preview(of: line)
                        ))
                        searchStart = r.upperBound
                    }
                }
            }
        }
        return results
    }

    private static func preview(of line: String, maxLength: Int = 200) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= maxLength { return trimmed }
        return String(trimmed.prefix(maxLength)) + "…"
    }

    private static func looksBinary(_ data: Data) -> Bool {
        let check = data.prefix(8192)
        return check.contains(0)
    }
}
