import Foundation
import LocalAICore
#if canImport(UIKit)
import UIKit
#endif

/// The state of one model as surfaced in the Models tab.
public enum ModelRowState: Equatable, Sendable {
    case inspected(ModelCompatibilityReport)
    case downloading(DownloadProgress)
    case downloaded(DownloadedModel)
    case active(DownloadedModel)
    case failed(String)
}

public struct ModelRow: Identifiable, Equatable, Sendable {
    public let id: String                 // org/name for repo entries; org--name for downloads
    public let repo: HFRepoReference
    public var info: HFModelInfo?
    public var state: ModelRowState
    /// Stashed report so a paused/failed download can resume without re-inspecting.
    public var inspectedReport: ModelCompatibilityReport?

    public init(id: String, repo: HFRepoReference, info: HFModelInfo?, state: ModelRowState, inspectedReport: ModelCompatibilityReport? = nil) {
        self.id = id
        self.repo = repo
        self.info = info
        self.state = state
        self.inspectedReport = inspectedReport
    }
}

/// Coordinates model URL inspection, download, on-disk store, and the active
/// MLX engine. Main-actor bound for UI.
@MainActor
public final class ModelService: ObservableObject {

    @Published public private(set) var rows: [ModelRow] = []
    @Published public private(set) var activeModelID: String?
    @Published public private(set) var loadedModelDirectory: URL?
    @Published public private(set) var engineState: MLXEngine.State = .unloaded
    @Published public var error: UserFacingError?

    public let engine: MLXEngine
    public let modelStore: ModelStore
    public let modelsRoot: URL
    public let credentialStore: CredentialStore

    private var downloader: ModelDownloader?
    private var downloaderRepoID: String?
    private var downloadTask: Task<Void, Never>?
    private var lastInspect: (repo: HFRepoReference, info: HFModelInfo)?

    public init(
        engine: MLXEngine,
        modelStore: ModelStore,
        modelsRoot: URL,
        credentialStore: CredentialStore
    ) {
        self.engine = engine
        self.modelStore = modelStore
        self.modelsRoot = modelsRoot
        self.credentialStore = credentialStore
    }

    // MARK: - Refresh

    public func refreshDownloaded() async {
        let downloaded = await modelStore.listDownloaded()
        let activeID = await modelStore.activeModelID()
        self.activeModelID = activeID

        // Replace `downloaded` / `active` rows, keep inspected/downloading rows.
        var rows = self.rows.filter {
            switch $0.state {
            case .downloaded, .active: return false
            default: return true
            }
        }
        for model in downloaded {
            let state: ModelRowState = (model.id == activeID) ? .active(model) : .downloaded(model)
            // HFRepoReference's memberwise init is internal; use the public parser.
            // `model.repo` is canonical "org/name" so parse always succeeds; if it
            // somehow fails (corrupt store), skip the row rather than crash.
            guard let repoRef = try? HFRepoReference.parse(model.repo) else { continue }
            rows.append(ModelRow(
                id: model.id,
                repo: repoRef,
                info: nil,
                state: state
            ))
        }
        self.rows = rows
    }

    // MARK: - Inspect

    public func inspect(urlString: String) async {
        let repo: HFRepoReference
        do {
            repo = try HFRepoReference.parse(urlString)
        } catch {
            self.error = UserFacingError(
                title: "Invalid model URL",
                message: "Paste a huggingface.co model URL, e.g. https://huggingface.co/org/name",
                recoveryAction: .dismiss,
                developerDetails: "parse failure"
            )
            return
        }

        // Already shown?
        if rows.contains(where: { $0.repo.id == repo.id && !$0.repoState.isDownloaded }) {
            return
        }
        if rows.contains(where: { $0.repo.id == repo.id }) {
            return
        }

        let token = try? credentialStore.get(.huggingFaceToken)
        let client = HuggingFaceClient(token: token)

        do {
            let info = try await client.modelInfo(repo: repo)
            let report = evaluate(info: info)
            let row = ModelRow(
                id: repo.id,
                repo: repo,
                info: info,
                state: .inspected(report),
                inspectedReport: report
            )
            rows.append(row)
            lastInspect = (repo, info)
        } catch let uf as UserFacingError {
            self.error = uf
        } catch {
            self.error = UserFacingErrorMapper.map(error)
        }
    }

    private func evaluate(info: HFModelInfo) -> ModelCompatibilityReport {
        let ram = Int64(ProcessInfo.processInfo.physicalMemory)
        let available: Int64 = (try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage) ?? 0
        return ModelCompatibility.evaluate(
            info: info,
            deviceRAMBytes: ram,
            availableStorageBytes: available
        )
    }

    // MARK: - Download

