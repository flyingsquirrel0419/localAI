import Foundation

extension ToolExecutor {
    // MARK: - Git tools

    func requireGit() throws -> any GitService {
        guard let git = context.git else {
            throw GitError.commandFailed("Git is not available in this environment.")
        }
        return git
    }

    func gitClone(_ call: ToolCall) async throws -> ToolExecutionResult {
        let git = try requireGit()
        guard let urlString = arg(call, "url"), let url = URL(string: urlString),
              let directory = arg(call, "directory") else {
            return .failure(message: "git_clone requires \"url\" and \"directory\".")
        }
        let branch = arg(call, "branch")
        let credentials = try await context.credentialProvider?.credentials(for: url)
        let target = try context.fileSystem.resolve(directory)
        try await git.clone(url: url, to: target, branch: branch, credentials: credentials)
        return .success(output: "Cloned \(urlString) into \(directory).")
    }

    func gitStatus(_ call: ToolCall) async throws -> ToolExecutionResult {
        let git = try requireGit()
        let statuses = try await git.status(in: context.repositoryDirectory)
        if statuses.isEmpty { return .success(output: "Working tree clean.") }
        let lines = statuses.map { "\($0.staged ? "staged  " : "unstaged") \($0.kind.rawValue) \($0.path)" }
        return .success(output: lines.joined(separator: "\n"))
    }

    func gitDiff(_ call: ToolCall) async throws -> ToolExecutionResult {
        let git = try requireGit()
        let paths = arrayArg(call, "paths")
        let staged = boolArg(call, "staged") ?? false
        let diff = try await git.diff(in: context.repositoryDirectory, paths: paths, staged: staged)
        return .success(output: diff.isEmpty ? "(no diff)" : diff)
    }

    func gitAdd(_ call: ToolCall) async throws -> ToolExecutionResult {
        let git = try requireGit()
        guard let paths = arrayArg(call, "paths"), !paths.isEmpty else {
            return .failure(message: "git_add requires \"paths\".")
        }
        try await git.stage(in: context.repositoryDirectory, paths: paths)
        return .success(output: "Staged \(paths.joined(separator: ", ")).")
    }

    func gitCommit(_ call: ToolCall) async throws -> ToolExecutionResult {
        let git = try requireGit()
        guard let message = arg(call, "message") else {
            return .failure(message: "git_commit requires \"message\".")
        }
        let author = GitAuthor(name: "LocalAI Agent", email: "agent@localai.local")
        let sha = try await git.commit(in: context.repositoryDirectory, message: message, author: author)
        return .success(output: "Committed \(String(sha.prefix(8))).")
    }

    func gitPull(_ call: ToolCall) async throws -> ToolExecutionResult {
        let git = try requireGit()
        let credentials = try await context.credentialProvider?.credentials(for: nil)
        let result = try await git.pull(in: context.repositoryDirectory, credentials: credentials)
        switch result {
        case .upToDate:
            return .success(output: "Already up to date.")
        case .fastForward(let commits):
            return .success(output: "Fast-forwarded by \(commits) commit(s).")
        case .conflict(let paths):
            return .failure(message: "Pull produced conflicts in: \(paths.joined(separator: ", ")). Resolve them.")
        }
    }

    func gitPush(_ call: ToolCall) async throws -> ToolExecutionResult {
        // Hard policy: push requires explicit user authorization for this request.
        guard context.userAuthorizedPush else {
            return .failure(message: "git_push is not allowed: the user did not ask to push in this request. Ask the user first.")
        }
        // Force push is never allowed.
        if boolArg(call, "force") == true {
            return .failure(message: "Force push is never allowed.")
        }
        let git = try requireGit()
        let remote = arg(call, "remote") ?? "origin"
        let branch: String
        if let requested = arg(call, "branch") {
            branch = requested
        } else {
            branch = try await git.currentBranch(in: context.repositoryDirectory)
        }
        let credentials = try await context.credentialProvider?.credentials(for: nil)
        try await git.push(in: context.repositoryDirectory, remote: remote, branch: branch, credentials: credentials, force: false)
        return .success(output: "Pushed \(branch) to \(remote).")
    }

    func gitBranch(_ call: ToolCall) async throws -> ToolExecutionResult {
        let git = try requireGit()
        if let create = arg(call, "create") {
            try await git.checkout(in: context.repositoryDirectory, branch: create, create: true)
            return .success(output: "Created and switched to branch \(create).")
        }
        if let checkout = arg(call, "checkout") {
            try await git.checkout(in: context.repositoryDirectory, branch: checkout, create: false)
            return .success(output: "Switched to branch \(checkout).")
        }
        let branches = try await git.branches(in: context.repositoryDirectory)
        let lines = branches.map { "\($0.isCurrent ? "* " : "  ")\($0.name)" }
        return .success(output: lines.isEmpty ? "(no branches)" : lines.joined(separator: "\n"))
    }

    // MARK: - Project info

    func projectInfo(_ call: ToolCall) async throws -> ToolExecutionResult {
        var out = ""
        if let packageText = try? context.fileSystem.read("package.json"),
           let data = packageText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = json["name"] as? String { out += "name: \(name)\n" }
            if let version = json["version"] as? String { out += "version: \(version)\n" }
            if let scripts = json["scripts"] as? [String: Any] {
                out += "scripts: \(scripts.keys.sorted().joined(separator: ", "))\n"
            }
            for section in ["dependencies", "devDependencies"] {
                if let deps = json[section] as? [String: Any], !deps.isEmpty {
                    out += "\(section): \(deps.keys.sorted().joined(separator: ", "))\n"
                }
            }
        } else {
            out += "package.json: (none)\n"
        }
        let topLevel = try context.fileSystem.listDirectory(".")
        out += "top-level:\n"
        for node in topLevel.prefix(50) {
            out += "  \(node.isDirectory ? "dir " : "file") \(node.name)\n"
        }
        if let git = context.git, let branch = try? await git.currentBranch(in: context.repositoryDirectory) {
            out += "git branch: \(branch)\n"
        }
        return .success(output: out)
    }
}
