import Foundation
import LocalAICore
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
// Required by the `#huggingFaceTokenizerLoader()` macro: its expansion
// references `Tokenizers.AutoTokenizer` and `Tokenizers.Tokenizer` directly.
import Tokenizers
#if canImport(UIKit)
import UIKit
#endif

/// LocalAICore `LocalModelEngine` implementation backed by mlx-swift-lm.
///
/// - Loads a model from a previously-downloaded local directory (the one
///   `ModelDownloader` produced).
/// - Streams token deltas via `ModelContainer.generate` over a `UserInput`
///   built from the full chronological conversation.
/// - Cancellation is delivered through Swift's `Task.cancel()` on the consumer's
///   `for try await` loop; we additionally keep an explicit `cancel()` that
///   interrupts in-flight generation on memory pressure.
/// - On memory warnings we cancel generation and drop the MLX buffer cache.
public actor MLXEngine: LocalModelEngine {

    public enum State: Sendable, Equatable {
        case unloaded
        case loading
        case loaded(modelDirectory: URL)
        case failed(String)
    }

    private var state: State = .unloaded
    private var container: ModelContainer?
    private var memoryObserver: NSObjectProtocol?

    /// Continuation notified on memory warnings so a streaming `generate` call
    /// can finish early.
    private var activeContinuation: AsyncThrowingStream<String, Error>.Continuation?

    public init() {
        // Cap the MLX cache so back-to-back generations don't pin Metal buffers.
        MLX.Memory.cacheLimit = 20 * 1024 * 1024 // 20 MB, per running-on-ios.md
        installMemoryWarningObserver()
    }

    deinit {
        if let observer = memoryObserver {
            #if canImport(UIKit)
            NotificationCenter.default.removeObserver(observer)
            #endif
        }
    }

    public var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    public var currentState: State { state }

    // MARK: - LocalModelEngine

    public func load(modelDirectory: URL) async throws {
        if case .loaded(let dir) = state, dir == modelDirectory {
            return
        }
        if case .loaded = state {
            await unload()
        }
        state = .loading
        do {
            let container = try await loadModelContainer(
                from: modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
            self.container = container
            state = .loaded(modelDirectory: modelDirectory)
        } catch {
            state = .failed(SecretRedactor.redact(String(describing: error)))
            throw ModelEngineError.loadFailed(
                SecretRedactor.redact(String(describing: error))
            )
        }
    }

    public func unload() async {
        container = nil
        state = .unloaded
        MLX.Memory.clearCache()
    }

    /// Protocol requirement is nonisolated; we bounce into the actor to set
    /// up state, then run the actual generation in a Task.
    public nonisolated func generate(
        messages: [ChatMessage],
        parameters: GenerationParameters
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.setActiveContinuation(continuation)
                await self.runGeneration(
                    messages: messages,
                    parameters: parameters,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.clearActiveContinuation() }
            }
        }
    }

    private func setActiveContinuation(
        _ continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        self.activeContinuation = continuation
    }

    private func clearActiveContinuation() {
        self.activeContinuation = nil
    }

    // MARK: - Internals

    private func runGeneration(
        messages: [ChatMessage],
        parameters: GenerationParameters,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        guard let container = self.container else {
            continuation.finish(throwing: ModelEngineError.notLoaded)
            return
        }

        // Build GenerateParameters from the core type.
        var params = GenerateParameters()
        params.temperature = Float(parameters.temperature)
        params.topP = Float(parameters.topP)
        params.maxTokens = parameters.maxTokens

        // Build the full conversation as a single [Chat.Message] in the order
        // received. `UserInput(chat:)` applies the model's chat template to the
        // entire list, preserving chronological order (the prior implementation
        // reshuffled the original task into history and streamed against only
        // the last user message, derailing the agent loop after iteration 1).
        //
        // Role mapping: our `tool` role becomes MLX's `.tool` so chat templates
        // that support tool results render them in the right slot. Templates
        // without tool support degrade gracefully (the message text is still
        // included).
        var chatMessages: [Chat.Message] = []
        chatMessages.reserveCapacity(messages.count)
        for message in messages {
            switch message.role {
            case .system:
                chatMessages.append(Chat.Message(role: .system, content: message.content))
            case .user:
                chatMessages.append(Chat.Message(role: .user, content: message.content))
            case .assistant:
                chatMessages.append(Chat.Message(role: .assistant, content: message.content))
            case .tool:
                chatMessages.append(Chat.Message(role: .tool, content: message.content))
            }
        }
        guard !chatMessages.isEmpty else {
            continuation.finish(throwing: ModelEngineError.notLoaded)
            return
        }

        // Stop sequences: per-request stops aren't a `GenerateParameters` knob
        // (they live on ModelConfiguration). Enforce them here: accumulate text,
        // halt when any stop string appears, and truncate at (but include) the
        // stop marker so the parser downstream sees a complete <tool_call>.
        let stopSequences = parameters.stopSequences.filter { !$0.isEmpty }

        do {
            let input = try await container.prepare(input: UserInput(chat: chatMessages))
            let stream = try await container.generate(input: input, parameters: params)
            var accumulated = ""
            var hitStop = false
            var pendingTail = ""
            for await generation in stream {
                try Task.checkCancellation()
                if hitStop { break }
                guard case .chunk(let text) = generation else { continue }
                if stopSequences.isEmpty {
                    continuation.yield(text)
                    continue
                }
                // Append to a small buffer; only emit the prefix that cannot
                // contain the start of a stop string. This avoids leaking the
                // first half of "</tool_call>" if the chunk boundary splits it.
                pendingTail += text
                if let emit = Self.drainablePrefix(of: &pendingTail, stops: stopSequences) {
                    accumulated += emit
                    if let stopHit = Self.firstStop(in: accumulated, stops: stopSequences) {
                        // finalText is accumulated truncated just past the stop marker.
                        let finalCount = stopHit.lowerBoundOffset + stopHit.length
                        let alreadyStreamed = accumulated.count - pendingTail.count
                        if finalCount > alreadyStreamed {
                            let emitTail = String(accumulated.dropFirst(alreadyStreamed).prefix(finalCount - alreadyStreamed))
                            continuation.yield(emitTail)
                        }
                        hitStop = true
                        break
                    }
                    continuation.yield(emit)
                }
            }
            if !hitStop, !stopSequences.isEmpty, !pendingTail.isEmpty {
                accumulated += pendingTail
                if let stopHit = Self.firstStop(in: accumulated, stops: stopSequences) {
                    let finalCount = stopHit.lowerBoundOffset + stopHit.length
                    let alreadyStreamed = accumulated.count - pendingTail.count
                    if finalCount > alreadyStreamed {
                        let emitTail = String(accumulated.dropFirst(alreadyStreamed).prefix(finalCount - alreadyStreamed))
                        continuation.yield(emitTail)
                    }
                } else {
                    continuation.yield(pendingTail)
                }
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Pop the longest prefix of `buffer` that definitely does not contain the
    /// start of any stop string. Returns nil if the buffer is too small to
    /// decide (caller should wait for more text).
    private static func drainablePrefix(of buffer: inout String, stops: [String]) -> String? {
        // The largest stop prefix that could match at the tail determines how
        // much is safe to release. We conservatively keep the last
        // (maxStopLength - 1) characters buffered.
        let maxStop = stops.map(\.count).max() ?? 0
        guard buffer.count >= maxStop else { return nil }
        let keep = maxStop - 1
        let emitCount = buffer.count - keep
        let emit = String(buffer.prefix(emitCount))
        buffer = String(buffer.suffix(keep))
        return emit
    }

    /// Find the earliest occurrence of any stop string. Returns the character
    /// offset of the match start (from `text.startIndex`) and the matched
    /// stop's character length. Offsets (not String.Index) are returned
    /// because indices from `range(of:)` are not portable across String values.
    private static func firstStop(
        in text: String,
        stops: [String]
    ) -> (lowerBoundOffset: Int, length: Int)? {
        var best: (Int, Int)? = nil
        for stop in stops {
            if let range = text.range(of: stop) {
                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                if let current = best {
                    if offset < current.0 {
                        best = (offset, stop.count)
                    }
                } else {
                    best = (offset, stop.count)
                }
            }
        }
        return best
    }

    // MARK: - Memory warnings

    private func installMemoryWarningObserver() {
        #if canImport(UIKit)
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleMemoryWarning() }
        }
        #endif
    }

    private func handleMemoryWarning() {
        // Cancel any in-flight generation, then drop the cache.
        activeContinuation?.finish(throwing: CancellationError())
        activeContinuation = nil
        MLX.Memory.clearCache()
    }
}
