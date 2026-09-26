import Foundation
import LocalAICore

/// Bridges the Code tab UI to the workspace's sandboxed filesystem and Git.
/// Main-actor bound for SwiftUI.
@MainActor
public final class CodeService: ObservableObject {

    @Published public private(set) var workspaceRoot: URL?
    @Published public private(set) var workspaceID: UUID?
    @Published public var error: UserFacingError?
    /// True when the attached workspace is a git repository.
    @Published public private(set) var isGitRepository: Bool = false
    /// Number of local commits ahead of `origin/<currentBranch>`. 0 when
    /// no upstream is configured yet.
    @Published public private(set) var aheadCount: Int = 0

    public private(set) var fileSystem: SandboxedFileSystem?
    public let changeTracker = ChangeTracker()
    public let gitStatusProvider: GitStatusProvider

    private let workspaceStore: WorkspaceStore
    private let gitService: Libgit2GitService

    public init(
        workspaceStore: WorkspaceStore,
        gitService: Libgit2GitService,
        gitStatusProvider: GitStatusProvider
    ) {
        self.workspaceStore = workspaceStore
        self.gitService = gitService
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
            await refreshGitState()
        } catch {
            self.error = UserFacingErrorMapper.map(error)
        }
    }

    public func detach() {
        fileSystem = nil
        workspaceRoot = nil
        workspaceID = nil
        isGitRepository = false
        aheadCount = 0
    }

    /// Refresh cached git state (`isGitRepository` and `aheadCount`).
    public func refreshGitState() async {
        guard let root = workspaceRoot else {
            isGitRepository = false
            aheadCount = 0
            return
        }
        isGitRepository = await gitService.isGitRepository(at: root)
        aheadCount = isGitRepository ? await gitService.aheadCount(in: root) : 0
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

    /// Snapshot-based diff entries (fallback when the workspace is not a git repo).
    public func changedFiles() async -> [ChangeTracker.ChangedFile] {
        guard let fs = fileSystem else { return [] }
        return await changeTracker.changedFiles(fileSystem: fs)
    }

    /// Unified diff text for all pending changes (HEAD vs worktree, plus any
    /// staged changes against HEAD) when in a git repo. `nil` otherwise.
    public func gitDiff() async -> String? {
        guard let root = workspaceRoot, isGitRepository else { return nil }
        let unstaged = (try? await gitService.diff(in: root, paths: nil, staged: false)) ?? ""
        let staged = (try? await gitService.diff(in: root, paths: nil, staged: true)) ?? ""
        if staged.isEmpty { return unstaged }
        if unstaged.isEmpty { return staged }
        return staged + "\n" + unstaged
    }

    /// List of changed paths from git status (when in a git repo).
    public func gitStatusEntries() async -> [GitFileStatus] {
        guard let root = workspaceRoot, isGitRepository else { return [] }
        return (try? await gitService.status(in: root)) ?? []
    }

    /// Revert a file. In a git repo, restores from HEAD; otherwise uses
    /// the snapshot the ChangeTracker took when the file was first edited.
    public func revert(path: String) async throws {
        guard let fs = fileSystem, let root = workspaceRoot else { return }
        if isGitRepository {
            try await gitService.revertFile(in: root, path: path)
            await changeTracker.clear(relativePath: path)
        } else {
            try await changeTracker.revert(relativePath: path, fileSystem: fs)
        }
        await refreshGitState()
    }

    public func isModified(path: String) async -> Bool {
        guard let root = workspaceRoot else { return false }
        let gitModified = await gitStatusProvider.modifiedPaths(workspace: root)
        if gitModified.contains(path) { return true }
        let changed = await changeTracker.changedFiles(fileSystem: fileSystem!)
        return changed.contains { $0.relativePath == path }
    }

    // MARK: - Git operations surfaced to the UI

    /// Stage every modified path and commit with the given message.
    /// Returns the new commit SHA.
    @discardableResult
    public func commitAll(message: String, author: GitAuthor) async throws -> String {
        guard let root = workspaceRoot else {
            throw LocalAICore.GitError.notARepository("no workspace")
        }
        let entries = try await gitService.status(in: root)
        let paths = Array(Set(entries.map { $0.path }))
        if !paths.isEmpty {
            try await gitService.stage(in: root, paths: paths)
        }
        let sha = try await gitService.commit(in: root, message: message, author: author)
        await changeTracker.clearAll()
        await refreshGitState()
        return sha
    }

    public func pushToOrigin() async throws {
        guard let root = workspaceRoot else {
            throw LocalAICore.GitError.notARepository("no workspace")
        }
        let credentials = try await gitCredentialProviderForPush()
        try await gitService.push(in: root, remote: "origin", branch: nil, credentials: credentials, force: false)
        await refreshGitState()
    }

    public func pullFromOrigin() async throws -> GitPullResult {
        guard let root = workspaceRoot else {
            throw LocalAICore.GitError.notARepository("no workspace")
        }
        let credentials = try await gitCredentialProviderForPush()
        let result = try await gitService.pull(in: root, credentials: credentials)
        await refreshGitState()
        return result
    }

    /// The credential provider is set externally (from AppEnvironment) so the
    /// CodeService doesn't have to know where tokens come from.
    public var gitCredentialProviderForPush: () async throws -> GitCredentials? = { nil }
}
