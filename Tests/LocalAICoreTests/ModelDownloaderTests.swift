import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LocalAICore

/// Byte streamer that serves file bodies from memory and honors Range requests.
final class MockByteStreamer: HTTPByteStreamer, @unchecked Sendable {
    /// path-suffix -> full body
    var bodies: [String: Data] = [:]
    /// path-suffix -> sha256 to enforce? no — real bytes; sha checked from bodies.
    var requestCount = 0
    var rangeRequestsSeen: [String] = []
    private let lock = NSLock()

    func bytes(for request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        lock.lock()
        requestCount += 1
        let url = request.url!
        let match = bodies.first { url.absoluteString.hasSuffix($0.key) }
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        if let r = rangeHeader { rangeRequestsSeen.append(r) }
        lock.unlock()

        guard let (pathSuffix, full) = match else {
            let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (resp, AsyncThrowingStream { $0.finish(throwing: DownloadError.httpStatus(path: url.path, status: 404)) })
        }

        var data = full
        var status = 200
        if let rangeHeader,
           let range = parseRange(rangeHeader),
           range < full.count {
            data = full.subdata(in: range..<full.count)
            status = 206
        } else if rangeHeader != nil {
            _ = pathSuffix
        }

        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (resp, AsyncThrowingStream { continuation in
            // Emit in small chunks to exercise streaming.
            let chunkSize = 4096
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                continuation.yield(data.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        })
    }

    private func parseRange(_ header: String) -> Int? {
        // "bytes=123-"
        guard header.hasPrefix("bytes=") else { return nil }
        let body = header.dropFirst(6)
        guard let dash = body.firstIndex(of: "-") else { return nil }
        return Int(body[..<dash])
    }
}

final class ModelDownloaderTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeRepo() throws -> HFRepoReference { try HFRepoReference.parse("org/model") }

    private func makeDownloader(
        streamer: MockByteStreamer,
        files: [ModelFileDownload]
    ) throws -> ModelDownloader {
        ModelDownloader(repo: try makeRepo(), files: files, modelsRoot: tempRoot, streamer: streamer)
    }

    private func modelDir() -> URL {
        tempRoot.appendingPathComponent("org--model", isDirectory: true)
    }

    func testBasicDownload() async throws {
        let body = Data((0..<10_000).map { UInt8($0 % 251) })
        let sha = SHA256.hexDigest(body)
        let streamer = MockByteStreamer()
        streamer.bodies["config.json"] = body

        let downloader = try makeDownloader(
            streamer: streamer,
            files: [ModelFileDownload(path: "config.json", size: Int64(body.count), sha256: sha)]
        )
        try await downloader.start()

        let finalURL = modelDir().appendingPathComponent("config.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertEqual(try Data(contentsOf: finalURL), body)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: modelDir().appendingPathComponent("manifest.json").path))
        let progress = await downloader.currentProgress()
        XCTAssertEqual(progress.state, .completed)
    }

    func testResumeFromPartial() async throws {
        let body = Data((0..<20_000).map { UInt8($0 % 253) })
        let sha = SHA256.hexDigest(body)
        let streamer = MockByteStreamer()
        streamer.bodies["weights.bin"] = body

        // Pre-seed a partial with the first 8,192 bytes.
        let dir = modelDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appendingPathComponent("weights.bin.partial")
        try body.prefix(8192).write(to: partial)

        let downloader = try makeDownloader(
            streamer: streamer,
            files: [ModelFileDownload(path: "weights.bin", size: Int64(body.count), sha256: sha)]
        )
        try await downloader.start()

        XCTAssertTrue(streamer.rangeRequestsSeen.contains("bytes=8192-"))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("weights.bin")), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testChecksumMismatchFailsAndRemovesPartial() async throws {
        let body = Data("corrupt-content".utf8)
        let streamer = MockByteStreamer()
        streamer.bodies["model.safetensors"] = body

        let downloader = try makeDownloader(
            streamer: streamer,
            files: [ModelFileDownload(path: "model.safetensors", size: Int64(body.count),
                                      sha256: String(repeating: "0", count: 64))]
        )
        do {
            try await downloader.start()
            XCTFail("expected checksum failure")
        } catch let DownloadError.checksumMismatch(path) {
            XCTAssertEqual(path, "model.safetensors")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: modelDir().appendingPathComponent("model.safetensors.partial").path))
        let progress = await downloader.currentProgress()
        XCTAssertEqual(progress.state, .failed)
    }

