import Foundation

public struct DownloadedModel: Sendable, Equatable, Identifiable {
    public let id: String           // "org--name"
    public let repo: String         // "org/name"
    public let revision: String
    public let directory: URL
    public let files: [String]
    public let totalBytes: Int64
    public let completedAt: Date
}

public enum ModelStoreError: Error, Equatable, Sendable {
    case notFound(String)
    case deleteRequiresConfirmation
}

/// Tracks models downloaded into a root directory. A model is listed only when
/// its manifest is valid AND every file in the manifest exists on disk.
public actor ModelStore {
    private let modelsRoot: URL
    private let activeModelURL: URL
    private var cachedActiveID: String?? // nil = not loaded, .some(nil) = none set

    public init(modelsRoot: URL) {
        self.modelsRoot = modelsRoot
        self.activeModelURL = modelsRoot.appendingPathComponent(".active-model")
        self.cachedActiveID = nil
    }

    /// All valid, complete downloads under the root.
    public func listDownloaded() -> [DownloadedModel] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: modelsRoot.path) else { return [] }
        var models: [DownloadedModel] = []
        for entry in entries where !entry.hasPrefix(".") {
            let dir = modelsRoot.appendingPathComponent(entry, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let model = loadModel(id: entry, directory: dir) {
                models.append(model)
            }
        }
        return models.sorted { $0.id < $1.id }
    }

    private func loadModel(id: String, directory: URL) -> DownloadedModel? {
        let fm = FileManager.default
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? ModelDownloader.makeManifestDecoder()
                  .decode(ModelDownloader.Manifest.self, from: data) else {
            return nil
        }
        var total: Int64 = 0
        for file in manifest.files {
            let url = directory.appendingPathComponent(file)
            guard fm.fileExists(atPath: url.path),
                  let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else {
                return nil // incomplete
            }
            total += size
        }
        return DownloadedModel(
            id: id,
            repo: manifest.repo,
            revision: manifest.revision,
            directory: directory,
            files: manifest.files,
            totalBytes: total,
            completedAt: manifest.completedAt
        )
    }

    // MARK: - Active model

    public func activeModelID() -> String? {
        if let cached = cachedActiveID { return cached }
        guard let data = try? Data(contentsOf: activeModelURL),
              let id = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else {
            cachedActiveID = .some(nil)
            return nil
        }
        cachedActiveID = .some(id)
        return id
    }

    public func setActiveModel(id: String?) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        if let id {
            try Data(id.utf8).write(to: activeModelURL)
        } else {
            try? fm.removeItem(at: activeModelURL)
        }
        cachedActiveID = .some(id)
    }

    // MARK: - Delete

    /// Delete a downloaded model. Refuses without `confirm: true`. If the model
    /// is active, the active selection is cleared.
    public func delete(modelID: String, confirm: Bool) throws {
        guard confirm else { throw ModelStoreError.deleteRequiresConfirmation }
        let dir = modelsRoot.appendingPathComponent(modelID, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else {
            throw ModelStoreError.notFound(modelID)
        }
        try FileManager.default.removeItem(at: dir)
        if activeModelID() == modelID {
            try setActiveModel(id: nil)
        }
    }
}
