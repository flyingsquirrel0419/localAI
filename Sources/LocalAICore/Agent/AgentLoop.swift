import Foundation

public enum AgentEvent: Sendable, Equatable {
    case assistantDelta(String)
    case toolStarted(id: String, ToolActivity)
    case toolFinished(id: String, succeeded: Bool, summary: String, rawOutput: String)
    case needsConfirmation(description: String)
    case changedFiles(files: [String], added: Int, removed: Int)
    case finished(answer: String)
    case failed(UserFacingError)
    case cancelled
}

public struct AgentLimits: Sendable, Equatable {
    public var maxIterations: Int
    public var maxToolCalls: Int
    public var overallTimeout: TimeInterval
    public var perToolTimeout: TimeInterval

    public init(
        maxIterations: Int = 20,
        maxToolCalls: Int = 30,
        overallTimeout: TimeInterval = 600,
        perToolTimeout: TimeInterval = 120
    ) {
        self.maxIterations = maxIterations
        self.maxToolCalls = maxToolCalls
        self.overallTimeout = overallTimeout
        self.perToolTimeout = perToolTimeout
    }

    public static let `default` = AgentLimits()
}

/// Builds the system prompt for small (~4B) models: short, imperative, with
/// the exact tool-call format spelled out and one worked example. Kept under
/// ~1500 tokens (≈6000 chars) so it fits small context windows.
public enum AgentSystemPrompt {
    public static func build(projectInfo: String? = nil) -> String {
        var lines: [String] = [
            "You are a coding agent working inside a git repository.",
            "Call ONE tool per turn, exactly:",
            "<tool_call>{\"tool\":\"NAME\",\"arguments\":{...}}</tool_call>",
            "Example: <tool_call>{\"tool\":\"read_file\",\"arguments\":{\"path\":\"src/sum.js\"}}</tool_call>",
            "When the task is done, reply in plain text with NO tool call.",
            "Never invent tools or arguments. On failure, read the error and adjust.",
            "Tools:"
        ]
        for tool in AgentTools.all {
            lines.append(tool.promptDescription())
        }
        if let projectInfo, !projectInfo.isEmpty {
            lines.append("Project info:")
            lines.append(projectInfo)
        }
        return lines.joined(separator: "\n")
    }
}

