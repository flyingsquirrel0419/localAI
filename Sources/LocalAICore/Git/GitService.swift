import Foundation

public enum GitFileKind: String, Sendable, Equatable, Codable {
    case modified, added, deleted, renamed, untracked, conflicted
}

public struct GitFileStatus: Sendable, Equatable, Codable {
    public let path: String
    public let kind: GitFileKind
    public let staged: Bool

    public init(path: String, kind: GitFileKind, staged: Bool) {
        self.path = path
        self.kind = kind
        self.staged = staged
    }
}

public enum GitPullResult: Sendable, Equatable {
    case fastForward(commits: Int)
    case upToDate
    case conflict(paths: [String])
}

public struct GitBranch: Sendable, Equatable, Codable {
    public let name: String
    public let isCurrent: Bool
    public let isRemote: Bool

    public init(name: String, isCurrent: Bool, isRemote: Bool) {
        self.name = name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
    }
}

public struct GitAuthor: Sendable, Equatable {
    public let name: String
    public let email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }
}

/// Credentials for a git remote. The token value is only ever handed to the
/// transport layer — never surfaced to the agent, logs, or error text.
public struct GitCredentials: Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Supplies credentials on demand. Backed by a CredentialStore in production
/// so the token itself never flows through agent-visible strings.
public protocol GitCredentialProvider: Sendable {
    func credentials(for remoteURL: URL?) async throws -> GitCredentials?
}

public struct CredentialStoreGitCredentialProvider: GitCredentialProvider {
    public let store: CredentialStore
    public let key: CredentialKey

    public init(store: CredentialStore, key: CredentialKey = .githubToken) {
        self.store = store
        self.key = key
    }

    public func credentials(for remoteURL: URL?) async throws -> GitCredentials? {
        guard let token = try store.get(key), !token.isEmpty else { return nil }
        // x-access-token is GitHub's canonical username for PAT auth.
        return GitCredentials(username: "x-access-token", password: token)
    }
}

public enum GitError: Error, Equatable, Sendable {
    case notARepository(String)
    case authenticationFailed
    case nonFastForward
    case conflict([String])
    case network(String)
    case branchNotFound(String)
    case branchExists(String)
    case commandFailed(String)
}

extension GitError: UserFacingErrorConvertible {
    public var userFacingError: UserFacingError {
        switch self {
        case .notARepository(let path):
            return UserFacingError(
                title: "Not a git repository",
                message: "\"\(path)\" isn't a git repository.",
                recoveryAction: .dismiss,
                developerDetails: "notARepository: \(SecretRedactor.redact(path))"
            )
        case .authenticationFailed:
            return UserFacingError(
                title: "Authentication failed",
                message: "GitHub rejected the stored credentials. Sign in again with a valid token.",
                recoveryAction: .signIn,
                developerDetails: "authenticationFailed"
            )
        case .nonFastForward:
            return UserFacingError(
                title: "Push rejected",
                message: "Remote has new commits. Pull first.",
                recoveryAction: .retry,
                developerDetails: "nonFastForward"
            )
        case .conflict(let paths):
            return UserFacingError(
                title: "Merge conflict",
                message: "Conflicts in: \(paths.joined(separator: ", ")). Resolve them before continuing.",
                recoveryAction: .dismiss,
                developerDetails: "conflict: \(paths.joined(separator: ","))"
            )
        case .network(let detail):
            return UserFacingError(
                title: "Network error",
                message: "Couldn't reach the remote. Check your connection and try again.",
                recoveryAction: .retry,
                developerDetails: SecretRedactor.redact(detail)
            )
        case .branchNotFound(let name):
            return UserFacingError(
                title: "Branch not found",
                message: "Branch \"\(name)\" doesn't exist.",
                recoveryAction: .dismiss,
                developerDetails: "branchNotFound: \(name)"
            )
        case .branchExists(let name):
            return UserFacingError(
                title: "Branch exists",
                message: "A branch named \"\(name)\" already exists.",
                recoveryAction: .dismiss,
                developerDetails: "branchExists: \(name)"
            )
        case .commandFailed(let detail):
            return UserFacingError(
                title: "Git operation failed",
                message: "The git operation could not be completed.",
                recoveryAction: .retry,
                developerDetails: SecretRedactor.redact(detail)
            )
        }
    }
}

/// Git operations over a working copy. iOS will implement this via libgit2;
/// desktop/tests use CLIGitService.
public protocol GitService: Sendable {
    /// Clone `url` into `directory`. `url` may be https or a local path.
    func clone(url: URL, to directory: URL, branch: String?, credentials: GitCredentials?) async throws
    func status(in directory: URL) async throws -> [GitFileStatus]
    /// Unified diff. `staged` diffs the index against HEAD; otherwise worktree against index.
    func diff(in directory: URL, paths: [String]?, staged: Bool) async throws -> String
    func stage(in directory: URL, paths: [String]) async throws
    func unstage(in directory: URL, paths: [String]) async throws
    /// Commit staged changes; returns the new commit SHA.
    func commit(in directory: URL, message: String, author: GitAuthor) async throws -> String
    func pull(in directory: URL, credentials: GitCredentials?) async throws -> GitPullResult
    func push(in directory: URL, remote: String, branch: String?, credentials: GitCredentials?, force: Bool) async throws
    func branches(in directory: URL) async throws -> [GitBranch]
    func currentBranch(in directory: URL) async throws -> String
    func checkout(in directory: URL, branch: String, create: Bool) async throws
}
