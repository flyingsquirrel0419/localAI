import Foundation

public enum ChatRole: String, Sendable, Equatable, Codable {
    case system, user, assistant, tool
}

public struct ChatMessage: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public let role: ChatRole
    public var content: String

    public init(id: UUID = UUID(), role: ChatRole, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

public struct GenerationParameters: Sendable, Equatable, Codable {
    public var temperature: Double
    public var topP: Double
    public var maxTokens: Int
    public var stopSequences: [String]

    public init(
        temperature: Double = 0.7,
        topP: Double = 0.9,
        maxTokens: Int = 1024,
        stopSequences: [String] = []
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
    }

    public static let `default` = GenerationParameters()
}

public enum ModelEngineError: Error, Equatable, Sendable {
    case notLoaded
    case alreadyLoaded
    case loadFailed(String)
}

/// A local inference engine. Implemented by MLX on-device; the protocol lives
/// here so the agent loop and UI are testable without a real model.
public protocol LocalModelEngine: Sendable {
    /// Load a model from a previously downloaded directory.
    func load(modelDirectory: URL) async throws
    func unload() async
    var isLoaded: Bool { get async }
    /// Stream token deltas. The stream finishes when generation completes,
    /// hits a stop sequence / maxTokens, or the task is cancelled.
    func generate(
        messages: [ChatMessage],
        parameters: GenerationParameters
    ) -> AsyncThrowingStream<String, Error>
}