    func testCancelDeletesPartials() async throws {
        // A streamer that emits one chunk then hangs would be ideal; simpler:
        // pre-seed a partial, then cancel before start so cancel path is exercised.
        let streamer = MockByteStreamer()
        streamer.bodies["f.bin"] = Data(repeating: 7, count: 100)
        let dir = modelDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appendingPathComponent("f.bin.partial")
        try Data(repeating: 7, count: 50).write(to: partial)

        let downloader = try makeDownloader(
            streamer: streamer,
            files: [ModelFileDownload(path: "f.bin", size: 100, sha256: nil)]
        )
        await downloader.cancel()
        try await downloader.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        let progress = await downloader.currentProgress()
        XCTAssertEqual(progress.state, .cancelled)
    }

    func testProgressStreamEmits() async throws {
        let body = Data(repeating: 3, count: 100_000)
        let streamer = MockByteStreamer()
        streamer.bodies["big.bin"] = body
        let downloader = try makeDownloader(
            streamer: streamer,
            files: [ModelFileDownload(path: "big.bin", size: Int64(body.count), sha256: nil)]
        )
        var sawRunning = false
        let stream = await downloader.progressStream()
        let collector = Task {
            for await p in stream {
                if p.state == .running { sawRunning = true }
                if p.state == .completed || p.state == .failed { break }
            }
        }
        try await downloader.start()
        _ = await collector.value
        XCTAssertTrue(sawRunning)
    }

    // M5: server-supplied paths must never escape the model directory.
    func testRejectsPathTraversal() async throws {
        let streamer = MockByteStreamer()
        streamer.bodies["evil.bin"] = Data("x".utf8)
        let downloader = try makeDownloader(
            streamer: streamer,
            files: [ModelFileDownload(path: "../evil.bin", size: 1, sha256: nil)]
        )
        do {
            try await downloader.start()
            XCTFail("expected invalidPath")
        } catch let DownloadError.invalidPath(path) {
            XCTAssertEqual(path, "../evil.bin")
        }
        // Nothing should have been written outside the model directory.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("evil.bin").path))
    }

    func testRejectsAbsolutePath() async throws {
        let streamer = MockByteStreamer()
        let downloader = try makeDownloader(
            streamer: streamer,
            files: [ModelFileDownload(path: "/etc/passwd", size: 1, sha256: nil)]
        )
        do {
            try await downloader.start()
            XCTFail("expected invalidPath")
        } catch let DownloadError.invalidPath(path) {
            XCTAssertEqual(path, "/etc/passwd")
        }
    }
}

final class ModelStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func seedModel(id: String, files: [String: String]) throws {
        let dir = tempRoot.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var sizes: [String: Int64] = [:]
        for (path, contents) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
            sizes[path] = Int64(contents.utf8.count)
        }
        let manifest: [String: Any] = [
            "repo": id.replacingOccurrences(of: "--", with: "/"),
            "revision": "main",
            "files": Array(files.keys),
            "sizes": sizes,
            "completedAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"))
    }

    func testListValidModel() async throws {
        try seedModel(id: "org--a", files: ["config.json": "{}"])
        let store = ModelStore(modelsRoot: tempRoot)
        let models = await store.listDownloaded()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.id, "org--a")
        XCTAssertEqual(models.first?.repo, "org/a")
    }

    func testModelWithMissingFileNotListed() async throws {
        try seedModel(id: "org--broken", files: ["config.json": "{}", "weights.bin": "xx"])
        try FileManager.default.removeItem(at: tempRoot.appendingPathComponent("org--broken/weights.bin"))
        let store = ModelStore(modelsRoot: tempRoot)
        let models = await store.listDownloaded()
        XCTAssertTrue(models.isEmpty)
    }

    func testActiveModelPersistence() async throws {
        let store = ModelStore(modelsRoot: tempRoot)
        let initial = await store.activeModelID()
        XCTAssertNil(initial)
        try await store.setActiveModel(id: "org--a")
        let set = await store.activeModelID()
        XCTAssertEqual(set, "org--a")
        // Fresh instance reads from disk.
        let store2 = ModelStore(modelsRoot: tempRoot)
        let persisted = await store2.activeModelID()
        XCTAssertEqual(persisted, "org--a")
    }

    func testDeleteRequiresConfirmation() async throws {
        try seedModel(id: "org--a", files: ["config.json": "{}"])
        let store = ModelStore(modelsRoot: tempRoot)
        do {
            try await store.delete(modelID: "org--a", confirm: false)
            XCTFail("expected deleteRequiresConfirmation")
        } catch ModelStoreError.deleteRequiresConfirmation {}
        try await store.delete(modelID: "org--a", confirm: true)
        let models = await store.listDownloaded()
        XCTAssertTrue(models.isEmpty)
    }

    func testDeleteClearsActiveModel() async throws {
        try seedModel(id: "org--a", files: ["config.json": "{}"])
        let store = ModelStore(modelsRoot: tempRoot)
        try await store.setActiveModel(id: "org--a")
        try await store.delete(modelID: "org--a", confirm: true)
        let active = await store.activeModelID()
        XCTAssertNil(active)
    }
}

