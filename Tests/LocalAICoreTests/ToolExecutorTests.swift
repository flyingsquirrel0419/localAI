import XCTest
@testable import LocalAICore

final class ToolExecutorTests: XCTestCase {
    var tempRoot: URL!
    var workspaceRoot: URL!
    var fileSystem: SandboxedFileSystem!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-exec-\(UUID().uuidString)", isDirectory: true)
        workspaceRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        fileSystem = try SandboxedFileSystem(rootURL: workspaceRoot)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    private func makeExecutor(
        userAuthorizedPush: Bool = false,
        confirm: (@Sendable (String) async -> Bool)? = nil
    ) -> ToolExecutor {
        ToolExecutor(context: ToolContext(
            fileSystem: fileSystem,
            search: RepositorySearch(fileSystem: fileSystem),
            git: nil, runtime: nil, credentialProvider: nil,
            repositoryDirectory: workspaceRoot,
            userAuthorizedPush: userAuthorizedPush,
            confirm: confirm
        ))
    }

    func testEditFileSearchReplace() async throws {
        try fileSystem.createFile("main.ts", contents: "const answer = 41;\n")
        let exec = makeExecutor()
        let result = await exec.execute(ToolCall(tool: "edit_file", arguments: [
            "path": "main.ts", "old_string": "41", "new_string": "42"
        ]))
        guard case .success(let output) = result else {
            XCTFail("expected success, got \(result)"); return
        }
        XCTAssertTrue(output.contains("Edited main.ts"))
        XCTAssertEqual(try fileSystem.read("main.ts"), "const answer = 42;\n")
    }

    func testEditFileAmbiguousOldString() async throws {
        try fileSystem.createFile("a.txt", contents: "foo foo")
        let exec = makeExecutor()
        let result = await exec.execute(ToolCall(tool: "edit_file", arguments: [
            "path": "a.txt", "old_string": "foo", "new_string": "bar"
        ]))
        guard case .failure = result else {
            XCTFail("expected failure, got \(result)"); return
        }
    }

    func testApplyPatch() async throws {
        try fileSystem.createFile("src/app.ts", contents: "line1\nline2\nline3\n")
        let exec = makeExecutor()
        let diff = """
        --- a/src/app.ts
        +++ b/src/app.ts
        @@ -1,3 +1,3 @@
         line1
        -line2
        +line2 modified
         line3
        """
        let result = await exec.execute(ToolCall(tool: "apply_patch", arguments: ["diff": diff]))
        guard case .success(let out) = result else {
            XCTFail("expected success, got \(result)"); return
        }
        XCTAssertTrue(out.contains("Patched 1 file"))
        XCTAssertEqual(try fileSystem.read("src/app.ts"), "line1\nline2 modified\nline3\n")
    }

    func testDeleteFileDirectoryNeedsConfirmation() async throws {
        try fileSystem.createFile("docs/readme.md", contents: "x")
        // confirm callback returns false
        let exec = makeExecutor(confirm: { _ in false })
        let result = await exec.execute(ToolCall(tool: "delete_file", arguments: ["path": "docs"]))
        guard case .failure(let message) = result else {
            XCTFail("expected failure when user declines, got \(result)"); return
        }
        XCTAssertTrue(message.contains("declined"))
        // Directory still exists.
        XCTAssertTrue(fileSystem.exists("docs"))
    }

    func testDeleteFileDirectoryConfirmed() async throws {
        try fileSystem.createFile("docs/readme.md", contents: "x")
        let exec = makeExecutor(confirm: { _ in true })
        let result = await exec.execute(ToolCall(tool: "delete_file", arguments: ["path": "docs"]))
        guard case .success = result else {
            XCTFail("expected success, got \(result)"); return
        }
        XCTAssertFalse(fileSystem.exists("docs"))
    }

    func testDeleteFileDirectoryNoCallback() async throws {
        try fileSystem.createFile("docs/readme.md", contents: "x")
        let exec = makeExecutor(confirm: nil)
        let result = await exec.execute(ToolCall(tool: "delete_file", arguments: ["path": "docs"]))
        guard case .needsConfirmation(let description, _) = result else {
            XCTFail("expected needsConfirmation, got \(result)"); return
        }
        XCTAssertTrue(description.contains("docs"))
    }

    func testSearchAndList() async throws {
        try fileSystem.createFile("src/router.ts", contents: "function handleRequest() {}")
        try fileSystem.createFile("README.md", contents: "no match here")
        let exec = makeExecutor()
        let result = await exec.execute(ToolCall(tool: "search_text", arguments: ["pattern": "handleRequest"]))
        guard case .success(let out) = result else {
            XCTFail("expected success, got \(result)"); return
        }
        XCTAssertTrue(out.contains("src/router.ts"))
        XCTAssertTrue(out.contains("handleRequest"))
    }

