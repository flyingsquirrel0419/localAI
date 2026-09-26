import Foundation
import LocalAICore

/// Bridges the Code tab UI to the workspace's sandboxed filesystem.
/// Main-actor bound for SwiftUI.
@MainActor
public final class CodeService: ObservableObject {

    @Published public private(set) var workspaceRoot: URL?
    @Published public private(set) var workspaceID: UUID?
    @Published public var error: UserFacingError?

    public private(set) var fileSystem: SandboxedFileSystem?
    public let changeTracker = ChangeTracker()
    public let gitStatusProvider: GitStatusProvider

    private let workspaceStore: WorkspaceStore

    public init(workspaceStore: WorkspaceStore, gitStatusProvider: GitStatusProvider = EmptyGitStatusProvider()) {
        self.workspaceStore = workspaceStore
        self.gitStatusProvider = gitStatusProvider
    }

    /// Bind to a workspace. Idempotent.
    public func attach(workspaceID: UUID) async {
        if self.workspaceID == workspaceID, fileSystem != nil { return }
        do {
            let url = try await workspaceStore.repositoryURL(for: workspaceID)
            let fs = try SandboxedFileSystem(rootURL: url)
            self.fileSystem = fs
            self.workspaceRoot = url
            self.workspaceID = workspaceID
            await changeTracker.clearAll()
        } catch {
            self.error = UserFacingErrorMapper.map(error)
        }
    }

    public func detach() {
        fileSystem = nil
        workspaceRoot = nil
        workspaceID = nil
    }

    // MARK: - Listing / reads

    public func listDirectory(_ path: String = ".") throws -> [FileNode] {
        guard let fs = fileSystem else { throw FileSystemError.invalidPath("no workspace") }
        return try fs.listDirectory(path)
    }

    public func readFile(_ path: String) throws -> String {
        guard let fs = fileSystem else { throw FileSystemError.invalidPath("no workspace") }
        return try fs.read(path)
    }

    public func stat(_ path: String) throws -> FileStat {
        guard let fs = fileSystem else { throw FileSystemError.invalidPath("no workspace") }
        return try fs.stat(path)
    }

    // MARK: - Writes (with change tracking)

    /// Save a file, snapshotting the previous contents for diffing.
    public func saveFile(_ path: String, contents: String) throws {
        guard let fs = fileSystem else { throw FileSystemError.invalidPath("no workspace") }
        let existed = fs.exists(path)
        if existed {
            let previous = (try? fs.read(path)) ?? ""
            Task { await changeTracker.trackBeforeEdit(relativePath: path, contents: previous) }
        } else {
            Task { await changeTracker.trackCreation(relativePath: path) }
        }
        try fs.write(path, contents: contents)
    }

    public func createFile(_ path: String) throws {
        guard let fs = fileSystem else { throw FileSystemError.invalidPath("no workspace") }
        Task { await changeTracker.trackCreation(relativePath: path) }
        try fs.createFile(path, contents: "")
    }

    public func createDirectory(_ path: String) throws {
        guard let fs = fileSystem else { throw FileSystemError.invalidPath("no workspace") }
        try fs.createDirectory(path)
    }

    public func delete(_ path: String, recursive: Bool = false) throws {
        guard let fs = fileSystem else { throw FileSystemError.invalidPath("no workspace") }
        // Snapshot so the deletion shows up in the diff list until cleared.
        if !recursive, fs.exists(path), let previous = try? fs.read(path) {
            Task { await changeTracker.trackBeforeEdit(relativePath: path, contents: previous) }
        }
        try fs.delete(path, recursive: recursive)
    }

    public func move(from source: String, to destination: String) throws {
        guard let fs = fileSystem else { throw FileSystemError.invalidPath("no workspace") }
        try fs.move(from: source, to: destination)
    }

    // MARK: - Search

    public func makeSearch() -> RepositorySearch? {
        guard let fs = fileSystem else { return nil }
        return RepositorySearch(fileSystem: fs)
    }

    // MARK: - Diffs

    public func changedFiles() async -> [ChangeTracker.ChangedFile] {
        guard let fs = fileSystem else { return [] }
        return await changeTracker.changedFiles(fileSystem: fs)
    }

    public func revert(path: String) async throws {
        guard let fs = fileSystem else { return }
        try await changeTracker.revert(relativePath: path, fileSystem: fs)
    }

    public func isModified(path: String) async -> Bool {
        guard let root = workspaceRoot else { return false }
        let gitModified = await gitStatusProvider.modifiedPaths(workspace: root)
        if gitModified.contains(path) { return true }
        let changed = await changeTracker.changedFiles(fileSystem: fileSystem!)
        return changed.contains { $0.relativePath == path }
    }
}