    public func startDownload(rowID: String) async {
        guard let row = rows.first(where: { $0.id == rowID }),
              let info = row.info,
              case .inspected(let report) = row.state else {
            return
        }

        let files = ModelCompatibility.neededFiles(info: info, format: report.format)
            .map { ModelFileDownload(path: $0.path, size: $0.size.map(Int64.init), sha256: $0.lfsSHA256) }

        let token = try? credentialStore.get(.huggingFaceToken)
        let downloader = ModelDownloader(
            repo: row.repo,
            files: files,
            modelsRoot: modelsRoot,
            token: token
        )
        self.downloader = downloader
        self.downloaderRepoID = row.id

        // Initial row update
        updateRowState(id: row.id, state: .downloading(DownloadProgress(
            bytesDownloaded: 0,
            totalBytes: report.downloadBytes,
            bytesPerSecond: 0,
            currentFile: "",
            state: .queued
        )))

        let progressStream = await downloader.progressStream()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            // Drive progress.
            let progressTask = Task { [weak self] in
                for await progress in progressStream {
                    await self?.updateRowState(id: row.id, state: .downloading(progress))
                }
            }

            do {
                try await downloader.start()
                progressTask.cancel()
                await MainActor.run {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                await self.refreshDownloaded()
            } catch {
                progressTask.cancel()
                let uf = UserFacingErrorMapper.map(error)
                await MainActor.run { self.error = uf }
                await self.updateRowState(id: row.id, state: .failed(uf.title))
            }
        }
    }

    public func pauseDownload() async {
        await downloader?.pause()
    }

    /// Resume a paused or failed download. Constructs a new downloader against
    /// the same on-disk state — `.partial` files resume via HTTP Range.
    public func resumeDownload() async {
        guard let repoID = downloaderRepoID,
              let row = rows.first(where: { $0.id == repoID }),
              let info = row.info else { return }
        let format = (row.inspectedReport?.format) ?? .unknown
        let files = ModelCompatibility.neededFiles(info: info, format: format)
            .map { ModelFileDownload(path: $0.path, size: $0.size.map(Int64.init), sha256: $0.lfsSHA256) }
        let token = try? credentialStore.get(.huggingFaceToken)
        let downloader = ModelDownloader(
            repo: row.repo,
            files: files,
            modelsRoot: modelsRoot,
            token: token
        )
        self.downloader = downloader

        let progressStream = await downloader.progressStream()
        downloadTask = Task { [weak self] in
            guard let self else { return }
            let progressTask = Task { [weak self] in
                for await progress in progressStream {
                    await self?.updateRowState(id: repoID, state: .downloading(progress))
                }
            }
            do {
                try await downloader.start()
                progressTask.cancel()
                await self.refreshDownloaded()
            } catch {
                progressTask.cancel()
                let uf = UserFacingErrorMapper.map(error)
                await MainActor.run { self.error = uf }
                await self.updateRowState(id: repoID, state: .failed(uf.title))
            }
        }
    }

    public func cancelDownload() async {
        await downloader?.cancel()
        if let id = downloaderRepoID {
            rows.removeAll { $0.id == id }
        }
        downloader = nil
        downloaderRepoID = nil
    }

    // MARK: - Use / delete

    public func useModel(_ modelID: String) async {
        let downloaded = await modelStore.listDownloaded()
        guard let model = downloaded.first(where: { $0.id == modelID }) else { return }
        do {
            try await engine.load(modelDirectory: model.directory)
            try await modelStore.setActiveModel(id: modelID)
            self.loadedModelDirectory = model.directory
            self.engineState = await engine.currentState
            await MainActor.run {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            await refreshDownloaded()
        } catch {
            self.error = UserFacingErrorMapper.map(error)
            self.engineState = await engine.currentState
        }
    }

    public func unloadActiveModel() async {
        await engine.unload()
        try? await modelStore.setActiveModel(id: nil)
        self.loadedModelDirectory = nil
        self.engineState = .unloaded
        await refreshDownloaded()
    }

    public func deleteModel(_ modelID: String) async {
        if activeModelID == modelID {
            await unloadActiveModel()
        }
        do {
            try await modelStore.delete(modelID: modelID, confirm: true)
        } catch {
            self.error = UserFacingErrorMapper.map(error)
        }
        await refreshDownloaded()
    }

    // MARK: - Helpers

    private func updateRowState(id: String, state: ModelRowState) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].state = state
    }
}

private extension ModelRow {
    var repoState: RepoState {
        switch state {
        case .downloaded, .active: return .downloaded
        case .downloading: return .downloading
        case .inspected: return .inspected
        case .failed: return .failed
        }
    }
    enum RepoState {
        case inspected, downloading, downloaded, failed
        var isDownloaded: Bool { self == .downloaded }
    }
}