    func testProjectInfo() async throws {
        try fileSystem.createFile("package.json", contents: #"{"name":"demo","scripts":{"test":"node --test","build":"tsc"},"dependencies":{"react":"^18"}}"#)
        let exec = makeExecutor()
        let result = await exec.execute(ToolCall(tool: "get_project_info", arguments: [:]))
        guard case .success(let out) = result else {
            XCTFail("expected success, got \(result)"); return
        }
        XCTAssertTrue(out.contains("name: demo"))
        XCTAssertTrue(out.contains("test"))
        XCTAssertTrue(out.contains("react"))
        XCTAssertTrue(out.contains("package.json"))
    }

    func testReadFileLineRange() async throws {
        try fileSystem.createFile("lines.txt", contents: "a\nb\nc\nd\ne\n")
        let exec = makeExecutor()
        let result = await exec.execute(ToolCall(tool: "read_file", arguments: [
            "path": "lines.txt", "startLine": 2, "endLine": 3
        ]))
        guard case .success(let out) = result else {
            XCTFail("expected success, got \(result)"); return
        }
        XCTAssertTrue(out.contains("2: b"))
        XCTAssertTrue(out.contains("3: c"))
        XCTAssertFalse(out.contains("1: a"))
    }

    func testUnknownToolFails() async throws {
        let exec = makeExecutor()
        let result = await exec.execute(ToolCall(tool: "does_not_exist", arguments: [:]))
        guard case .failure(let message) = result else {
            XCTFail("expected failure, got \(result)"); return
        }
        XCTAssertTrue(message.contains("Unknown tool"))
    }

    func testSecretRedaction() async throws {
        // If a tool somehow outputs a token-shaped string, it's redacted.
        try fileSystem.createFile("leak.txt", contents: "token: ghp_abcdefghijklmnopqrstuvwxyz0123456789")
        let exec = makeExecutor()
        let result = await exec.execute(ToolCall(tool: "read_file", arguments: ["path": "leak.txt"]))
        guard case .success(let out) = result else {
            XCTFail("expected success, got \(result)"); return
        }
        XCTAssertTrue(out.contains("[REDACTED]"))
        XCTAssertFalse(out.contains("ghp_"))
    }

    // M2: cancellation
    func testCancellationReturnsCancelledFailure() async throws {
        let exec = makeExecutor()
        let task = Task {
            // Simulate a run that's already been cancelled before dispatch.
            withUnsafeCurrentTask { $0?.cancel() }
            return await exec.execute(ToolCall(tool: "list_directory", arguments: ["path": "."]))
        }
        let result = await task.value
        guard case .failure(let message) = result else {
            XCTFail("expected failure, got \(result)"); return
        }
        XCTAssertTrue(message.contains("Cancelled"))
    }

    // H4: run_node path confinement. runtime is nil here, but the path guard
    // fires BEFORE the runtime check would matter for a hostile path.
    func testRunNodeRejectsAbsoluteScriptPath() async throws {
        let exec = makeExecutor()
        // We can't actually run_node without a runtime, but the rejection
        // must happen before the runtime is consulted. Use a fake runtime.
        let runtime = FakeJSRuntime()
        let context = ToolContext(
            fileSystem: fileSystem,
            search: RepositorySearch(fileSystem: fileSystem),
            git: nil, runtime: runtime, credentialProvider: nil,
            repositoryDirectory: workspaceRoot,
            userAuthorizedPush: false, confirm: nil
        )
        let exec2 = ToolExecutor(context: context)
        let result = await exec2.execute(ToolCall(tool: "run_node", arguments: ["script": "/etc/passwd"]))
        guard case .failure(let message) = result else {
            XCTFail("expected failure, got \(result)"); return
        }
        XCTAssertTrue(message.contains("inside the workspace"), "got: \(message)")
    }

    func testRunNodeRejectsTraversalScriptPath() async throws {
        let runtime = FakeJSRuntime()
        let context = ToolContext(
            fileSystem: fileSystem,
            search: RepositorySearch(fileSystem: fileSystem),
            git: nil, runtime: runtime, credentialProvider: nil,
            repositoryDirectory: workspaceRoot,
            userAuthorizedPush: false, confirm: nil
        )
        let exec = ToolExecutor(context: context)
        let result = await exec.execute(ToolCall(tool: "run_node", arguments: ["script": "../outside.js"]))
        guard case .failure(let message) = result else {
            XCTFail("expected failure, got \(result)"); return
        }
        XCTAssertTrue(message.contains("inside the workspace"))
    }
}

/// Minimal JavaScriptRuntimeService used to satisfy the H4 path tests —
/// never actually invoked because the path guard short-circuits first.
private final class FakeJSRuntime: JavaScriptRuntimeService, @unchecked Sendable {
    func run(
        _ command: RuntimeCommand,
        in directory: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.exited(code: 0, duration: 0))
            continuation.finish()
        }
    }
}
