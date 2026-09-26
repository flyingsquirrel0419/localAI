import Foundation

public enum ToolExecutionResult: Sendable, Equatable {
    /// Normal completion; `output` is already truncated + redacted.
    case success(output: String)
    /// Tool declined without user confirmation. The loop surfaces this to UI.
    case needsConfirmation(description: String, resumeToken: UUID)
    /// Failed; `message` is model-friendly text fed back into the loop.
    case failure(message: String)
}

public struct ToolActivity: Sendable, Equatable {
    public let title: String

    public init(title: String) {
        self.title = title
    }
}

public enum ToolPolicy {
    /// Char budget for any single tool output handed back to the model.
    public static let maxOutputChars = 6000
    /// Default timeout for node/npm invocations from the agent.
    public static let defaultCommandTimeout: TimeInterval = 120
}

/// Everything the executor needs to act on a workspace.
public struct ToolContext: Sendable {
    public let fileSystem: SandboxedFileSystem
    public let search: RepositorySearch
    public let git: (any GitService)?
    public let runtime: (any JavaScriptRuntimeService)?
    public let credentialProvider: (any GitCredentialProvider)?
    /// Repository working copy URL — usually the workspace root.
    public let repositoryDirectory: URL
    /// Whether the user's current request explicitly authorizes pushing.
    public let userAuthorizedPush: Bool
    /// Async UI hook: returns true if the user confirms. May be nil in tests,
    /// in which case actions requiring confirmation are refused.
    public let confirm: (@Sendable (String) async -> Bool)?

    public init(
        fileSystem: SandboxedFileSystem,
        search: RepositorySearch,
        git: (any GitService)? = nil,
        runtime: (any JavaScriptRuntimeService)? = nil,
        credentialProvider: (any GitCredentialProvider)? = nil,
        repositoryDirectory: URL,
        userAuthorizedPush: Bool = false,
        confirm: (@Sendable (String) async -> Bool)? = nil
    ) {
        self.fileSystem = fileSystem
        self.search = search
        self.git = git
        self.runtime = runtime
        self.credentialProvider = credentialProvider
        self.repositoryDirectory = repositoryDirectory
        self.userAuthorizedPush = userAuthorizedPush
        self.confirm = confirm
    }
}

