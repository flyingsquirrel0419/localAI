import XCTest
@testable import LocalAICore

/// Canned-output engine used for AgentLoop tests.
final class ScriptedEngine: LocalModelEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String]
    private(set) var calls: Int = 0

    init(outputs: [String]) { self.outputs = outputs }

    func load(modelDirectory: URL) async throws {}
    func unload() async {}
    var isLoaded: Bool { true }

    func generate(
        messages: [ChatMessage],
        parameters: GenerationParameters
    ) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        calls += 1
        let next = outputs.isEmpty ? "" : outputs.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(next)
            continuation.finish()
        }
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}

final class AgentLoopTests: XCTestCase {
    var tempRoot: URL!
    var workspaceRoot: URL!
    var fileSystem: SandboxedFileSystem!
    var taskStoreRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-loop-\(UUID().uuidString)", isDirectory: true)
        workspaceRoot = tempRoot.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        fileSystem = try SandboxedFileSystem(rootURL: workspaceRoot)
        taskStoreRoot = tempRoot.appendingPathComponent("store", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    private func makeContext(userAuthorizedPush: Bool = false) -> ToolContext {
        ToolContext(
            fileSystem: fileSystem,
            search: RepositorySearch(fileSystem: fileSystem),
            git: nil,
            runtime: nil,
            credentialProvider: nil,
            repositoryDirectory: workspaceRoot,
            userAuthorizedPush: userAuthorizedPush,
            confirm: { _ in false }
        )
    }

    private func makeLoop(
        outputs: [String],
        limits: AgentLimits = AgentLimits(maxIterations: 10, maxToolCalls: 20, overallTimeout: 60, perToolTimeout: 10),
        taskStore: AgentTaskStore? = nil,
        context: ToolContext? = nil
    ) -> AgentLoop {
        AgentLoop(
            engine: ScriptedEngine(outputs: outputs),
            executor: ToolExecutor(context: context ?? makeContext()),
            contextWindow: ContextWindowManager(tokenBudget: 8192),
            limits: limits,
            taskStore: taskStore,
            workspaceId: UUID()
        )
    }

    private func collectEvents(_ stream: AsyncStream<AgentEvent>) async -> [AgentEvent] {
        var events: [AgentEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    func testReadThenFinalAnswer() async throws {
        try fileSystem.createFile("hello.txt", contents: "world")

        let outputs = [
            #"<tool_call>{"tool":"read_file","arguments":{"path":"hello.txt"}}</tool_call>"#,
            "The file says: world."
        ]
        let loop = makeLoop(outputs: outputs)
        let events = await collectEvents(loop.run(taskId: UUID(), userRequest: "What is in hello.txt?"))

        let startedTools = events.compactMap { event -> String? in
            if case .toolStarted(_, let activity) = event { return activity.title }
            return nil
        }
        XCTAssertEqual(startedTools, ["Reading hello.txt"])

        let finished = events.compactMap { event -> (Bool, String)? in
            if case .toolFinished(_, let ok, let summary, _) = event { return (ok, summary) }
            return nil
        }
        XCTAssertEqual(finished.count, 1)
        XCTAssertTrue(finished[0].0)

        guard case .finished(let answer) = events.last else {
            XCTFail("expected .finished, got \(String(describing: events.last))"); return
        }
        XCTAssertEqual(answer, "The file says: world.")
    }

    func testEditFileUpdatesWorkspace() async throws {
        try fileSystem.createFile("a.txt", contents: "hello old world")

        let outputs = [
            #"<tool_call>{"tool":"edit_file","arguments":{"path":"a.txt","old_string":"old","new_string":"new"}}</tool_call>"#,
            "done"
        ]
        let loop = makeLoop(outputs: outputs)
        let events = await collectEvents(loop.run(taskId: UUID(), userRequest: "replace old with new"))

        let finalText = try fileSystem.read("a.txt")
        XCTAssertEqual(finalText, "hello new world")

        XCTAssertTrue(events.contains { event in
            if case .changedFiles(let files, _, _) = event { return files.contains("a.txt") }
            return false
        })
    }

    func testParseErrorRecovery() async throws {
        try fileSystem.createFile("a.txt", contents: "x")
        let outputs = [
            "<tool_call>{not json}</tool_call>",
            #"<tool_call>{"tool":"read_file","arguments":{"path":"a.txt"}}</tool_call>"#,
            "ok"
        ]
        let loop = makeLoop(outputs: outputs)
        let events = await collectEvents(loop.run(taskId: UUID(), userRequest: "read a.txt"))

        let finishes = events.filter { if case .toolFinished = $0 { return true }; return false }
        XCTAssertEqual(finishes.count, 1)
        guard case .finished = events.last else {
            XCTFail("expected .finished"); return
        }
    }

    func testMaxIterationsStops() async throws {
        // Engine always returns a tool call, never a final answer.
        let outputs = Array(repeating: #"<tool_call>{"tool":"list_directory","arguments":{"path":"."}}</tool_call>"#, count: 50)
        let loop = makeLoop(
            outputs: outputs,
            limits: AgentLimits(maxIterations: 3, maxToolCalls: 50, overallTimeout: 60, perToolTimeout: 5)
        )
        let events = await collectEvents(loop.run(taskId: UUID(), userRequest: "loop forever"))
        guard case .failed(let error) = events.last else {
            XCTFail("expected .failed, got \(String(describing: events.last))"); return
        }
        XCTAssertEqual(error.title, "Iteration limit reached")
    }

    func testPushBlockedWithoutIntent() async throws {
        let outputs = [
            #"<tool_call>{"tool":"git_push","arguments":{}}</tool_call>"#,
            "I cannot push without permission."
        ]
        let loop = makeLoop(outputs: outputs)
        let events = await collectEvents(loop.run(taskId: UUID(), userRequest: "just look around"))

        let finishEvents = events.compactMap { event -> (Bool, String)? in
            if case .toolFinished(_, let ok, _, let raw) = event { return (ok, raw) }
            return nil
        }
        XCTAssertEqual(finishEvents.count, 1)
        XCTAssertFalse(finishEvents[0].0)
        XCTAssertTrue(finishEvents[0].1.contains("did not ask to push"))
    }

    func testPushAllowedWithKoreanIntent() async throws {
        XCTAssertTrue(PushIntentDetector.userAuthorizedPush(in: "커밋하고 push해줘"))
        XCTAssertTrue(PushIntentDetector.userAuthorizedPush(in: "이거 GitHub에 올려줘"))
        XCTAssertTrue(PushIntentDetector.userAuthorizedPush(in: "원격에 올려"))
        XCTAssertTrue(PushIntentDetector.userAuthorizedPush(in: "please push this"))
        XCTAssertFalse(PushIntentDetector.userAuthorizedPush(in: "commit만 해줘"))
        XCTAssertFalse(PushIntentDetector.userAuthorizedPush(in: "read the file"))
    }

    func testPushNegationsDoNotAuthorize() {
        // English negations.
        XCTAssertFalse(PushIntentDetector.userAuthorizedPush(in: "commit but don't push"))
        XCTAssertFalse(PushIntentDetector.userAuthorizedPush(in: "do not push this"))
        XCTAssertFalse(PushIntentDetector.userAuthorizedPush(in: "commit without pushing"))
        XCTAssertFalse(PushIntentDetector.userAuthorizedPush(in: "never push to origin"))
        // Korean negations.
        XCTAssertFalse(PushIntentDetector.userAuthorizedPush(in: "push하지 마"))
        XCTAssertFalse(PushIntentDetector.userAuthorizedPush(in: "푸시하지 말고 커밋만"))
        XCTAssertFalse(PushIntentDetector.userAuthorizedPush(in: "푸시 없이 커밋해줘"))
        XCTAssertFalse(PushIntentDetector.userAuthorizedPush(in: "올리지 마"))
        XCTAssertFalse(PushIntentDetector.userAuthorizedPush(in: "GitHub에 올리지 말고"))
        // Mixed-case Latin inside Korean must still match.
        XCTAssertTrue(PushIntentDetector.userAuthorizedPush(in: "GitHub에 올려"))
        XCTAssertTrue(PushIntentDetector.userAuthorizedPush(in: "GITHUB에 올려줘"))
        XCTAssertTrue(PushIntentDetector.userAuthorizedPush(in: "github에 올려"))
        // Conservative: any "하지 말고"/"없이" anywhere vetoes, even when the
        // negation targets something else — better to refuse a real push than
        // to push without consent.
        XCTAssertFalse(PushIntentDetector.userAuthorizedPush(in: "테스트는 하지 말고 push해줘"))
    }

    func testCheckpointSaveResume() async throws {
        try fileSystem.createFile("hello.txt", contents: "checkpoint me")
        let store = AgentTaskStore(rootURL: taskStoreRoot)

        let taskId = UUID()
        let outputs = [
            #"<tool_call>{"tool":"read_file","arguments":{"path":"hello.txt"}}</tool_call>"#,
            "checkpoint answer"
        ]
        let loop = makeLoop(outputs: outputs, taskStore: store)
        let events = await collectEvents(loop.run(taskId: taskId, userRequest: "read hello.txt"))
        guard case .finished = events.last else {
            XCTFail("expected finish"); return
        }

        let saved = try await store.load(taskId: taskId)
        XCTAssertEqual(saved.state, .completed)
        XCTAssertEqual(saved.userRequest, "read hello.txt")
        XCTAssertEqual(saved.toolHistory.count, 1)
        XCTAssertEqual(saved.toolHistory.first?.call.tool, "read_file")
        XCTAssertTrue(saved.toolHistory.first?.succeeded ?? false)
        XCTAssertFalse(saved.messages.isEmpty)
    }

    func testInterruptedOnLaunch() async throws {
        let store = AgentTaskStore(rootURL: taskStoreRoot)
        var checkpoint = AgentCheckpoint(
            taskId: UUID(), workspaceId: UUID(), userRequest: "x",
            state: .running
        )
        try await store.save(checkpoint)
        let marked = try await store.markInterruptedOnLaunch()
        XCTAssertEqual(marked, 1)
        let reloaded = try await store.load(taskId: checkpoint.taskId)
        XCTAssertEqual(reloaded.state, .interrupted)
        checkpoint.state = .interrupted
    }

    func testCancellation() async throws {
        // Engine that streams many chunks, giving stop() a chance to fire.
        final class SlowEngine: LocalModelEngine, @unchecked Sendable {
            func load(modelDirectory: URL) async throws {}
            func unload() async {}
            var isLoaded: Bool { true }
            func generate(
                messages: [ChatMessage],
                parameters: GenerationParameters
            ) -> AsyncThrowingStream<String, Error> {
                AsyncThrowingStream { continuation in
                    let task = Task {
                        for _ in 0..<1000 {
                            if Task.isCancelled { break }
                            continuation.yield("chunk ")
                            try? await Task.sleep(nanoseconds: 5_000_000)
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        }

        let loop = AgentLoop(
            engine: SlowEngine(),
            executor: ToolExecutor(context: makeContext()),
            contextWindow: ContextWindowManager(tokenBudget: 8192),
            limits: AgentLimits(maxIterations: 5, maxToolCalls: 5, overallTimeout: 30, perToolTimeout: 5),
            taskStore: nil,
            workspaceId: UUID()
        )
        let stream = await loop.run(taskId: UUID(), userRequest: "long")
        var sawCancelled = false
        var iterator = stream.makeAsyncIterator()

        // Wait until first deltas arrive, then stop.
        let first = await iterator.next()
        XCTAssertNotNil(first)
        await loop.stop()

        while let event = await iterator.next() {
            if case .cancelled = event { sawCancelled = true; break }
            if case .finished = event { break }
            if case .failed = event { break }
        }
        XCTAssertTrue(sawCancelled, "expected .cancelled event")
    }

    func testOutputTruncation() async throws {
        // read_file returns full file; ensure ToolExecutor truncates at maxOutputChars.
        let big = String(repeating: "x", count: ToolPolicy.maxOutputChars + 5000)
        try fileSystem.createFile("big.txt", contents: big)

        let outputs = [
            #"<tool_call>{"tool":"read_file","arguments":{"path":"big.txt"}}</tool_call>"#,
            "done"
        ]
        let loop = makeLoop(outputs: outputs)
        let events = await collectEvents(loop.run(taskId: UUID(), userRequest: "read big"))
        let toolFinished = events.compactMap { event -> String? in
            if case .toolFinished(_, true, _, let raw) = event { return raw }
            return nil
        }
        XCTAssertEqual(toolFinished.count, 1)
        XCTAssertTrue(toolFinished[0].contains("[truncated"))
        XCTAssertLessThanOrEqual(toolFinished[0].count, ToolPolicy.maxOutputChars + 200)
    }
}