/// The agent run loop. Streams AgentEvent; `stop()` cancels generation and any
/// running tool promptly. State checkpoints are saved after every tool result.
public actor AgentLoop {
    public enum State: Sendable, Equatable {
        case idle, running, stopped
    }

    private let engine: LocalModelEngine
    private let executor: ToolExecutor
    private let contextWindow: ContextWindowManager
    private let limits: AgentLimits
    private let taskStore: AgentTaskStore?
    private let workspaceId: UUID

    private var runTask: Task<Void, Never>?
    private var currentToolTask: Task<ToolExecutionResult, Never>?
    private(set) public var state: State = .idle

    public init(
        engine: LocalModelEngine,
        executor: ToolExecutor,
        contextWindow: ContextWindowManager,
        limits: AgentLimits = .default,
        taskStore: AgentTaskStore? = nil,
        workspaceId: UUID = UUID()
    ) {
        self.engine = engine
        self.executor = executor
        self.contextWindow = contextWindow
        self.limits = limits
        self.taskStore = taskStore
        self.workspaceId = workspaceId
    }

    /// Start a new task; emits events into the returned stream.
    /// Refuses to start a new run while one is still active; the caller must
    /// `await` the existing run's stream finishing (or call `stop()`) first.
    public func run(taskId: UUID, userRequest: String) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                let granted = await self.tryStartRun()
                guard granted else {
                    continuation.yield(.failed(UserFacingError(
                        title: "Agent is busy",
                        message: "Wait for the current run to finish or stop it first.",
                        recoveryAction: .dismiss,
                        developerDetails: "concurrent run() refused"
                    )))
                    continuation.finish()
                    return
                }
                let task = Task { [weak self] in
                    guard let self else { continuation.finish(); return }
                    await self.execute(
                        taskId: taskId,
                        userRequest: userRequest,
                        checkpoint: nil,
                        continuation: continuation
                    )
                }
                await self.track(task)
            }
        }
    }

    /// Resume a task from a saved checkpoint.
    public func resume(taskId: UUID) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self, let store = self.taskStore else {
                    continuation.finish(); return
                }
                let granted = await self.tryStartRun()
                guard granted else {
                    continuation.yield(.failed(UserFacingError(
                        title: "Agent is busy",
                        message: "Wait for the current run to finish or stop it first.",
                        recoveryAction: .dismiss,
                        developerDetails: "concurrent resume() refused"
                    )))
                    continuation.finish()
                    return
                }
                do {
                    let checkpoint = try await store.load(taskId: taskId)
                    let task = Task { [weak self] in
                        guard let self else { continuation.finish(); return }
                        await self.execute(
                            taskId: taskId,
                            userRequest: checkpoint.userRequest,
                            checkpoint: checkpoint,
                            continuation: continuation
                        )
                    }
                    await self.track(task)
                } catch {
                    continuation.yield(.failed(UserFacingErrorMapper.map(error)))
                    continuation.finish()
                }
            }
        }
    }

    /// Atomically claim the run slot. Returns false when a run is already in
    /// flight. The state machine lives behind the actor, so this can't race.
    private func tryStartRun() -> Bool {
        guard state == .idle else { return false }
        state = .running
        return true
    }

    private func track(_ task: Task<Void, Never>) {
        runTask = task
    }

    /// Cancel the run and any in-flight tool call.
    public func stop() {
        runTask?.cancel()
        currentToolTask?.cancel()
        // Don't clobber a finished state; only mark stopped when actually running.
        if state == .running {
            state = .stopped
        }
    }

    // MARK: - Run

    private func execute(
        taskId: UUID,
        userRequest: String,
        checkpoint: AgentCheckpoint?,
        continuation: AsyncStream<AgentEvent>.Continuation
    ) async {
        // State was claimed by tryStartRun(); do not re-assign .running here.
        defer {
            // Don't overwrite .stopped → .idle; the next run claims via
            // tryStartRun regardless, but keeping .stopped visible lets the
            // UI distinguish "stopped by user" from "never ran".
            if state == .running { state = .idle }
            continuation.finish()
        }

        let userAuthorizedPush = PushIntentDetector.userAuthorizedPush(in: userRequest)
        // Replace the executor's context push authorization for this request.
        let executor = ToolExecutor(
            context: ToolContext(
                fileSystem: self.executor.context.fileSystem,
                search: self.executor.context.search,
                git: self.executor.context.git,
                runtime: self.executor.context.runtime,
                credentialProvider: self.executor.context.credentialProvider,
                repositoryDirectory: self.executor.context.repositoryDirectory,
                userAuthorizedPush: userAuthorizedPush,
                confirm: self.executor.context.confirm
            )
        )

        let projectInfo = await Self.fetchProjectInfo(executor: executor)
        let systemPrompt = AgentSystemPrompt.build(projectInfo: projectInfo)

        var messages: [ChatMessage] = checkpoint?.messages ?? [
            ChatMessage(role: .system, content: systemPrompt),
            ChatMessage(role: .user, content: userRequest)
        ]
        var checkpointState = checkpoint ?? AgentCheckpoint(
            taskId: taskId, workspaceId: workspaceId, userRequest: userRequest,
            state: .running, messages: messages
        )
        checkpointState.state = .running
        try? await taskStore?.save(checkpointState)

        var toolCallCount = 0
        let deadline = Date().addingTimeInterval(limits.overallTimeout)

        for iteration in 0..<limits.maxIterations {
            if Task.isCancelled {
                continuation.yield(.cancelled)
                if state != .stopped {
                    checkpointState.state = .interrupted
                    try? await taskStore?.save(checkpointState)
                }
                return
            }
            if Date() > deadline {
                continuation.yield(.failed(UserFacingError(
                    title: "Task timed out",
                    message: "The agent ran longer than \(Int(limits.overallTimeout)) seconds.",
                    recoveryAction: .retry,
                    developerDetails: "overallTimeout \(limits.overallTimeout)s"
                )))
                checkpointState.state = .failed
                try? await taskStore?.save(checkpointState)
                return
            }

            checkpointState.currentStep = iteration

            // Generate.
            let trimmed = contextWindow.trim(messages)
            var assistantText = ""
            var generationFailed: UserFacingError?
            let params = GenerationParameters(
                temperature: 0.2, topP: 0.9, maxTokens: 1024,
                stopSequences: ["</tool_call>"]
            )
            let stream = engine.generate(messages: trimmed, parameters: params)
            // Track think-block state across deltas. We never surface <think>
            // content in the UI, never save it to history, and never feed it
            // to the tool parser. Loop-level stop enforcement runs through
            // StopSequenceFilter so a misbehaving engine still gets cut off —
            // the filter guarantees everything up to and including the first
            // stop string is emitted exactly once, with no drop/duplicate.
            var inThinkBlock = false
            var thinkBuffer = ""
            var stopFilter = StopSequenceFilter(stopSequences: params.stopSequences)
            do {
                for try await delta in stream {
                    if Task.isCancelled { break }
                    let split = Self.splitThink(delta, inThink: inThinkBlock, buffer: &thinkBuffer)
                    inThinkBlock = split.nowInThink
                    let visibleChunk = split.visible
                    if visibleChunk.isEmpty { continue }
                    let r = stopFilter.feed(visibleChunk)
                    if !r.emit.isEmpty {
                        assistantText += r.emit
                        let stripped = Self.visibleDelta(r.emit)
                        if !stripped.isEmpty {
                            continuation.yield(.assistantDelta(stripped))
                        }
                    }
                    if r.stopped { break }
                }
                // Flush any held tail only if the stream ended without a stop
                // and without cancellation.
                if !Task.isCancelled {
                    let tail = stopFilter.finish()
                    if !tail.isEmpty {
                        assistantText += tail
                        let stripped = Self.visibleDelta(tail)
                        if !stripped.isEmpty {
                            continuation.yield(.assistantDelta(stripped))
                        }
                    }
                }
            } catch {
                generationFailed = UserFacingErrorMapper.map(error)
            }
            if let failure = generationFailed {
                continuation.yield(.failed(failure))
                checkpointState.state = .failed
                try? await taskStore?.save(checkpointState)
                return
            }
            if Task.isCancelled {
                continuation.yield(.cancelled)
                // Save .interrupted so resume works; never overwrite with a
                // later "completed" save once the user stopped the run.
                if state != .stopped {
                    checkpointState.state = .interrupted
                    try? await taskStore?.save(checkpointState)
                }
                return
            }
            // Strip think blocks from the recorded assistant message: think
            // text isn't part of the model's tool-use contract and only
            // pollutes the context window on subsequent turns.
            let cleanedAssistant = Self.stripThinkBlocks(assistantText)
            messages.append(ChatMessage(role: .assistant, content: cleanedAssistant))

            switch ToolCallParser.parse(cleanedAssistant) {
            case .finalAnswer(let answer):
                let changed = await executor.changedFiles
                if !changed.isEmpty {
                    continuation.yield(.changedFiles(files: Array(changed).sorted(), added: 0, removed: 0))
                }
                continuation.yield(.finished(answer: answer))
                checkpointState.state = .completed
                checkpointState.messages = messages
                checkpointState.modifiedFiles = Array(changed).sorted()
                try? await taskStore?.save(checkpointState)
                return

            case .parseError(let message, _):
                messages.append(ChatMessage(role: .tool, content: "PARSE ERROR: \(message)"))
                checkpointState.messages = messages
                try? await taskStore?.save(checkpointState)
                continue

            case .toolCall(let call, _):
                toolCallCount += 1
                if toolCallCount > limits.maxToolCalls {
                    continuation.yield(.failed(UserFacingError(
                        title: "Too many tool calls",
                        message: "The agent exceeded the tool-call limit (\(limits.maxToolCalls)).",
                        recoveryAction: .dismiss,
                        developerDetails: "maxToolCalls \(limits.maxToolCalls)"
                    )))
                    checkpointState.state = .failed
                    try? await taskStore?.save(checkpointState)
                    return
                }

                let activity = await executor.activity(for: call)
                continuation.yield(.toolStarted(id: call.id, activity))

                let toolTask = Task { await executor.execute(call) }
                currentToolTask = toolTask
                let result = await toolTask.value
                currentToolTask = nil

                switch result {
                case .needsConfirmation(let description, _):
                    continuation.yield(.needsConfirmation(description: description))
                    // Confirmation was already asked inside executor via callback;
                    // reaching here without callback means refusal.
                    let feedback = "TOOL REFUSED (needs user confirmation): \(description)"
                    messages.append(ChatMessage(role: .tool, content: feedback))
                    continuation.yield(.toolFinished(id: call.id, succeeded: false, summary: "Needs confirmation", rawOutput: feedback))
                    checkpointState.messages = messages
                    try? await taskStore?.save(checkpointState)

                case .success(let output):
                    let summary = Self.summarize(output)
                    continuation.yield(.toolFinished(id: call.id, succeeded: true, summary: summary, rawOutput: output))
                    messages.append(ChatMessage(role: .tool, content: "TOOL \(call.tool) OK:\n\(output)"))
                    checkpointState.messages = messages
                    checkpointState.toolHistory.append(Self.record(call: call, result: output, succeeded: true))
                    checkpointState.modifiedFiles = Array(await executor.changedFiles).sorted()
                    try? await taskStore?.save(checkpointState)

                case .failure(let message):
                    let summary = Self.summarize(message)
                    continuation.yield(.toolFinished(id: call.id, succeeded: false, summary: summary, rawOutput: message))
                    messages.append(ChatMessage(role: .tool, content: "TOOL \(call.tool) FAILED:\n\(message)"))
                    checkpointState.messages = messages
                    checkpointState.toolHistory.append(Self.record(call: call, result: message, succeeded: false))
                    try? await taskStore?.save(checkpointState)
                }
            }
        }

        continuation.yield(.failed(UserFacingError(
            title: "Iteration limit reached",
            message: "The agent didn't finish within \(limits.maxIterations) iterations.",
            recoveryAction: .retry,
            developerDetails: "maxIterations \(limits.maxIterations)"
        )))
        checkpointState.state = .failed
        checkpointState.messages = messages
        try? await taskStore?.save(checkpointState)
    }

    // MARK: - Helpers

    /// Strip raw tool-call markup from deltas shown to the UI.
    static func visibleDelta(_ delta: String) -> String {
        // Only emit text before a <tool_call> opener.
        if let range = delta.range(of: "<tool_call>") {
            return String(delta[..<range.lowerBound])
        }
        return delta
    }

    /// Split a delta into "visible" text (outside <think>...</think>) versus
    /// think-block content. Streams may split `<think>` across deltas; we keep
    /// the unmatched tail in `buffer` until we can decide. An unclosed
    /// `<think>` swallows the rest of the stream.
    static func splitThink(
        _ delta: String,
        inThink: Bool,
        buffer: inout String
    ) -> (visible: String, nowInThink: Bool) {
        buffer += delta
        var visible = ""
        var inT = inThink
        var s = buffer
        buffer = ""
        while !s.isEmpty {
            if inT {
                if let close = s.range(of: "</think>") {
                    s = String(s[close.upperBound...])
                    inT = false
                } else {
                    // All inside think; drop everything (don't even buffer).
                    return (visible, true)
                }
            } else {
                if let open = s.range(of: "<think>") {
                    visible += s[s.startIndex..<open.lowerBound]
                    s = String(s[open.upperBound...])
                    inT = true
                } else {
                    // No complete tag — but a partial "<thi..." at the end
                    // could still be the start of "<think>". Keep up to 6
                    // trailing chars buffered when they look like a tag prefix.
                    let tail = Self.partialTagTail(of: s, tag: "<think>")
                    if !tail.isEmpty, s.hasSuffix(tail) {
                        let endIndex = s.index(s.endIndex, offsetBy: -tail.count)
                        visible += s[s.startIndex..<endIndex]
                        buffer = tail
                    } else {
                        visible += s
                    }
                    return (visible, false)
                }
            }
        }
        return (visible, inT)
    }

    /// The longest suffix of `text` that is also a prefix of `tag`. Empty when
    /// no such suffix exists. Used to defer emitting text that might be the
    /// start of a "<think>" / "</think>" tag split across deltas.
    private static func partialTagTail(of text: String, tag: String) -> String {
        let tagChars = Array(tag)
        let textChars = Array(text)
        let max = min(textChars.count, tagChars.count - 1)
        if max <= 0 { return "" }
        for length in stride(from: max, through: 1, by: -1) {
            let tail = textChars[(textChars.count - length)...]
            let prefix = tagChars[..<length]
            if Array(tail) == Array(prefix) {
                return String(tail)
            }
        }
        return ""
    }

    /// Remove all complete and trailing-unclosed <think>...</think> spans from
    /// `text`. Used to clean assistant text before parsing and storing.
    static func stripThinkBlocks(_ text: String) -> String {
        var out = ""
        var s = text
        while let open = s.range(of: "<think>") {
            out += s[s.startIndex..<open.lowerBound]
            let after = s[open.upperBound...]
            if let close = after.range(of: "</think>") {
                s = String(after[close.upperBound...])
            } else {
                // Unclosed think block swallows the remainder.
                return out
            }
        }
        out += s
        return out
    }

    private static func summarize(_ output: String) -> String {
        for line in output.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasSuffix("tests passed") || s.hasSuffix("tests failed")
                || s.hasPrefix("✓") || s.hasPrefix("exit ") {
                return s
            }
        }
        let first = output.split(separator: "\n").first.map(String.init) ?? ""
        return first.count > 120 ? String(first.prefix(120)) + "…" : first
    }

    private static func record(call: ToolCall, result: String, succeeded: Bool) -> ToolHistoryEntry {
        let argsData = (try? JSONSerialization.data(withJSONObject: call.arguments)) ?? Data()
        let argsString = String(data: argsData, encoding: .utf8) ?? "{}"
        let truncated = result.count > 500 ? String(result.prefix(500)) + "…" : result
        return ToolHistoryEntry(
            call: .init(tool: call.tool, argumentsJSON: argsString),
            resultSummary: truncated,
            succeeded: succeeded
        )
    }

    private static func fetchProjectInfo(executor: ToolExecutor) async -> String? {
        let result = await executor.execute(ToolCall(tool: "get_project_info", arguments: [:]))
        if case .success(let output) = result { return output }
        return nil
    }
}
