import Foundation
import LocalAICore
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
#if canImport(UIKit)
import UIKit
#endif

/// LocalAICore `LocalModelEngine` implementation backed by mlx-swift-lm.
///
/// - Loads a model from a previously-downloaded local directory (the one
///   `ModelDownloader` produced).
/// - Streams token deltas via `ChatSession.streamResponse`.
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

    public func generate(
        messages: [ChatMessage],
        parameters: GenerationParameters
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            self.activeContinuation = continuation
            let task = Task {
                await self.runGeneration(
                    messages: messages,
                    parameters: parameters,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await self.clearActiveContinuation(continuation) }
            }
        }
    }

    // MARK: - Internals

    private func clearActiveContinuation(
        _ continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        if activeContinuation != nil {
            activeContinuation = nil
        }
    }

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

        // Translate our messages into MLX chat messages. The first system
        // message (if any) becomes the session instructions; the LAST user
        // message is what we stream against; everything before it becomes the
        // session's prior history.
        var instructions: String? = nil
        var prior: [Chat.Message] = []
        var latestUser: Chat.Message? = nil
        for message in messages {
            switch message.role {
            case .system:
                if instructions == nil {
                    instructions = message.content
                } else {
                    prior.append(Chat.Message(role: .system, content: message.content))
                }
            case .user:
                if let previous = latestUser {
                    prior.append(previous)
                }
                latestUser = Chat.Message(role: .user, content: message.content)
            case .assistant:
                prior.append(Chat.Message(role: .assistant, content: message.content))
            case .tool:
                prior.append(Chat.Message(role: .user, content: message.content))
            }
        }
        guard let latest = latestUser else {
            continuation.finish(throwing: ModelEngineError.notLoaded)
            return
        }

        // Build a fresh ChatSession for this turn, rehydrating prior history.
        let session = ChatSession(
            container,
            instructions: instructions,
            history: prior,
            generateParameters: params
        )

        do {
            let stream = session.streamResponse(to: latest.content)
            for try await chunk in stream {
                try Task.checkCancellation()
                continuation.yield(chunk)
            }
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
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
