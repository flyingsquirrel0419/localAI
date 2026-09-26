import Foundation

/// Metadata describing a workspace: a locally-cloned repository plus app state.
public struct WorkspaceMetadata: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var repositoryURL: URL?
    public var branch: String?
    public var createdAt: Date
    public var lastOpenedAt: Date
    public var activeModel: String?

    public init(
        id: UUID = UUID(),
        name: String,
        repositoryURL: URL? = nil,
        branch: String? = nil,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        activeModel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.repositoryURL = repositoryURL
        self.branch = branch
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.activeModel = activeModel
    }
}

public enum WorkspaceStoreError: Error, Equatable, Sendable {
    case workspaceNotFound(UUID)
    case nameIsEmpty
    case deletionNotConfirmed
    case metadataCorrupted(UUID)
}

/// Actor managing on-disk workspaces under `<root>/Workspaces/<UUID>/`.
///
/// Layout per workspace:
///   <UUID>/metadata.json
///   <UUID>/repository/   (cloned repo lives here)
public actor WorkspaceStore {
    public let rootURL: URL

    private var workspacesURL: URL {
        rootURL.appendingPathComponent("Workspaces", isDirectory: true)
    }

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private func directoryURL(for id: UUID) -> URL {
        workspacesURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func metadataURL(for id: UUID) -> URL {
        directoryURL(for: id).appendingPathComponent("metadata.json")
    }

    /// URL of the on-disk repository for a workspace (created on workspace creation).
    public func repositoryURL(for id: UUID) throws -> URL {
        let dir = directoryURL(for: id)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw WorkspaceStoreError.workspaceNotFound(id)
        }
        return dir.appendingPathComponent("repository", isDirectory: true)
    }

    /// Create a new workspace, its repository directory, and persist metadata.
    @discardableResult
    public func create(name: String, repositoryURL: URL? = nil, branch: String? = nil) throws -> WorkspaceMetadata {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceStoreError.nameIsEmpty }

        let metadata = WorkspaceMetadata(name: trimmed, repositoryURL: repositoryURL, branch: branch)
        let dir = directoryURL(for: metadata.id)
        let repo = dir.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try persist(metadata)
        return metadata
    }

    /// List all workspaces, most recently opened first. Corrupted entries are skipped.
    public func list() throws -> [WorkspaceMetadata] {
        let fm = FileManager.default
        try fm.createDirectory(at: workspacesURL, withIntermediateDirectories: true)
        let entries = try fm.contentsOfDirectory(atPath: workspacesURL.path)
        var result: [WorkspaceMetadata] = []
        for entry in entries {
            guard let id = UUID(uuidString: entry) else { continue }
            let url = metadataURL(for: id)
            guard fm.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let meta = try? Self.decoder.decode(WorkspaceMetadata.self, from: data)
            else { continue }
            result.append(meta)
        }
        return result.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    /// Fetch metadata for one workspace.
    public func metadata(for id: UUID) throws -> WorkspaceMetadata {
        let url = metadataURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            throw WorkspaceStoreError.workspaceNotFound(id)
        }
        guard let meta = try? Self.decoder.decode(WorkspaceMetadata.self, from: data) else {
            throw WorkspaceStoreError.metadataCorrupted(id)
        }
        return meta
    }

    /// Mark a workspace as opened (updates lastOpenedAt to now).
    @discardableResult
    public func open(id: UUID) throws -> WorkspaceMetadata {
        var meta = try metadata(for: id)
        meta.lastOpenedAt = Date()
        try persist(meta)
        return meta
    }

    /// Rename a workspace.
    @discardableResult
    public func rename(id: UUID, to newName: String) throws -> WorkspaceMetadata {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceStoreError.nameIsEmpty }
        var meta = try metadata(for: id)
        meta.name = trimmed
        try persist(meta)
        return meta
    }

    /// Update the active model for a workspace.
    @discardableResult
    public func setActiveModel(id: UUID, model: String?) throws -> WorkspaceMetadata {
        var meta = try metadata(for: id)
        meta.activeModel = model
        try persist(meta)
        return meta
    }

    /// Delete a workspace and all of its contents. Requires explicit confirmation.
    public func delete(id: UUID, confirm: Bool) throws {
        guard confirm else { throw WorkspaceStoreError.deletionNotConfirmed }
        let dir = directoryURL(for: id)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw WorkspaceStoreError.workspaceNotFound(id)
        }
        try FileManager.default.removeItem(at: dir)
    }

    private func persist(_ metadata: WorkspaceMetadata) throws {
        let data = try Self.encoder.encode(metadata)
        try data.write(to: metadataURL(for: metadata.id), options: .atomic)
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
