import Foundation

public enum FileSystemError: Error, Equatable, Sendable {
    case pathEscapesSandbox(String)
    case notFound(String)
    case isDirectory(String)
    case isFile(String)
    case alreadyExists(String)
    case cannotDeleteRoot
    case recursiveDeleteRequiresFlag(String)
    case fileTooLarge(path: String, size: Int, limit: Int)
    case notUTF8(String)
    case invalidPath(String)
}

/// A node in the file tree, for UI display.
public struct FileNode: Sendable, Equatable, Identifiable {
    public let name: String
    public let relativePath: String
    public let isDirectory: Bool
    public let size: Int?

    public var id: String { relativePath }

    public init(name: String, relativePath: String, isDirectory: Bool, size: Int? = nil) {
        self.name = name
        self.relativePath = relativePath
        self.isDirectory = isDirectory
        self.size = size
    }
}

public struct FileStat: Sendable, Equatable {
    public let isDirectory: Bool
    public let size: Int
    public let modifiedAt: Date?
}

/// Filesystem rooted at a single directory. All paths are relative to the root and
/// are resolved (symlinks followed); anything escaping the root is rejected with
/// `FileSystemError.pathEscapesSandbox`.
public struct SandboxedFileSystem: Sendable {
    public let rootURL: URL

    /// Canonical, symlink-resolved root path with no trailing slash.
    private let canonicalRoot: String

    public init(rootURL: URL) throws {
        let standardized = rootURL.standardizedFileURL
        // Resolve symlinks on the root itself (e.g. /tmp -> /private/tmp on macOS).
        let resolved = standardized.resolvingSymlinksInPath()
        self.rootURL = resolved
        self.canonicalRoot = resolved.path
    }

    // MARK: - Path resolution

    /// Resolve a relative path to an absolute URL inside the root, or throw.
    public func resolve(_ relativePath: String) throws -> URL {
        guard !relativePath.isEmpty else { throw FileSystemError.invalidPath(relativePath) }
        guard !relativePath.hasPrefix("/") else {
            throw FileSystemError.pathEscapesSandbox(relativePath)
        }
        guard !relativePath.contains("\0") else {
            throw FileSystemError.invalidPath(relativePath)
        }

        // Reject NUL / weird schemes early.
        let joined = rootURL.appendingPathComponent(relativePath)
        let standardizedPath = (joined.path as NSString).standardizingPath

        // Resolve symlinks for the deepest existing ancestor chain.
        let resolvedPath = Self.resolvingExistingSymlinks(path: standardizedPath)

        // Must be the root itself or strictly under it.
        if resolvedPath == canonicalRoot { return URL(fileURLWithPath: resolvedPath) }
        guard resolvedPath.hasPrefix(canonicalRoot + "/") else {
            throw FileSystemError.pathEscapesSandbox(relativePath)
        }
        return URL(fileURLWithPath: resolvedPath)
    }

    /// Follow symlinks only along components that exist, so non-existent trailing
    /// components (for write targets) don't cause resolution failure.
    private static func resolvingExistingSymlinks(path: String) -> String {
        let fm = FileManager.default
        var current = path
        // Walk up until we hit an existing prefix, resolve it, re-append remainder.
        var tail: [String] = []
        while !fm.fileExists(atPath: current) {
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break } // reached "/"
            tail.insert((current as NSString).lastPathComponent, at: 0)
            current = parent
        }
        let resolvedPrefix = (current as NSString).resolvingSymlinksInPath
        if tail.isEmpty { return (resolvedPrefix as NSString).standardizingPath }
        let rejoined = tail.reduce(resolvedPrefix) { ($0 as NSString).appendingPathComponent($1) }
        return (rejoined as NSString).standardizingPath
    }

    // MARK: - Queries

    public func exists(_ relativePath: String) -> Bool {
        guard let url = try? resolve(relativePath) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func stat(_ relativePath: String) throws -> FileStat {
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FileSystemError.notFound(relativePath)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let modified = attrs[.modificationDate] as? Date
        return FileStat(isDirectory: isDir.boolValue, size: size, modifiedAt: modified)
    }

    /// List a directory's immediate children as FileNodes (sorted: directories first, then name).
    public func listDirectory(_ relativePath: String = ".") throws -> [FileNode] {
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FileSystemError.notFound(relativePath)
        }
        guard isDir.boolValue else { throw FileSystemError.isFile(relativePath) }

        let names = try FileManager.default.contentsOfDirectory(atPath: url.path)
        var nodes: [FileNode] = []
        for name in names {
            let childRelative = relativePath == "." ? name : (relativePath as NSString).appendingPathComponent(name)
            let childURL = url.appendingPathComponent(name)
            var childIsDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: childURL.path, isDirectory: &childIsDir)
            let size: Int? = childIsDir.boolValue
                ? nil
                : (try? FileManager.default.attributesOfItem(atPath: childURL.path))
                    .flatMap { ($0[.size] as? NSNumber)?.intValue }
            nodes.append(FileNode(name: name, relativePath: childRelative, isDirectory: childIsDir.boolValue, size: size))
        }
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Reads

    /// Read a UTF-8 text file, enforcing a size limit (default 1 MiB).
    public func read(_ relativePath: String, maxBytes: Int = 1_048_576) throws -> String {
        let url = try resolve(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FileSystemError.notFound(relativePath)
        }
        guard !isDir.boolValue else { throw FileSystemError.isDirectory(relativePath) }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxBytes else {
            throw FileSystemError.fileTooLarge(path: relativePath, size: size, limit: maxBytes)
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw FileSystemError.notUTF8(relativePath)
        }
        return text
    }

    // MARK: - Writes

    /// Atomically write a UTF-8 text file, creating intermediate directories.
    public func write(_ relativePath: String, contents: String) throws {
        let url = try resolve(relativePath)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = Data(contents.utf8)
        try data.write(to: url, options: .atomic)
    }

    public func createFile(_ relativePath: String, contents: String = "") throws {
        let url = try resolve(relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            throw FileSystemError.alreadyExists(relativePath)
        }
        try write(relativePath, contents: contents)
    }

    public func createDirectory(_ relativePath: String) throws {
        let url = try resolve(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Delete a file or directory. The root itself can never be deleted.
    /// Deleting a non-empty directory requires `recursive: true`.
    public func delete(_ relativePath: String, recursive: Bool = false) throws {
        let url = try resolve(relativePath)
        if url.path == canonicalRoot {
            throw FileSystemError.cannotDeleteRoot
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw FileSystemError.notFound(relativePath)
        }
        if isDir.boolValue {
            let children = try FileManager.default.contentsOfDirectory(atPath: url.path)
            if !children.isEmpty && !recursive {
                throw FileSystemError.recursiveDeleteRequiresFlag(relativePath)
            }
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Move/rename a file or directory. Destination must also be inside the sandbox.
    public func move(from source: String, to destination: String) throws {
        let srcURL = try resolve(source)
        let dstURL = try resolve(destination)
        guard FileManager.default.fileExists(atPath: srcURL.path) else {
            throw FileSystemError.notFound(source)
        }
        if FileManager.default.fileExists(atPath: dstURL.path) {
            throw FileSystemError.alreadyExists(destination)
        }
        let parent = dstURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: srcURL, to: dstURL)
    }
}
