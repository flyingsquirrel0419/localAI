#if os(macOS) || os(Linux)
import XCTest
@testable import LocalAICore

/// End-to-end agent acceptance test on Linux with no LLM: a ScriptedEngine
/// replays the exact tool calls a small model should make for the scenario,
/// AgentLoop wires everything through the real ToolExecutor, CLIGitService,
/// and NodeHostJavaScriptRuntime (via a real NodeHost subprocess).
final class AgentAcceptanceTests: XCTestCase {
    private var tempRoot: URL!
    private var remoteURL: URL!        // bare "remote" repo
    private var workspaceRoot: URL!    // sandbox root (clone lands inside)
    private var repoDir: URL!          // workspaceRoot/repo (the clone)
    private var launcher: ProcessNodeHostLauncher!
    private var port: Int = 0
    private let token = "acceptance-\(UUID().uuidString)"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        remoteURL = tempRoot.appendingPathComponent("remote.git", isDirectory: true)
        workspaceRoot = tempRoot.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

        // 1. Seed a bare "remote" with the buggy-project contents.
        let fixture = Self.nodeHostDirectory()
            .appendingPathComponent("test/fixtures/buggy-project", isDirectory: true)
        let seed = tempRoot.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.copyItem(at: fixture, to: seed)
        try shell("git", ["init", "-b", "main"], at: seed)
        try shell("git", ["-c", "user.name=Seed", "-c", "user.email=seed@x", "add", "."], at: seed)
        try shell("git", ["-c", "user.name=Seed", "-c", "user.email=seed@x", "commit", "-m", "initial"], at: seed)
        try shell("git", ["init", "--bare", "-b", "main", remoteURL.path], at: tempRoot)
        try shell("git", ["push", remoteURL.path, "main"], at: seed)

