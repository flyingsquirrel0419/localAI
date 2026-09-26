import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DownloadState: String, Sendable, Equatable, Codable {
    case queued, running, paused, completed, failed, cancelled
}

public struct DownloadProgress: Sendable, Equatable {
    public let bytesDownloaded: Int64
    public let totalBytes: Int64
    public let bytesPerSecond: Double
    public let currentFile: String
    public let state: DownloadState

    /// Public memberwise init so the app target can construct placeholder
    /// progress values (e.g. "queued" before the downloader emits its first
    /// event). Without this the synthesized memberwise init is internal.
    public init(
        bytesDownloaded: Int64,
        totalBytes: Int64,
        bytesPerSecond: Double,
        currentFile: String,
        state: DownloadState
    ) {
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.currentFile = currentFile
        self.state = state
    }
}

public enum DownloadError: Error, Equatable, Sendable {
    case checksumMismatch(path: String)
    case sizeMismatch(path: String, expected: Int64, got: Int64)
    case httpStatus(path: String, status: Int)
    case missingModelsRoot
    /// Server-supplied file path is invalid (absolute, contains `..`, or
    /// resolves outside the model directory).
    case invalidPath(String)
}

/// A file to download, with optional integrity metadata from the Hub API.
public struct ModelFileDownload: Sendable, Equatable {
    public let path: String
    public let size: Int64?
    public let sha256: String?

