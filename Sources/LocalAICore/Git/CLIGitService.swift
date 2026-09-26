#if os(macOS) || os(Linux)
import Foundation

/// GitService implementation shelling out to the `git` executable.
/// Available on macOS/Linux only; iOS uses a libgit2-backed implementation.
///
/// Credentials are passed via a temporary GIT_ASKPASS helper script — never on
/// the command line or embedded in URLs, so they can't leak into process
/// listings or logs.
public final class CLIGitService: GitService, @unchecked Sendable {
    private let gitPath: String

    public init(gitPath: String = "/usr/bin/git") {
        self.gitPath = gitPath
    }

    // MARK: - Process plumbing

    private struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func run(
        _ args: [String],
        in directory: URL?,
        environment: [String: String] = [:]
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gitPath)
            process.arguments = args
            if let directory {
                process.currentDirectoryURL = directory
            }
            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["LC_ALL"] = "C"
            for (k, v) in environment { env[k] = v }
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: GitError.commandFailed("launch git: \(error.localizedDescription)"))
                return
            }
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: Result(
                status: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            ))
        }
    }

    /// Run a git command that must succeed; classify failure into GitError.
    private func runChecked(
        _ args: [String],
        in directory: URL?,
        credentials: GitCredentials? = nil,
        failureHint: String? = nil
    ) async throws -> Result {
        var env: [String: String] = [:]
        var cleanup: (() -> Void)?
        if let credentials {
            let (helperDir, askpass) = try Self.writeAskPassHelper(credentials: credentials)
            env["GIT_ASKPASS"] = askpass.path
            cleanup = { try? FileManager.default.removeItem(at: helperDir) }
        }
        defer { cleanup?() }
        let result = try await run(args, in: directory, environment: env)
        guard result.status == 0 else {
            throw Self.classifyFailure(stderr: result.stderr, hint: failureHint)
        }
        return result
    }

    private static func classifyFailure(stderr: String, hint: String?) -> GitError {
        let lower = stderr.lowercased()
        // Non-fast-forward rejection is checked first: git's rejection text can
        // contain auth-adjacent phrases on some platform gits (e.g. credential
        // helper chatter on macOS), and rejection never means auth failure.
        if lower.contains("non-fast-forward") || lower.contains("fetch first")
            || lower.contains("updates were rejected") || lower.contains("rejected") {
            return .nonFastForward
        }
        if lower.contains("authentication failed") || lower.contains("authentication required")
            || lower.contains("403") || lower.contains("401")
            || lower.contains("could not read username") || lower.contains("permission denied") {
            return .authenticationFailed
        }
        if lower.contains("could not resolve host") || lower.contains("connection refused")
            || lower.contains("network is unreachable") || lower.contains("operation timed out")
            || lower.contains("failed to connect") {
            return .network(stderr)
        }
        if lower.contains("not a git repository") {
            return .notARepository(hint ?? "")
        }
        return .commandFailed(stderr)
    }

    /// Write a tiny executable askpass script into a private temp dir.
    /// The script prints the password when asked; username is printed when the
    /// prompt mentions "Username". File mode 0700, dir mode 0700.
    private static func writeAskPassHelper(credentials: GitCredentials) throws -> (dir: URL, script: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("localai-git-askpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let script = dir.appendingPathComponent("askpass.sh")
        // Quote values with single quotes after escaping embedded ones.
        func shellQuote(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let body = """
        #!/bin/sh
        case "$1" in
          *Username*|*username*) printf '%s' \(shellQuote(credentials.username)) ;;
          *) printf '%s' \(shellQuote(credentials.password)) ;;
        esac
        """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return (dir, script)
    }

    // MARK: - GitService

    public func clone(url: URL, to directory: URL, branch: String?, credentials: GitCredentials?) async throws {
        var args = ["clone", "--", url.absoluteString]
        if let branch {
            args = ["clone", "--branch", branch, "--", url.absoluteString]
        }
        // For file paths git treats them as paths, not URLs — pass through as given.
        let target: String
        if url.isFileURL {
            target = url.path
        } else {
            target = url.absoluteString
        }
        args = branch != nil
            ? ["clone", "--branch", branch!, "--", target, directory.path]
            : ["clone", "--", target, directory.path]
        _ = try await runChecked(args, in: nil, credentials: credentials, failureHint: url.absoluteString)
    }

    public func status(in directory: URL) async throws -> [GitFileStatus] {
        let result = try await runChecked(
            ["status", "--porcelain=v1", "--untracked-files=all"],
            in: directory, failureHint: directory.path
        )
        return Self.parsePorcelain(result.stdout)
    }

    static func parsePorcelain(_ text: String) -> [GitFileStatus] {
        var statuses: [GitFileStatus] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            guard line.count >= 4 else { continue }
            let x = line[line.startIndex]
            let y = line[line.index(line.startIndex, offsetBy: 1)]
            var pathField = String(line.dropFirst(3))
            // Renames/copies: "old -> new"
            if let arrowRange = pathField.range(of: " -> ") {
                pathField = String(pathField[arrowRange.upperBound...])
            }
            let statusesForCodes: [(Character, Bool)] = [(x, true), (y, false)]
            for (code, staged) in statusesForCodes {
                guard let kind = kindFor(code) else { continue }
                statuses.append(GitFileStatus(path: pathField, kind: kind, staged: staged))
            }
        }
        return statuses
    }

    private static func kindFor(_ code: Character) -> GitFileKind? {
        switch code {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R", "C": return .renamed
        case "?": return .untracked
        case "U": return .conflicted
        case " ", ".": return nil
        default: return nil
        }
    }

    public func diff(in directory: URL, paths: [String]?, staged: Bool) async throws -> String {
        var args = ["diff", "--no-color", "--no-ext-diff"]
        if staged { args.append("--cached") }
        if let paths, !paths.isEmpty {
            args.append("--")
            args.append(contentsOf: paths)
        }
        let result = try await runChecked(args, in: directory, failureHint: directory.path)
        return result.stdout
    }

    public func stage(in directory: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runChecked(["add", "--"] + paths, in: directory, failureHint: directory.path)
    }

    public func unstage(in directory: URL, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runChecked(["restore", "--staged", "--"] + paths, in: directory, failureHint: directory.path)
    }

    public func commit(in directory: URL, message: String, author: GitAuthor) async throws -> String {
        _ = try await runChecked(
            [
                "-c", "user.name=\(author.name)",
                "-c", "user.email=\(author.email)",
                "commit", "--message", message
            ],
            in: directory
        )
        let rev = try await runChecked(["rev-parse", "HEAD"], in: directory)
        return rev.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func pull(in directory: URL, credentials: GitCredentials?) async throws -> GitPullResult {
        let before = (try? await runChecked(["rev-parse", "HEAD"], in: directory))?.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try await runChecked(
            ["pull", "--ff-only", "--no-edit"],
            in: directory, credentials: credentials
        )
        let combined = result.stdout + "\n" + result.stderr
        if combined.contains("Already up to date") {
            return .upToDate
        }
        let after = try? await runChecked(["rev-parse", "HEAD"], in: directory)
        let afterSHA = after?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        var commits = 0
        if let before, let afterSHA, before != afterSHA {
            let count = try? await runChecked(
                ["rev-list", "--count", "\(before)..\(afterSHA)"], in: directory
            )
            commits = Int(count?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 1
        }
        return .fastForward(commits: max(commits, before == afterSHA ? 0 : 1))
    }

    public func push(in directory: URL, remote: String, branch: String?, credentials: GitCredentials?, force: Bool) async throws {
        var args = ["push"]
        if force { args.append("--force-with-lease") }
        args.append(remote)
        if let branch { args.append(branch) }
        _ = try await runChecked(args, in: directory, credentials: credentials)
    }

    public func branches(in directory: URL) async throws -> [GitBranch] {
        let result = try await runChecked(
            ["branch", "--all", "--format=%(refname:short)%09%(HEAD)"],
            in: directory, failureHint: directory.path
        )
        var branches: [GitBranch] = []
        for rawLine in result.stdout.split(separator: "\n") {
            let line = String(rawLine)
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let nameRaw = parts.first else { continue }
            let name = String(nameRaw)
            let isCurrent = parts.count > 1 && parts[1] == "*"
            let isRemote = name.hasPrefix("remotes/") || name.contains("/HEAD")
            if name.hasSuffix("/HEAD") { continue }
            branches.append(GitBranch(name: name, isCurrent: isCurrent, isRemote: isRemote))
        }
        return branches
    }

    public func currentBranch(in directory: URL) async throws -> String {
        let result = try await runChecked(
            ["branch", "--show-current"], in: directory, failureHint: directory.path
        )
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func checkout(in directory: URL, branch: String, create: Bool) async throws {
        if create {
            let existing = try await branches(in: directory)
            if existing.contains(where: { $0.name == branch && !$0.isRemote }) {
                throw GitError.branchExists(branch)
            }
            _ = try await runChecked(["checkout", "-b", branch], in: directory)
        } else {
            let result = try await run(["checkout", branch], in: directory)
            guard result.status == 0 else {
                if result.stderr.lowercased().contains("did not match any file")
                    || result.stderr.lowercased().contains("invalid reference") {
                    throw GitError.branchNotFound(branch)
                }
                throw Self.classifyFailure(stderr: result.stderr, hint: nil)
            }
        }
    }
}
#endif