final class SHA256Tests: XCTestCase {
    func testEmptyVector() {
        XCTAssertEqual(SHA256.hexDigest(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testAbcVector() {
        XCTAssertEqual(SHA256.hexDigest(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testLongVector() {
        let text = String(repeating: "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", count: 1)
        XCTAssertEqual(SHA256.hexDigest(Data(text.utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testStreamingMatchesOneShot() {
        // Feed 200 KB in odd-sized chunks through the streaming hasher path.
        let data = Data((0..<200_000).map { UInt8($0 % 256) }
        )
        XCTAssertEqual(SHA256.hexDigest(data), {
            var h = PureSHA256()
            var offset = 0
            while offset < data.count {
                let end = min(offset + 7777, data.count)
                h.update(data.subdata(in: offset..<end))
                offset = end
            }
            return h.finalize().map { String(format: "%02x", $0) }.joined()
        }())
    }

    func testMillionAVector() {
        let data = Data(repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(SHA256.hexDigest(data),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}

final class ContextWindowManagerTests: XCTestCase {
    func testKeepsEverythingUnderBudget() {
        let manager = ContextWindowManager(tokenBudget: 10_000)
        let messages = [
            ChatMessage(role: .system, content: "You are helpful."),
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .assistant, content: "hello")
        ]
        let trimmed = manager.trim(messages)
        XCTAssertEqual(trimmed.count, 3)
    }

    func testTrimsOldMessagesOverBudget() {
        let manager = ContextWindowManager(tokenBudget: 50) // ~200 chars
        var messages = [ChatMessage(role: .system, content: "sys")]
        for i in 0..<20 {
            messages.append(ChatMessage(role: .user, content: "question \(i) " + String(repeating: "x", count: 40)))
        }
        messages.append(ChatMessage(role: .user, content: "latest"))
        let trimmed = manager.trim(messages)
        XCTAssertEqual(trimmed.first?.role, .system)
        XCTAssertEqual(trimmed.last?.content, "latest")
        XCTAssertLessThan(trimmed.count, messages.count)
    }

    func testDroppedToolOutputGetsTruncatedMarker() {
        let manager = ContextWindowManager(tokenBudget: 40)
        let bigToolOutput = String(repeating: "y", count: 1000)
        let messages = [
            ChatMessage(role: .system, content: "s"),
            ChatMessage(role: .tool, content: bigToolOutput),
            ChatMessage(role: .user, content: "ok")
        ]
        let trimmed = manager.trim(messages)
        XCTAssertTrue(trimmed.contains { $0.content == "[truncated]" && $0.role == .tool })
    }

    func testTokenEstimator() {
        let manager = ContextWindowManager(tokenBudget: 100)
        XCTAssertEqual(manager.estimateTokens(String(repeating: "a", count: 400)), 100)
        XCTAssertEqual(manager.estimateTokens(""), 1)
    }
}