    public init(path: String, size: Int64?, sha256: String?) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// Streams raw response bytes so downloads never buffer whole files in memory.
public protocol HTTPByteStreamer: Sendable {
    /// Start a GET (optionally with `Range: bytes=offset-`) and return the
    /// response plus a byte-chunk stream.
    func bytes(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>)
}

public struct URLSessionByteStreamer: HTTPByteStreamer {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func bytes(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        #if canImport(FoundationNetworking)
        // Linux swift-corelibs-foundation lacks URLSession.bytes; chunk manually.
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.httpStatus(path: request.url?.path ?? "", status: 0) }
        return (http, AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish()
        })
        #else
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DownloadError.httpStatus(path: request.url?.path ?? "", status: 0) }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            Task {
                do {
                    var buffer = Data()
                    buffer.reserveCapacity(1 << 16)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if buffer.count >= (1 << 16) {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        return (http, stream)
        #endif
    }
}

/// Downloads model files from Hugging Face with resume (`.partial` + HTTP Range),
/// verification, pause/resume/cancel, and progress streaming.
public actor ModelDownloader {
    private let repo: HFRepoReference
    private let files: [ModelFileDownload]
    private let modelsRoot: URL
    private let streamer: HTTPByteStreamer
    private let token: String?

    private var state: DownloadState = .queued
    private var pauseRequested = false
    private var cancelRequested = false
    private var progressContinuation: AsyncStream<DownloadProgress>.Continuation?
    private var latestProgress = DownloadProgress(bytesDownloaded: 0, totalBytes: 0, bytesPerSecond: 0, currentFile: "", state: .queued)

    /// Directory for this model: `<modelsRoot>/<org>--<name>/`.
    public var modelDirectory: URL {
        modelsRoot.appendingPathComponent("\(repo.organization)--\(repo.name)", isDirectory: true)
    }

    public init(
        repo: HFRepoReference,
        files: [ModelFileDownload],
        modelsRoot: URL,
        streamer: HTTPByteStreamer = URLSessionByteStreamer(),
        token: String? = nil
    ) {
        self.repo = repo
        self.files = files
        self.modelsRoot = modelsRoot
        self.streamer = streamer
        self.token = token
    }

    public func currentProgress() -> DownloadProgress { latestProgress }

    /// Progress stream. Emits an initial event immediately.
    public func progressStream() -> AsyncStream<DownloadProgress> {
        AsyncStream { continuation in
            self.progressContinuation = continuation
            continuation.yield(self.latestProgress)
            continuation.onTermination = { _ in
                Task { await self.clearContinuation() }
            }
        }
    }

    private func clearContinuation() { progressContinuation = nil }

    private func emit(_ p: DownloadProgress) {
        latestProgress = p
        progressContinuation?.yield(p)
    }

    public func pause() {
        guard state == .running || state == .queued else { return }
        pauseRequested = true
        state = .paused
        emit(DownloadProgress(bytesDownloaded: latestProgress.bytesDownloaded,
                              totalBytes: latestProgress.totalBytes,
                              bytesPerSecond: 0,
                              currentFile: latestProgress.currentFile,
                              state: .paused))
    }

    /// Cancel: stops the download and deletes all `.partial` files.
    public func cancel() {
        cancelRequested = true
        pauseRequested = false
        state = .cancelled
    }

    /// Run the download to completion. Resumable: existing `.partial` files are
    /// continued via HTTP Range. Safe to call again after `pause()`.
    public func start() async throws {
        pauseRequested = false
        if cancelRequested {
            deleteAllPartials()
            emit(DownloadProgress(bytesDownloaded: 0, totalBytes: 0,
                                  bytesPerSecond: 0, currentFile: "", state: .cancelled))
            return
        }
        state = .running

        let fm = FileManager.default
        try fm.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let totalBytes = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var downloadedAcrossFiles: Int64 = 0
        // Account for already-partial work.
        for f in files {
            let partial = try partialURL(for: f)
            let final = try finalURL(for: f)
            if fm.fileExists(atPath: final.path) {
                downloadedAcrossFiles += f.size ?? (try? fileSize(final)) ?? 0
            } else if fm.fileExists(atPath: partial.path) {
                downloadedAcrossFiles += (try? fileSize(partial)) ?? 0
            }
        }

        let startedAt = Date()
        for file in files {
            if cancelRequested {
                deleteAllPartials()
                emit(progress(0, totalBytes, file.path, .cancelled))
                return
            }
            while pauseRequested {
                try await Task.sleep(nanoseconds: 100_000_000)
                if cancelRequested {
                    deleteAllPartials()
                    emit(progress(downloadedAcrossFiles, totalBytes, file.path, .cancelled))
                    return
                }
                try Task.checkCancellation()
            }
            try Task.checkCancellation()
            try await downloadFile(file, totalBytes: totalBytes,
                                   baseDownloaded: &downloadedAcrossFiles,
                                   startedAt: startedAt)
        }

        try writeManifest()
        state = .completed
        emit(DownloadProgress(bytesDownloaded: totalBytes, totalBytes: totalBytes,
                              bytesPerSecond: 0, currentFile: "", state: .completed))
    }

    private func progress(_ downloaded: Int64, _ total: Int64, _ file: String, _ state: DownloadState) -> DownloadProgress {
        DownloadProgress(bytesDownloaded: downloaded, totalBytes: total,
                         bytesPerSecond: latestProgress.bytesPerSecond,
                         currentFile: file, state: state)
    }

    private func downloadFile(
        _ file: ModelFileDownload,
        totalBytes: Int64,
        baseDownloaded: inout Int64,
        startedAt: Date
    ) async throws {
        let fm = FileManager.default
        let final = try finalURL(for: file)
        let partial = try partialURL(for: file)

        // Already done? Verify integrity and skip.
        if fm.fileExists(atPath: final.path) {
            if try verify(file, at: final) { return }
            try fm.removeItem(at: final)
            baseDownloaded -= file.size ?? 0
        }

        var offset: Int64 = 0
        if fm.fileExists(atPath: partial.path) {
            offset = (try? fileSize(partial)) ?? 0
            if let expected = file.size, offset >= expected {
                // Partial is complete (or corrupt). Try finalizing; else restart.
                if try verify(file, at: partial) {
                    try fm.moveItem(at: partial, to: final)
                    return
                }
                try fm.removeItem(at: partial)
                baseDownloaded -= offset
                offset = 0
            }
        }

        var request = URLRequest(url: resolveURL(for: file))
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("localai-ios/1.0", forHTTPHeaderField: "User-Agent")

        let (response, byteStream) = try await streamer.bytes(for: request)
        let expectedStatus = offset > 0 ? 206 : 200
        // Servers may ignore Range; if we got a 200 while resuming, restart from 0.
        var effectiveOffset = offset
        if offset > 0 && response.statusCode == 200 {
            try? fm.removeItem(at: partial)
            baseDownloaded -= offset
            effectiveOffset = 0
        } else if response.statusCode != expectedStatus {
            state = .failed
            emit(progress(baseDownloaded, totalBytes, file.path, .failed))
            throw DownloadError.httpStatus(path: file.path, status: response.statusCode)
        }

        try fm.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: partial.path) {
            _ = fm.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        do {
            try handle.seekToEnd()
            var written = effectiveOffset
            var lastEmit = Date()
            for try await chunk in byteStream {
                if cancelRequested {
                    try handle.close()
                    deleteAllPartials()
                    emit(progress(baseDownloaded, totalBytes, file.path, .cancelled))
                    return
                }
                while pauseRequested {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    if cancelRequested {
                        try handle.close()
                        deleteAllPartials()
                        emit(progress(baseDownloaded, totalBytes, file.path, .cancelled))
                        return
                    }
                }
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                if Date().timeIntervalSince(lastEmit) > 0.25 {
                    lastEmit = Date()
                    let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                    let speed = Double(baseDownloaded + written) / elapsed
                    emit(DownloadProgress(bytesDownloaded: baseDownloaded + written,
                                          totalBytes: totalBytes,
                                          bytesPerSecond: speed,
                                          currentFile: file.path, state: .running))
                }
            }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        // Verify then promote.
        let partialOK = try verify(file, at: partial)
        if !partialOK {
            try? fm.removeItem(at: partial)
            state = .failed
            emit(progress(baseDownloaded, totalBytes, file.path, .failed))
            if let sha = file.sha256, !sha.isEmpty {
                throw DownloadError.checksumMismatch(path: file.path)
            }
            throw DownloadError.sizeMismatch(path: file.path, expected: file.size ?? -1,
                                             got: (try? fileSize(partial)) ?? -1)
        }
        baseDownloaded += (file.size ?? (try? fileSize(partial)) ?? 0) - effectiveOffset
        try fm.moveItem(at: partial, to: final)
        emit(progress(baseDownloaded, totalBytes, file.path, .running))
    }

    /// Size check always; sha256 check when an LFS oid is known.
    private func verify(_ file: ModelFileDownload, at url: URL) throws -> Bool {
        if let expected = file.size {
            let actual = try fileSize(url)
            if actual != expected { return false }
        }
        if let sha = file.sha256, !sha.isEmpty {
            let digest = try SHA256.hexDigest(fileAt: url)
            if digest.lowercased() != sha.lowercased() { return false }
        }
        return true
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func resolveURL(for file: ModelFileDownload) -> URL {
        let encodedPath = file.path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repo.id)/resolve/\(repo.revision)/\(encodedPath)")!
    }

    private func finalURL(for file: ModelFileDownload) throws -> URL {
        try resolveUnderModelDirectory(file.path)
    }

    private func partialURL(for file: ModelFileDownload) throws -> URL {
        // Validate the file path itself first (so the error reports the real
        // offender), then append the .partial suffix.
        let validated = try resolveUnderModelDirectory(file.path)
        return validated.appendingPathExtension("partial")
    }

    /// Resolve `relativePath` under `modelDirectory`, rejecting absolute paths,
    /// `..` components, and anything that resolves outside the model dir.
    /// M5: server-supplied paths from a (hypothetically hostile) Hub response
    /// must never escape the per-model directory.
    private func resolveUnderModelDirectory(_ relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\0") else {
            throw DownloadError.invalidPath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw DownloadError.invalidPath(relativePath)
        }
        let joined = modelDirectory.appendingPathComponent(relativePath)
        let standardized = joined.standardizedFileURL.path
        let root = modelDirectory.standardizedFileURL.path
        guard standardized == root || standardized.hasPrefix(root + "/") else {
            throw DownloadError.invalidPath(relativePath)
        }
        return joined
    }

    private func deleteAllPartials() {
        let fm = FileManager.default
        for file in files {
            if let url = try? partialURL(for: file) {
                try? fm.removeItem(at: url)
            }
        }
    }

    struct Manifest: Codable {
        let repo: String
        let revision: String
        let files: [String]
        let sizes: [String: Int64]
        let completedAt: Date
    }

    static func makeManifestEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeManifestDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func writeManifest() throws {
        var sizes: [String: Int64] = [:]
        for f in files { sizes[f.path] = f.size }
        let manifest = Manifest(
            repo: repo.id,
            revision: repo.revision,
            files: files.map(\.path),
            sizes: sizes,
            completedAt: Date()
        )
        let data = try Self.makeManifestEncoder().encode(manifest)
        try data.write(to: modelDirectory.appendingPathComponent("manifest.json"))
    }
}