        // 2. Start a real NodeHost.
        let hostScript = Self.nodeHostDirectory().appendingPathComponent("host.js")
        port = 21000 + Int.random(in: 0..<20000)
        launcher = ProcessNodeHostLauncher(hostScript: hostScript)
        try await launcher.start(port: port, token: token)
    }

    override func tearDown() async throws {
        await launcher?.stop()
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    static func nodeHostDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("NodeHost", isDirectory: true)
    }

    private func shell(_ cmd: String, _ args: [String], at dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/\(cmd)")
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let err = String(data: (p.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data(), encoding: .utf8) ?? ""
            throw NSError(domain: "shell", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(cmd) \(args) -> \(p.terminationStatus): \(err)"])
        }
    }

    private func makeContext(userAuthorizedPush: Bool) -> ToolContext {
        let fs = try! SandboxedFileSystem(rootURL: workspaceRoot)
        return ToolContext(
            fileSystem: fs,
            search: RepositorySearch(fileSystem: fs),
            git: CLIGitService(),
            runtime: NodeHostJavaScriptRuntime(port: port, token: token),
            credentialProvider: nil,
            repositoryDirectory: workspaceRoot,
            userAuthorizedPush: userAuthorizedPush,
            confirm: { _ in true }
        )
    }

    private func runLoop(
        outputs: [String],
        request: String,
        userAuthorizedPush: Bool
    ) async -> [AgentEvent] {
        let loop = AgentLoop(
            engine: ScriptedEngine(outputs: outputs),
            executor: ToolExecutor(context: makeContext(userAuthorizedPush: userAuthorizedPush)),
            contextWindow: ContextWindowManager(tokenBudget: 8192),
            limits: AgentLimits(maxIterations: 30, maxToolCalls: 40, overallTimeout: 300, perToolTimeout: 60),
            taskStore: nil,
            workspaceId: UUID()
        )
        var events: [AgentEvent] = []
        for await event in await loop.run(taskId: UUID(), userRequest: request) {
            events.append(event)
        }
        return events
    }

    /// After the scripted clone, the workspace's repositoryDirectory must point
    /// at the cloned repo for subsequent tool calls. AgentLoop builds its
    /// executor from the initial context, so we perform the clone *outside*
    /// the loop (matching how the app clones before starting an agent run),
    /// then point the loop's context at the clone.
    private func cloneIntoWorkspace() async throws {
        repoDir = workspaceRoot.appendingPathComponent("repo", isDirectory: true)
        let git = CLIGitService()
        try await git.clone(url: URL(fileURLWithPath: remoteURL.path), to: repoDir, branch: nil, credentials: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoDir.appendingPathComponent("package.json").path),
                      "clone should have produced package.json")
    }

    private func makeRepoContext(userAuthorizedPush: Bool) -> ToolContext {
        let fs = try! SandboxedFileSystem(rootURL: repoDir)
        return ToolContext(
            fileSystem: fs,
            search: RepositorySearch(fileSystem: fs),
            git: CLIGitService(),
            runtime: NodeHostJavaScriptRuntime(port: port, token: token),
            credentialProvider: nil,
            repositoryDirectory: repoDir,
            userAuthorizedPush: userAuthorizedPush,
            confirm: { _ in true }
        )
    }

    private func runRepoLoop(
        outputs: [String],
        request: String,
        userAuthorizedPush: Bool
    ) async -> [AgentEvent] {
        let loop = AgentLoop(
            engine: ScriptedEngine(outputs: outputs),
            executor: ToolExecutor(context: makeRepoContext(userAuthorizedPush: userAuthorizedPush)),
            contextWindow: ContextWindowManager(tokenBudget: 8192),
            limits: AgentLimits(maxIterations: 30, maxToolCalls: 40, overallTimeout: 300, perToolTimeout: 60),
            taskStore: nil,
            workspaceId: UUID()
        )
        var events: [AgentEvent] = []
        for await event in await loop.run(taskId: UUID(), userRequest: request) {
            events.append(event)
        }
        return events
    }

    func testAgentFixesBugAndPushes() async throws {
        try await cloneIntoWorkspace()

        // Request 1: find and fix the failing test. Scripted tool sequence
        // mirrors what a competent small model should emit.
        let fixOutputs = [
            #"<tool_call>{"tool":"get_project_info","arguments":{}}</tool_call>"#,
            #"<tool_call>{"tool":"run_npm","arguments":{"args":["test"]}}</tool_call>"#,
            #"<tool_call>{"tool":"search_text","arguments":{"pattern":"sum"}}</tool_call>"#,
            #"<tool_call>{"tool":"read_file","arguments":{"path":"src/sum.js"}}</tool_call>"#,
            #"<tool_call>{"tool":"edit_file","arguments":{"path":"src/sum.js","old_string":"return a - b;","new_string":"return a + b;"}}</tool_call>"#,
            #"<tool_call>{"tool":"run_npm","arguments":{"args":["test"]}}</tool_call>"#,
            #"<tool_call>{"tool":"git_diff","arguments":{}}</tool_call>"#,
            "Fixed the bug in src/sum.js (subtraction -> addition). Tests pass."
        ]
        let fixEvents = await runRepoLoop(
            outputs: fixOutputs,
            request: "The tests are failing. Find the bug and fix it.",
            userAuthorizedPush: false
        )

        // Collect toolFinished events in order.
        let finishes: [(ok: Bool, summary: String, raw: String)] = fixEvents.compactMap { event in
            if case .toolFinished(_, let ok, let summary, let raw) = event { return (ok, summary, raw) }
            return nil
        }
        XCTAssertGreaterThanOrEqual(finishes.count, 7, "expected 7 tool calls, got \(finishes.count)")

        // First npm test must have failed and mentioned the failure.
        let firstTest = finishes[1]
        XCTAssertFalse(firstTest.ok, "first npm test should fail: \(firstTest.raw)")
        XCTAssertTrue(firstTest.raw.contains("FAIL"), "expected FAIL in output: \(firstTest.raw)")

        // Second npm test (after the edit) must pass.
        let secondTest = finishes[5]
        XCTAssertTrue(secondTest.ok, "second npm test should pass: \(secondTest.raw)")
        XCTAssertTrue(secondTest.raw.contains("all tests passed"), "expected pass output: \(secondTest.raw)")

        // Diff must be non-empty and mention the change.
        let diffResult = finishes[6]
        XCTAssertTrue(diffResult.ok)
        XCTAssertTrue(diffResult.raw.contains("return a + b"), "diff should show the fix: \(diffResult.raw)")

        guard case .finished = fixEvents.last else {
            XCTFail("expected loop to finish, got \(String(describing: fixEvents.last))")
            return
        }

        // Request 2: commit and push. Korean push intent must authorize.
        let commitOutputs = [
            #"<tool_call>{"tool":"git_add","arguments":{"paths":["src/sum.js"]}}</tool_call>"#,
            #"<tool_call>{"tool":"git_commit","arguments":{"message":"fix: repair sum"}}</tool_call>"#,
            #"<tool_call>{"tool":"git_push","arguments":{}}</tool_call>"#,
            "Committed and pushed fix: repair sum."
        ]
        let pushEvents = await runRepoLoop(
            outputs: commitOutputs,
            request: "fix: repair sum 으로 커밋하고 push해줘",
            userAuthorizedPush: PushIntentDetector.userAuthorizedPush(in: "fix: repair sum 으로 커밋하고 push해줘")
        )
        XCTAssertTrue(PushIntentDetector.userAuthorizedPush(in: "fix: repair sum 으로 커밋하고 push해줘"))

        let pushFinishes = pushEvents.compactMap { event -> (Bool, String)? in
            if case .toolFinished(_, let ok, _, let raw) = event { return (ok, raw) }
            return nil
        }
        XCTAssertEqual(pushFinishes.count, 3)
        XCTAssertTrue(pushFinishes.allSatisfy { $0.0 }, "all git ops should succeed: \(pushFinishes)")

        // The bare remote must now contain the commit message.
        let log = try shellOutput("git", ["log", "--format=%s", "-1"], at: remoteURL)
        XCTAssertEqual(log.trimmingCharacters(in: .whitespacesAndNewlines), "fix: repair sum",
                       "remote should have the pushed commit; log: \(log)")
    }

    func testAgentPushRefusedWithoutIntent() async throws {
        try await cloneIntoWorkspace()
        // Ask for a commit WITHOUT push intent; the scripted model still tries
        // to push — the policy layer must refuse.
        let outputs = [
            // Make a real change first so git_commit has something to commit.
            #"<tool_call>{"tool":"edit_file","arguments":{"path":"src/sum.js","old_string":"return a - b;","new_string":"return a + b;"}}</tool_call>"#,
            #"<tool_call>{"tool":"git_add","arguments":{"paths":["src/sum.js"]}}</tool_call>"#,
            #"<tool_call>{"tool":"git_commit","arguments":{"message":"wip"}}</tool_call>"#,
            #"<tool_call>{"tool":"git_push","arguments":{}}</tool_call>"#,
            "Pushed."
        ]
        let events = await runRepoLoop(
            outputs: outputs,
            request: "commit만 해줘",  // "just commit" — no push intent
            userAuthorizedPush: false
        )
        let finishes = events.compactMap { event -> (Bool, String)? in
            if case .toolFinished(_, let ok, _, let raw) = event { return (ok, raw) }
            return nil
        }
        XCTAssertEqual(finishes.count, 4)
        XCTAssertTrue(finishes[0].0)
        XCTAssertTrue(finishes[1].0)
        XCTAssertTrue(finishes[2].0)
        XCTAssertFalse(finishes[3].0, "push must be refused")
        XCTAssertTrue(finishes[3].1.contains("did not ask to push"),
                      "refusal should cite missing intent: \(finishes[3].1)")

        // Remote should still be at the seed commit.
        let log = try shellOutput("git", ["log", "--format=%s", "-1"], at: remoteURL)
        XCTAssertEqual(log.trimmingCharacters(in: .whitespacesAndNewlines), "initial")
    }

    private func shellOutput(_ cmd: String, _ args: [String], at dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/\(cmd)")
        p.arguments = args
        p.currentDirectoryURL = dir
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
#endif
