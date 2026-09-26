import Foundation
import LocalAICore
import Git2

/// `GitService` implementation backed by libgit2 via the Git2 Swift wrapper.
///
/// Why an actor: libgit2 calls block the calling thread. The wrapper serializes
/// per-repository access through an internal `os_unfair_lock`, but the call
/// itself still runs on whatever executor invoked it. Running every operation
/// inside an actor pushes them onto a cooperative thread pool instead of the
/// main actor.
///
/// Repositories are cached per working-directory URL so we don't pay open
/// costs on every operation.
///
/// A note on the raw-Cgit2 helpers (`RawRepo` below): the Git2 Swift wrapper
/// at the pinned commit doesn't yet wrap `git_diff_index_to_workdir`,
/// `git_diff_to_buf`, `git_reset_default`, or the path-filtered
/// `git_checkout_head` form we need. Because `Git2` re-exports `Cgit2`, we
/// open a second `git_repository*` for the same directory and call those
/// functions directly. libgit2 handles two open handles against the same
/// on-disk repo fine (each keeps its own index cache).
public actor Libgit2GitService: GitService {

    /// Bootstrap is process-wide and idempotent (libgit2 refcounts init).
    private static var didBootstrap = false
    private static func bootstrapOnce() throws {
        guard !didBootstrap else { return }
        try Git.bootstrap()
        didBootstrap = true
    }

    private var repositories: [String: Repository] = [:]

    public init() {}

    // MARK: - Repository cache

    private func repository(at directory: URL) throws -> Repository {
        try Self.bootstrapOnce()
        let key = directory.standardizedFileURL.path
        if let cached = repositories[key] { return cached }
        let repo = try Repository.open(at: directory)
        repositories[key] = repo
        return repo
    }

    // MARK: - Errors

    private static func mapError(_ error: Git2.GitError, hint: String? = nil) -> LocalAICore.GitError {
        switch error.code {
        case .auth:           return .authenticationFailed
        case .nonFastForward: return .nonFastForward
        case .conflict:       return .conflict([])
        case .notFound:
            if let hint { return .notARepository(hint) }
            return .commandFailed(error.message)
        case .unbornBranch:   return .commandFailed("unborn HEAD: \(error.message)")
        default:              return .commandFailed(error.message)
        }
    }

    // MARK: - Credentials

    private func credentialsHandler(
        for credentials: GitCredentials?
    ) -> Repository.FetchOptions.CredentialsHandler? {
        guard let credentials else { return nil }
        return { _, _, allowed in
            if allowed.contains(.userpassPlaintext) {
                return .userPass(username: credentials.username, password: credentials.password)
            }
            if allowed.contains(.username) {
                return .username(credentials.username)
            }
            return .default
        }
    }

    // MARK: - GitService

    public func clone(url: URL, to directory: URL, branch: String?, credentials: GitCredentials?) async throws {
        try Self.bootstrapOnce()
        // WorkspaceStore has already created the (empty) target directory.
        // libgit2's `git_clone` is not yet wrapped, so compose it:
        // create → addRemote → fetch → checkout.
        let repo = try Repository.create(at: directory, bare: false, initialBranch: branch)
        // M6: never persist credentials in .git/config. Strip any userinfo
        // the caller included in `url` and rely on the credentials callback
        // for auth. If a credentialed URL was passed, log nothing about it.
        let cleanedURL = Self.sanitizedRemoteURL(url)
        let remoteURLString = cleanedURL.isFileURL ? cleanedURL.path : cleanedURL.absoluteString
        _ = try repo.createRemote(named: "origin", url: remoteURLString)

        var fetchOpts = Repository.FetchOptions()
        fetchOpts.credentials = credentialsHandler(for: credentials)

        // Note: typed-throws `do { if/else } catch` trips a SILGen ownership
        // verifier crash in the Swift 6.2 toolchain (Xcode 26.3 CI image) for
        // `GitError`. Fetch is therefore factored into a helper whose do-block
        // contains a single call, and the mapped error is thrown from a local.
        if let branch {
            let spec = Refspec("+refs/heads/\(branch):refs/remotes/origin/\(branch)")
            try Self.fetchForClone(repo: repo, refspec: spec, options: fetchOpts, hint: remoteURLString)
        } else {
            try Self.fetchForClone(repo: repo, refspec: nil, options: fetchOpts, hint: remoteURLString)
        }

        let branchName = branch ?? (try? Self.discoverDefaultBranch(repo: repo)) ?? "main"
        try Self.checkoutClonedBranch(repo: repo, branchName: branchName)
    }

    /// Strip any userinfo (`user:pass@`) from an http(s) URL so credentials
    /// never end up persisted to .git/config or echoed in errors. File and
    /// non-URL inputs pass through unchanged.
    static func sanitizedRemoteURL(_ url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user != nil || url.password != nil else {
            return url
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        return components?.url ?? url
    }

    private static func fetchForClone(
        repo: Repository,
        refspec: Refspec?,
        options: Repository.FetchOptions,
        hint: String
    ) throws {
        do {
            if let refspec {
                try repo.fetch(remoteNamed: "origin", refspecs: [refspec], options: options)
            } else {
                try repo.fetch(remoteNamed: "origin", options: options)
            }
        } catch let error as Git2.GitError {
            let mapped = mapError(error, hint: hint)
            throw mapped
        }
    }

    private static func checkoutClonedBranch(repo: Repository, branchName: String) throws {
        do {
            guard let tracking = try repo.reference(named: "refs/remotes/origin/\(branchName)") else {
                throw LocalAICore.GitError.branchNotFound(branchName)
            }
            let tip = try tracking.resolveToCommit()
            _ = try repo.createBranch(named: branchName, at: tip, force: true)
            try repo.checkout(branchNamed: branchName)
        } catch let error as Git2.GitError {
            let mapped = mapError(error)
            throw mapped
        }
    }

    private static func discoverDefaultBranch(repo: Repository) throws -> String {
        // Prefer the remote's HEAD symref when present.
        if let head = try? repo.reference(named: "refs/remotes/origin/HEAD") {
            let target = head.name
            if let last = target.split(separator: "/").last { return String(last) }
        }
        if (try? repo.reference(named: "refs/remotes/origin/main")) != nil { return "main" }
        if (try? repo.reference(named: "refs/remotes/origin/master")) != nil { return "master" }
        throw Git2.GitError(code: .notFound, class: .reference, message: "no default branch")
    }

    public func status(in directory: URL) async throws -> [LocalAICore.GitFileStatus] {
        do {
            let repo = try repository(at: directory)
            let entries = try repo.statusEntries()
            var out: [LocalAICore.GitFileStatus] = []
            for entry in entries {
                let flags = entry.flags
                if flags.contains(.indexNew) {
                    out.append(.init(path: entry.path, kind: .added, staged: true))
                } else if flags.contains(.indexModified) {
                    out.append(.init(path: entry.path, kind: .modified, staged: true))
                } else if flags.contains(.indexDeleted) {
                    out.append(.init(path: entry.path, kind: .deleted, staged: true))
                } else if flags.contains(.indexRenamed) {
                    out.append(.init(path: entry.path, kind: .renamed, staged: true))
                }
                if flags.contains(.wtNew) {
                    out.append(.init(path: entry.path, kind: .untracked, staged: false))
                } else if flags.contains(.wtModified) {
                    out.append(.init(path: entry.path, kind: .modified, staged: false))
                } else if flags.contains(.wtDeleted) {
                    out.append(.init(path: entry.path, kind: .deleted, staged: false))
                } else if flags.contains(.wtRenamed) {
                    out.append(.init(path: entry.path, kind: .renamed, staged: false))
                }
                if flags.contains(.conflicted) {
                    out.append(.init(path: entry.path, kind: .conflicted, staged: false))
                }
            }
            return out
        } catch let error as Git2.GitError {
            throw Self.mapError(error, hint: directory.path)
        }
    }

    public func diff(in directory: URL, paths: [String]?, staged: Bool) async throws -> String {
        do {
            _ = try repository(at: directory) // ensure bootstrap + valid repo
            let raw = try RawRepo.open(directory)
            defer { raw.close() }
            return try raw.unifiedDiff(paths: paths, staged: staged)
        } catch let error as Git2.GitError {
            throw Self.mapError(error, hint: directory.path)
        } catch let error as RawRepo.Error {
            throw LocalAICore.GitError.commandFailed(error.message)
        }
    }

    public func stage(in directory: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        do {
            let repo = try repository(at: directory)
            let index = try repo.index()
            for path in paths {
                let absPath = directory.appendingPathComponent(path).path
                if FileManager.default.fileExists(atPath: absPath) {
                    try index.addPath(path)
                } else {
                    try index.removePath(path)
                }
            }
            try index.save()
        } catch let error as Git2.GitError {
            throw Self.mapError(error, hint: directory.path)
        }
    }

    public func unstage(in directory: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        do {
            _ = try repository(at: directory)
            let raw = try RawRepo.open(directory)
            defer { raw.close() }
            for path in paths { try raw.unstagePath(path) }
        } catch let error as Git2.GitError {
            throw Self.mapError(error, hint: directory.path)
        } catch let error as RawRepo.Error {
            throw LocalAICore.GitError.commandFailed(error.message)
        }
    }

    public func commit(in directory: URL, message: String, author: GitAuthor) async throws -> String {
        do {
            let repo = try repository(at: directory)
            let index = try repo.index()
            let tree = try index.writeTree()
            let signature = Signature(
                name: author.name, email: author.email,
                date: Date(), timeZone: .current
            )
            let parents: [Commit]
            if repo.isHeadUnborn {
                parents = []
            } else {
                parents = [try repo.head().resolveToCommit()]
            }
            let newCommit = try repo.commit(
                tree: tree, parents: parents,
                author: signature, message: message,
                updatingRef: "HEAD"
            )
            try index.save()
            return newCommit.oid.hex
        } catch let error as Git2.GitError {
            throw Self.mapError(error, hint: directory.path)
        }
    }

    public func pull(in directory: URL, credentials: GitCredentials?) async throws -> GitPullResult {
        do {
            let repo = try repository(at: directory)
            let branchName = try await currentBranch(in: directory)
            let beforeOID: OID? = repo.isHeadUnborn ? nil : try? repo.head().resolveToCommit().oid

            var pullOpts = Repository.PullOptions()
            pullOpts.fetch.credentials = credentialsHandler(for: credentials)
            pullOpts.allowNonFastForward = false

            let analysis = try repo.pull(
                remoteNamed: "origin", branchNamed: branchName, options: pullOpts
            )

            if analysis.contains(.upToDate) { return .upToDate }
            if analysis.contains(.fastForward) || analysis.contains(.unborn) {
                let afterOID = try? repo.head().resolveToCommit().oid
                var commits = 0
                if let beforeOID, let afterOID, beforeOID != afterOID {
                    commits = Self.countCommits(repo: repo, from: beforeOID, to: afterOID)
                } else if beforeOID == nil, afterOID != nil {
                    commits = 1
                }
                return .fastForward(commits: max(commits, 0))
            }
            return .conflict(paths: [])
        } catch let error as Git2.GitError {
            if error.code == .nonFastForward { throw LocalAICore.GitError.nonFastForward }
            if error.code == .conflict { throw LocalAICore.GitError.conflict([]) }
            throw Self.mapError(error, hint: directory.path)
        }
    }

    private static func countCommits(repo: Repository, from old: OID, to new: OID) -> Int {
        guard let tip = try? repo.commit(for: new) else { return 0 }
        var count = 0
        for commit in repo.log(from: tip) {
            if commit.oid == old { break }
            count += 1
            if count > 1000 { break }
        }
        return count
    }

    public func push(in directory: URL, remote: String, branch: String?, credentials: GitCredentials?, force: Bool) async throws {
        // Never force: the protocol's `force` parameter is accepted for parity
        // with the desktop implementation but ignored here. Force pushes bypass
        // the safety rails we expose in the UI, so we always send a plain refspec.
        _ = force
        do {
            let repo = try repository(at: directory)
            let branchName: String
            if let branch {
                branchName = branch
            } else {
                branchName = try await currentBranch(in: directory)
            }
            let spec = Refspec("refs/heads/\(branchName):refs/heads/\(branchName)")
            var opts = Repository.PushOptions()
            opts.credentials = credentialsHandler(for: credentials)
            try repo.push(remoteNamed: remote, refspecs: [spec], options: opts)
        } catch let error as Git2.GitError {
            if error.code == .nonFastForward { throw LocalAICore.GitError.nonFastForward }
            throw Self.mapError(error, hint: directory.path)
        }
    }

    public func branches(in directory: URL) async throws -> [GitBranch] {
        do {
            let repo = try repository(at: directory)
            let currentShort = repo.isHeadUnborn ? nil : try? await currentBranch(in: directory)
            var out: [GitBranch] = []
            for ref in repo.references() {
                let name = ref.name
                if name.hasPrefix("refs/heads/") {
                    let short = String(name.dropFirst("refs/heads/".count))
                    out.append(GitBranch(name: short, isCurrent: short == currentShort, isRemote: false))
                } else if name.hasPrefix("refs/remotes/") {
                    let short = String(name.dropFirst("refs/remotes/".count))
                    if short.hasSuffix("/HEAD") { continue }
                    out.append(GitBranch(name: short, isCurrent: false, isRemote: true))
                }
            }
            return out
        } catch let error as Git2.GitError {
            throw Self.mapError(error, hint: directory.path)
        }
    }

    public func currentBranch(in directory: URL) async throws -> String {
        do {
            let repo = try repository(at: directory)
            let head = try repo.head()
            return head.shorthand
        } catch let error as Git2.GitError {
            // Unborn HEAD: report the symbolic target.
            if error.code == .unbornBranch {
                // Re-open raw to read the symbolic ref. Cheap enough.
                if let raw = try? RawRepo.open(directory) {
                    defer { raw.close() }
                    if let branch = raw.unbornHeadBranch() { return branch }
                }
                return "main"
            }
            throw Self.mapError(error, hint: directory.path)
        }
    }

    public func checkout(in directory: URL, branch: String, create: Bool) async throws {
        do {
            let repo = try repository(at: directory)
            if create {
                if try repo.reference(named: "refs/heads/\(branch)") != nil {
                    throw LocalAICore.GitError.branchExists(branch)
                }
                let tip = try repo.head().resolveToCommit()
                _ = try repo.createBranch(named: branch, at: tip, force: false)
                try repo.checkout(branchNamed: branch)
            } else {
                do {
                    try repo.checkout(branchNamed: branch)
                } catch let error as Git2.GitError where error.code == .notFound {
                    throw LocalAICore.GitError.branchNotFound(branch)
                }
            }
        } catch let error as Git2.GitError {
            throw Self.mapError(error, hint: directory.path)
        }
    }

    // MARK: - iOS-specific helpers

    /// True when `directory` is inside a git repository.
    public func isGitRepository(at directory: URL) -> Bool {
        (try? repository(at: directory)) != nil
    }

    /// Commits HEAD is ahead of `refs/remotes/origin/<currentBranch>`.
    /// Returns 0 when no upstream exists yet (i.e. never pushed).
    public func aheadCount(in directory: URL) async -> Int {
        do {
            let repo = try repository(at: directory)
            guard !repo.isHeadUnborn else { return 0 }
            let branch = try await currentBranch(in: directory)
            guard let tracking = try repo.reference(named: "refs/remotes/origin/\(branch)") else {
                return 0
            }
            let localTip = try repo.head().resolveToCommit().oid
            let remoteTip = try tracking.resolveToCommit().oid
            if localTip == remoteTip { return 0 }
            return Self.countCommits(repo: repo, from: remoteTip, to: localTip)
        } catch {
            return 0
        }
    }

    /// Restore a file's working-tree contents from HEAD (`git checkout HEAD -- path`).
    public func revertFile(in directory: URL, path: String) async throws {
        do {
            _ = try repository(at: directory)
            let raw = try RawRepo.open(directory)
            defer { raw.close() }
            try raw.checkoutPathFromHead(path)
        } catch let error as Git2.GitError {
            throw Self.mapError(error, hint: directory.path)
        } catch let error as RawRepo.Error {
            throw LocalAICore.GitError.commandFailed(error.message)
        }
    }
}