/// Executes typed tool calls against a ToolContext.
public actor ToolExecutor {
    public let context: ToolContext
    /// Files the agent has modified via write/create/edit/move/delete/patch in this run.
    private(set) public var changedFiles: Set<String> = []

    public init(context: ToolContext) {
        self.context = context
    }

    public func resetChangedFiles() { changedFiles = [] }

    /// Human-readable activity line for the UI.
    public func activity(for call: ToolCall) -> ToolActivity {
        switch call.tool {
        case "read_file":
            return ToolActivity(title: "Reading \(arg(call, "path") ?? "file")")
        case "write_file", "create_file":
            return ToolActivity(title: "Writing \(arg(call, "path") ?? "file")")
        case "edit_file":
            return ToolActivity(title: "Editing \(arg(call, "path") ?? "file")")
        case "delete_file":
            return ToolActivity(title: "Deleting \(arg(call, "path") ?? "file")")
        case "move_file":
            return ToolActivity(title: "Moving \(arg(call, "source") ?? "file")")
        case "list_directory":
            return ToolActivity(title: "Listing \(arg(call, "path") ?? ".")")
        case "search_files":
            return ToolActivity(title: "Searching files for \"\(arg(call, "query") ?? "")\"")
        case "search_text":
            return ToolActivity(title: "Searching \"\(arg(call, "pattern") ?? "")\"")
        case "apply_patch":
            return ToolActivity(title: "Applying patch")
        case "run_node":
            return ToolActivity(title: "Running node \(arg(call, "script") ?? "")")
        case "run_npm":
            let args = arrayArg(call, "args")?.joined(separator: " ") ?? ""
            return ToolActivity(title: "Running npm \(args)")
        case "git_clone":
            return ToolActivity(title: "Cloning repository")
        case "git_status":
            return ToolActivity(title: "Checking git status")
        case "git_diff":
            return ToolActivity(title: "Computing diff")
        case "git_add":
            return ToolActivity(title: "Staging changes")
        case "git_commit":
            return ToolActivity(title: "Committing")
        case "git_pull":
            return ToolActivity(title: "Pulling")
        case "git_push":
            return ToolActivity(title: "Pushing")
        case "git_branch":
            return ToolActivity(title: "Managing branches")
        case "get_project_info":
            return ToolActivity(title: "Reading project info")
        default:
            return ToolActivity(title: "Running \(call.tool)")
        }
    }

    /// Execute a validated tool call. All outputs are truncated + redacted.
    public func execute(_ call: ToolCall) async -> ToolExecutionResult {
        let raw: ToolExecutionResult
        do {
            raw = try await dispatch(call)
        } catch {
            raw = .failure(message: Self.describe(error))
        }
        switch raw {
        case .success(let output):
            return .success(output: Self.postProcess(output))
        case .failure(let message):
            return .failure(message: SecretRedactor.redact(message))
        case .needsConfirmation:
            return raw
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ call: ToolCall) async throws -> ToolExecutionResult {
        switch call.tool {
        case "list_directory": return try await listDirectory(call)
        case "read_file": return try await readFile(call)
        case "write_file": return try await writeFile(call, create: false)
        case "create_file": return try await writeFile(call, create: true)
        case "delete_file": return try await deleteFile(call)
        case "move_file": return try await moveFile(call)
        case "search_files": return try await searchFiles(call)
        case "search_text": return try await searchText(call)
        case "apply_patch": return try await applyPatch(call)
        case "edit_file": return try await editFile(call)
        case "run_node": return try await runNode(call)
        case "run_npm": return try await runNpm(call)
        case "git_clone": return try await gitClone(call)
        case "git_status": return try await gitStatus(call)
        case "git_diff": return try await gitDiff(call)
        case "git_add": return try await gitAdd(call)
        case "git_commit": return try await gitCommit(call)
        case "git_pull": return try await gitPull(call)
        case "git_push": return try await gitPush(call)
        case "git_branch": return try await gitBranch(call)
        case "get_project_info": return try await projectInfo(call)
        default:
            return .failure(message: "Unknown tool \"\(call.tool)\". Use one of: \(AgentTools.byName.keys.sorted().joined(separator: ", ")).")
        }
    }

    // MARK: - Files

    private func listDirectory(_ call: ToolCall) throws -> ToolExecutionResult {
        let path = arg(call, "path") ?? "."
        let nodes = try context.fileSystem.listDirectory(path)
        let lines = nodes.map { node -> String in
            let size = node.size.map { " (\($0) B)" } ?? ""
            return (node.isDirectory ? "dir  " : "file ") + node.relativePath + size
        }
        return .success(output: lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"))
    }

    private func readFile(_ call: ToolCall) throws -> ToolExecutionResult {
        guard let path = arg(call, "path") else {
            return .failure(message: "read_file requires \"path\".")
        }
        let text = try context.fileSystem.read(path)
        let startLine = intArg(call, "startLine")
        let endLine = intArg(call, "endLine")
        if startLine == nil, endLine == nil {
            return .success(output: text)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = max((startLine ?? 1) - 1, 0)
        let end = min(endLine ?? lines.count, lines.count)
        guard start < end else {
            return .success(output: "(file has \(lines.count) lines; requested range is empty)")
        }
        let slice = lines[start..<end]
        var numbered = ""
        for (offset, line) in slice.enumerated() {
            numbered += "\(start + offset + 1): \(line)\n"
        }
        return .success(output: numbered)
    }

    private func writeFile(_ call: ToolCall, create: Bool) throws -> ToolExecutionResult {
        guard let path = arg(call, "path") else {
            return .failure(message: "write_file/create_file requires \"path\".")
        }
        let contents = arg(call, "contents") ?? ""
        if create {
            try context.fileSystem.createFile(path, contents: contents)
        } else {
            try context.fileSystem.write(path, contents: contents)
        }
        changedFiles.insert(path)
        return .success(output: "\(create ? "Created" : "Wrote") \(path) (\(contents.count) chars).")
    }

    private func deleteFile(_ call: ToolCall) async throws -> ToolExecutionResult {
        guard let path = arg(call, "path") else {
            return .failure(message: "delete_file requires \"path\".")
        }
        let stat = try context.fileSystem.stat(path)
        if stat.isDirectory {
            let description = "Delete directory \"\(path)\" and all of its contents?"
            guard let confirm = context.confirm else {
                return .needsConfirmation(description: description, resumeToken: UUID())
            }
            let ok = await confirm(description)
            guard ok else {
                return .failure(message: "User declined to delete directory \"\(path)\".")
            }
            try context.fileSystem.delete(path, recursive: true)
        } else {
            try context.fileSystem.delete(path)
        }
        changedFiles.insert(path)
        return .success(output: "Deleted \(path).")
    }

    private func moveFile(_ call: ToolCall) throws -> ToolExecutionResult {
        guard let source = arg(call, "source"), let destination = arg(call, "destination") else {
            return .failure(message: "move_file requires \"source\" and \"destination\".")
        }
        try context.fileSystem.move(from: source, to: destination)
        changedFiles.insert(source)
        changedFiles.insert(destination)
        return .success(output: "Moved \(source) -> \(destination).")
    }

    // MARK: - Search

    private func searchFiles(_ call: ToolCall) async throws -> ToolExecutionResult {
        guard let query = arg(call, "query") else {
            return .failure(message: "search_files requires \"query\".")
        }
        let extensions = arrayArg(call, "extensions") ?? []
        let results = try await context.search.searchFiles(query: query, extensions: extensions)
        if results.isEmpty { return .success(output: "No files matched \"\(query)\".") }
        let lines = results.map { "\($0.relativePath)" }
        return .success(output: lines.joined(separator: "\n"))
    }

    private func searchText(_ call: ToolCall) async throws -> ToolExecutionResult {
        guard let pattern = arg(call, "pattern") else {
            return .failure(message: "search_text requires \"pattern\".")
        }
        let isRegex = boolArg(call, "isRegex") ?? false
        let extensions = arrayArg(call, "extensions") ?? []
        let results = try await context.search.searchText(
            pattern: pattern, isRegex: isRegex, extensions: extensions
        )
        if results.isEmpty { return .success(output: "No matches for \"\(pattern)\".") }
        let lines = results.map { "\($0.relativePath):\($0.line):\($0.column): \($0.preview)" }
        return .success(output: lines.joined(separator: "\n"))
    }

    // MARK: - Editing

    private func applyPatch(_ call: ToolCall) throws -> ToolExecutionResult {
        guard let diff = arg(call, "diff") else {
            return .failure(message: "apply_patch requires \"diff\".")
        }
        let files = try UnifiedDiff.parse(diff)
        var touched: [String] = []
        for file in files {
            let path = file.newPath
            let original = (try? context.fileSystem.read(path)) ?? ""
            let patched = try PatchApplier.apply(hunks: file.hunks, to: original)
            try context.fileSystem.write(path, contents: patched)
            touched.append(path)
            changedFiles.insert(path)
        }
        return .success(output: "Patched \(touched.count) file(s): \(touched.joined(separator: ", ")).")
    }

    private func editFile(_ call: ToolCall) throws -> ToolExecutionResult {
        guard let path = arg(call, "path"),
              let oldString = arg(call, "old_string"),
              let newString = arg(call, "new_string") else {
            return .failure(message: "edit_file requires \"path\", \"old_string\", and \"new_string\".")
        }
        let text = try context.fileSystem.read(path)
        let edited = try PatchApplier.searchReplace(text: text, oldString: oldString, newString: newString)
        try context.fileSystem.write(path, contents: edited)
        changedFiles.insert(path)
        return .success(output: "Edited \(path).")
    }

    // MARK: - Runtime

    private func runNode(_ call: ToolCall) async throws -> ToolExecutionResult {
        guard let runtime = context.runtime else {
            return .failure(message: "JavaScript runtime is not available in this environment.")
        }
        guard let script = arg(call, "script") else {
            return .failure(message: "run_node requires \"script\".")
        }
        let args = arrayArg(call, "args") ?? []
        let timeout = TimeInterval(intArg(call, "timeoutSeconds") ?? Int(ToolPolicy.defaultCommandTimeout))
        return try await collect(
            runtime.run(.node(script: script, args: args), in: context.repositoryDirectory,
                        environment: [:], timeout: timeout),
            label: "node \(script)"
        )
    }

    private func runNpm(_ call: ToolCall) async throws -> ToolExecutionResult {
        guard let runtime = context.runtime else {
            return .failure(message: "JavaScript runtime is not available in this environment.")
        }
        guard let args = arrayArg(call, "args"), !args.isEmpty else {
            return .failure(message: "run_npm requires \"args\" (e.g. [\"test\"]).")
        }
        // Native addon gate before install-ish commands.
        if args.first == "install" || args.first == "i" || args.first == "ci" {
            let found = NativeAddonDetector().detectNativePackages(in: context.repositoryDirectory)
            if !found.isEmpty {
                return .failure(message: "\(NativeAddonDetector.userMessage) Packages: \(found.joined(separator: ", ")).")
            }
        }
        let timeout = TimeInterval(intArg(call, "timeoutSeconds") ?? Int(ToolPolicy.defaultCommandTimeout))
        return try await collect(
            runtime.run(.npm(args: args), in: context.repositoryDirectory,
                        environment: [:], timeout: timeout),
            label: "npm \(args.joined(separator: " "))"
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<RuntimeEvent, Error>,
        label: String
    ) async throws -> ToolExecutionResult {
        var stdout = ""
        var stderr = ""
        var exitCode: Int32?
        var duration: TimeInterval = 0
        do {
            for try await event in stream {
                switch event {
                case .stdout(let chunk): stdout += chunk
                case .stderr(let chunk): stderr += chunk
                case .exited(let code, let d):
                    exitCode = code
                    duration = d
                }
            }
        } catch {
            return .failure(message: "\(label) failed: \(Self.describe(error))")
        }
        let code = exitCode ?? -1
        let summary = TestOutputSummarizer.summarize(stdout: stdout, stderr: stderr, exitCode: code)
        var body = ""
        if !stdout.isEmpty { body += "stdout:\n\(stdout)\n" }
        if !stderr.isEmpty { body += "stderr:\n\(stderr)\n" }
        body += "exit \(code) in \(String(format: "%.1f", duration))s"
        if !summary.isEmpty { body += "\n\(summary)" }
        if code == 0 {
            return .success(output: body)
        }
        return .failure(message: body)
    }
    // MARK: - Argument helpers

    func arg(_ call: ToolCall, _ name: String) -> String? {
        if let s = call.arguments[name] as? String { return s }
        if let n = call.arguments[name] as? NSNumber { return n.stringValue }
        return nil
    }

    func intArg(_ call: ToolCall, _ name: String) -> Int? {
        if let n = call.arguments[name] as? Int { return n }
        if let n = call.arguments[name] as? NSNumber { return n.intValue }
        if let s = call.arguments[name] as? String { return Int(s) }
        return nil
    }

    func boolArg(_ call: ToolCall, _ name: String) -> Bool? {
        if let b = call.arguments[name] as? Bool { return b }
        if let n = call.arguments[name] as? NSNumber { return n.boolValue }
        if let s = call.arguments[name] as? String {
            return ["true", "yes", "1"].contains(s.lowercased())
        }
        return nil
    }

    func arrayArg(_ call: ToolCall, _ name: String) -> [String]? {
        if let arr = call.arguments[name] as? [String] { return arr }
        if let arr = call.arguments[name] as? [Any] {
            return arr.compactMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }
        }
        if let s = call.arguments[name] as? String { return [s] }
        return nil
    }

    // MARK: - Output hygiene

    static func postProcess(_ output: String) -> String {
        var redacted = SecretRedactor.redact(output)
        if redacted.count > ToolPolicy.maxOutputChars {
            let head = redacted.prefix(ToolPolicy.maxOutputChars)
            redacted = String(head) + "\n… [truncated \(redacted.count - ToolPolicy.maxOutputChars) chars]"
        }
        return redacted
    }

    static func describe(_ error: Error) -> String {
        if let uf = error as? UserFacingErrorConvertible {
            return uf.userFacingError.message
        }
        if let uf = error as? UserFacingError {
            return uf.message
        }
        return UserFacingErrorMapper.map(error).message
    }
}

/// Parses common test-runner output to a one-line summary for the UI.
enum TestOutputSummarizer {
    static func summarize(stdout: String, stderr: String, exitCode: Int32) -> String {
        let combined = stdout + "\n" + stderr
        // node --test TAP summary: "# pass 84" / "# fail 3"
        var pass: Int?
        var fail: Int?
        for line in combined.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // node --test: older versions "# pass N", newer "ℹ pass N".
            for prefix in ["# pass ", "ℹ pass ", "pass "] {
                if trimmed.hasPrefix(prefix) {
                    pass = Int(trimmed.dropFirst(prefix.count).prefix(while: { $0.isNumber }))
                    break
                }
            }
            for prefix in ["# fail ", "ℹ fail ", "fail "] {
                if trimmed.hasPrefix(prefix) {
                    fail = Int(trimmed.dropFirst(prefix.count).prefix(while: { $0.isNumber }))
                    break
                }
            }
            if let range = trimmed.range(of: #"(\d+) passed"#, options: .regularExpression) {
                // jest-style "N passed"
                let digits = trimmed[range].dropLast(" passed".count)
                pass = Int(digits)
            } else if let range = trimmed.range(of: #"(\d+) failed"#, options: .regularExpression) {
                let digits = trimmed[range].dropLast(" failed".count)
                fail = Int(digits)
            }
        }
        if let fail, fail > 0 {
            return "\(fail) tests failed" + (pass.map { ", \($0) passed" } ?? "")
        }
        if let pass, pass > 0, (fail == nil || fail == 0) {
            return "✓ \(pass) tests passed"
        }
        return exitCode == 0 ? "exit 0" : "exit \(exitCode)"
    }
}
