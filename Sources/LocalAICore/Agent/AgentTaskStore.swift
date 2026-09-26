import Foundation

public enum AgentTaskState: String, Codable, Sendable, Equatable {
    case queued, running, paused, interrupted, completed, failed
}

public struct ToolHistoryEntry: Codable, Sendable, Equatable {
    public let call: RecordedCall
    public let resultSummary: String
    public let succeeded: Bool
    public let at: Date

    public struct RecordedCall: Codable, Sendable, Equatable {
        public let tool: String
        /// JSON string of arguments (kept as text so Any payloads survive Codable).
        public let argumentsJSON: String

        public init(tool: String, argumentsJSON: String) {
            self.tool = tool
            self.argumentsJSON = argumentsJSON
        }
    }

    public init(call: RecordedCall, resultSummary: String, succeeded: Bool, at: Date = Date()) {
        self.call = call
        self.resultSummary = resultSummary
        self.succeeded = succeeded
        self.at = at
    }
}

public struct AgentCheckpoint: Codable, Sendable, Equatable {
    public let taskId: UUID
    public var workspaceId: UUID
    public var userRequest: String
    public var currentStep: Int
    public var state: AgentTaskState
    public var toolHistory: [ToolHistoryEntry]
    public var modifiedFiles: [String]
    public var messages: [ChatMessage]
    public var lastCheckpoint: Date

    public init(
        taskId: UUID,
        workspaceId: UUID,
        userRequest: String,
        currentStep: Int = 0,
        state: AgentTaskState = .queued,
        toolHistory: [ToolHistoryEntry] = [],
        modifiedFiles: [String] = [],
        messages: [ChatMessage] = [],
        lastCheckpoint: Date = Date()
    ) {
        self.taskId = taskId
        self.workspaceId = workspaceId
        self.userRequest = userRequest
        self.currentStep = currentStep
        self.state = state
        self.toolHistory = toolHistory
        self.modifiedFiles = modifiedFiles
        self.messages = messages
        self.lastCheckpoint = lastCheckpoint
    }
}

public enum AgentTaskStoreError: Error, Equatable, Sendable {
    case taskNotFound(UUID)
}

/// Persists AgentCheckpoint JSON per task under `<root>/AgentTasks/<UUID>.json`.
/// Saves after every tool result so an interrupted run can resume.
public actor AgentTaskStore {
    public let rootURL: URL

    private var tasksURL: URL {
        rootURL.appendingPathComponent("AgentTasks", isDirectory: true)
    }

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private func url(for taskId: UUID) -> URL {
        tasksURL.appendingPathComponent("\(taskId.uuidString).json")
    }

    public func save(_ checkpoint: AgentCheckpoint) throws {
        try FileManager.default.createDirectory(at: tasksURL, withIntermediateDirectories: true)
        var copy = checkpoint
        copy.lastCheckpoint = Date()
        let data = try Self.encoder.encode(copy)
        try data.write(to: url(for: checkpoint.taskId), options: .atomic)
    }

    public func load(taskId: UUID) throws -> AgentCheckpoint {
        let url = url(for: taskId)
        guard let data = try? Data(contentsOf: url),
              let checkpoint = try? Self.decoder.decode(AgentCheckpoint.self, from: data)
        else {
            throw AgentTaskStoreError.taskNotFound(taskId)
        }
        return checkpoint
    }

    public func list() throws -> [AgentCheckpoint] {
        let fm = FileManager.default
        try fm.createDirectory(at: tasksURL, withIntermediateDirectories: true)
        let entries = try fm.contentsOfDirectory(atPath: tasksURL.path)
        var checkpoints: [AgentCheckpoint] = []
        for entry in entries where entry.hasSuffix(".json") {
            let url = tasksURL.appendingPathComponent(entry)
            if let data = try? Data(contentsOf: url),
               let c = try? Self.decoder.decode(AgentCheckpoint.self, from: data) {
                checkpoints.append(c)
            }
        }
        return checkpoints.sorted { $0.lastCheckpoint > $1.lastCheckpoint }
    }

    public func delete(taskId: UUID) throws {
        let url = url(for: taskId)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Call at app launch: any task still marked `running` was killed mid-flight
    /// and becomes `interrupted`.
    public func markInterruptedOnLaunch() throws -> Int {
        var count = 0
        for var checkpoint in try list() where checkpoint.state == .running {
            checkpoint.state = .interrupted
            try save(checkpoint)
            count += 1
        }
        return count
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .deferredToDate
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .deferredToDate
        return d
    }()
}
