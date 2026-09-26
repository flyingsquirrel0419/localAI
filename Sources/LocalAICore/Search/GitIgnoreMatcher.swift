import Foundation

/// A single parsed .gitignore pattern.
public struct GitIgnorePattern: Sendable, Equatable {
    /// Raw pattern text with leading/trailing markers stripped.
    public let pattern: String
    /// True if the pattern begins with `!` (re-includes a previously ignored path).
    public let negation: Bool
    /// True if the pattern ends with `/` (matches directories only).
    public let directoryOnly: Bool
    /// True if the pattern is anchored: contains a `/` anywhere except a trailing
    /// directory marker. Anchored patterns match relative to the .gitignore's directory.
    public let anchored: Bool
    /// Directory (relative to the repository root, "" for the root) containing the
    /// .gitignore file this pattern came from.
    public let baseDirectory: String

    /// Parse one raw line from a .gitignore file. Returns nil for blank lines / comments.
    public init?(rawLine: String, baseDirectory: String) {
        var line = rawLine
        // Trailing spaces are ignored unless escaped with backslash (we ignore the escape case).
        while line.hasSuffix(" ") && !line.hasSuffix("\\ ") {
            line.removeLast()
        }
        if line.hasSuffix("\\ ") {
            line.removeLast(2)
            line.append(" ")
        }
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }

        var negation = false
        if line.hasPrefix("!") {
            negation = true
            line.removeFirst()
        } else if line.hasPrefix("\\!") || line.hasPrefix("\\#") {
            line.removeFirst()
        }
        guard !line.isEmpty else { return nil }

        var directoryOnly = false
        if line.hasSuffix("/") {
            directoryOnly = true
            line.removeLast()
        }
        guard !line.isEmpty else { return nil }

        var anchored = false
        if line.hasPrefix("/") {
            anchored = true
            line.removeFirst()
        } else if line.contains("/") {
            anchored = true
        }
        guard !line.isEmpty else { return nil }

        self.pattern = line
        self.negation = negation
        self.directoryOnly = directoryOnly
        self.anchored = anchored
        self.baseDirectory = baseDirectory
    }

    /// Whether this pattern matches the given repository-relative path.
    /// `isDirectory` describes the candidate path itself.
    func matches(relativePath: String, isDirectory: Bool) -> Bool {
        if directoryOnly && !isDirectory { return false }

        // The pattern only applies to paths inside (or equal to) its base directory.
        var path = relativePath
        if !baseDirectory.isEmpty {
            guard relativePath == baseDirectory || relativePath.hasPrefix(baseDirectory + "/") else {
                return false
            }
            if relativePath == baseDirectory { return false } // a dir's own .gitignore can't match itself
            path = String(relativePath.dropFirst(baseDirectory.count + 1))
        }

        if anchored {
            return Self.matchGlob(pattern: pattern, path: path)
        }
        // Unanchored: match against the last path component, or the full path
        // (gitignore semantics: a pattern without a slash matches at any depth).
        let lastComponent = (path as NSString).lastPathComponent
        if Self.matchGlob(pattern: pattern, path: lastComponent) { return true }
        return Self.matchGlob(pattern: pattern, path: path)
    }

    /// Glob matcher supporting `*` (within a component), `**` (across components),
    /// and `?` (single character within a component).
    static func matchGlob(pattern: String, path: String) -> Bool {
        let patternComponents = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return matchComponents(pattern: patternComponents, path: pathComponents)
    }

    private static func matchComponents(pattern: [String], path: [String]) -> Bool {
        if pattern.isEmpty { return path.isEmpty }
        let head = pattern[0]
        if head == "**" {
            // `**` matches zero or more path components.
            let rest = Array(pattern.dropFirst())
            if matchComponents(pattern: rest, path: path) { return true }
            if !path.isEmpty {
                return matchComponents(pattern: pattern, path: Array(path.dropFirst()))
            }
            return false
        }
        guard let pathHead = path.first else { return false }
        guard matchComponent(pattern: head, name: pathHead) else { return false }
        return matchComponents(pattern: Array(pattern.dropFirst()), path: Array(path.dropFirst()))
    }

    /// Match a single path component against a glob without `/` (`*` and `?` allowed).
    static func matchComponent(pattern: String, name: String) -> Bool {
        let p = Array(pattern)
        let n = Array(name)
        var pi = 0
        var ni = 0
        var starP = -1
        var starN = -1
        while ni < n.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == n[ni]) {
                pi += 1
                ni += 1
            } else if pi < p.count && p[pi] == "*" {
                starP = pi
                starN = ni
                pi += 1
            } else if starP != -1 {
                pi = starP + 1
                starN += 1
                ni = starN
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}

/// Matches repository-relative paths against .gitignore rules gathered from a
/// root .gitignore plus any nested .gitignore files. Later, deeper files win;
/// within a file, later lines win.
public struct GitIgnoreMatcher: Sendable {
    public private(set) var patterns: [GitIgnorePattern] = []

    public init() {}

    /// Add the contents of one .gitignore file. `baseDirectory` is the directory
    /// containing the file, relative to the repository root ("" for the root file).
    public mutating func addGitIgnore(contents: String, baseDirectory: String = "") {
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if let pattern = GitIgnorePattern(rawLine: line, baseDirectory: baseDirectory) {
                patterns.append(pattern)
            }
        }
    }

    /// Load the root .gitignore and all nested .gitignore files from the sandbox.
    public init(fileSystem: SandboxedFileSystem) {
        self.init()
        load(from: fileSystem, directory: "")
    }

    private mutating func load(from fs: SandboxedFileSystem, directory: String) {
        let ignorePath = directory.isEmpty ? ".gitignore" : directory + "/.gitignore"
        if fs.exists(ignorePath), let contents = try? fs.read(ignorePath) {
            addGitIgnore(contents: contents, baseDirectory: directory)
        }
        guard let children = try? fs.listDirectory(directory.isEmpty ? "." : directory) else { return }
        for child in children where child.isDirectory && child.name != ".git" {
            load(from: fs, directory: child.relativePath)
        }
    }

    /// True if the repository-relative path should be ignored.
    public func isIgnored(relativePath: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for pattern in patterns {
            if pattern.matches(relativePath: relativePath, isDirectory: isDirectory) {
                ignored = !pattern.negation
            }
        }
        return ignored
    }

    public func isIgnored(_ relativePath: String) -> Bool {
        // Best-effort: unknown paths are treated as files unless they end in "/".
        let trimmed = relativePath.hasSuffix("/") ? String(relativePath.dropLast()) : relativePath
        return isIgnored(relativePath: trimmed, isDirectory: relativePath.hasSuffix("/"))
    }
}
