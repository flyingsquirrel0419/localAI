import XCTest
@testable import LocalAICore

final class ModelCompatibilityTests: XCTestCase {
    private func info(
        id: String = "mlx-community/Qwen3-4B-4bit",
        tags: [String] = ["mlx"],
        library: String? = "mlx",
        modelType: String? = "qwen3",
        siblings: [HFSibling]
    ) -> HFModelInfo {
        HFModelInfo(id: id, sha: nil, gated: false, pipelineTag: "text-generation",
                    tags: tags, libraryName: library, modelType: modelType, siblings: siblings)
    }

    func testMLXFormatFromTags() {
        let i = info(siblings: [HFSibling(path: "config.json", size: 100, lfsSHA256: nil)])
        XCTAssertEqual(ModelCompatibility.detectFormat(info: i), .mlx)
    }

    func testMLXFormatFromSafetensors() {
        let i = info(tags: [], library: nil,
                     siblings: [HFSibling(path: "model.safetensors", size: 10, lfsSHA256: nil)])
        XCTAssertEqual(ModelCompatibility.detectFormat(info: i), .mlx)
    }

    func testGGUFFormat() {
        let i = info(tags: [], library: nil,
                     siblings: [HFSibling(path: "model-q4.gguf", size: 10, lfsSHA256: nil)])
        XCTAssertEqual(ModelCompatibility.detectFormat(info: i), .gguf)
    }

    func testGGUFUnsupportedVerdict() {
        let i = info(tags: [], library: nil,
                     siblings: [HFSibling(path: "model-q4.gguf", size: 1000, lfsSHA256: nil)])
        let report = ModelCompatibility.evaluate(info: i, deviceRAMBytes: 16_000_000_000,
                                                 availableStorageBytes: 50_000_000_000)
        guard case .unsupportedFormat = report.verdict else {
            return XCTFail("expected unsupportedFormat, got \(report.verdict)")
        }
    }

    func testQuantizationHeuristics() {
        XCTAssertEqual(ModelCompatibility.detectQuantizationBits(info: info(id: "o/m-4bit", siblings: [])), 4)
        XCTAssertEqual(ModelCompatibility.detectQuantizationBits(info: info(id: "o/m-8bit", siblings: [])), 8)
        XCTAssertEqual(ModelCompatibility.detectQuantizationBits(info: info(id: "o/m-bf16", siblings: [])), 16)
        XCTAssertNil(ModelCompatibility.detectQuantizationBits(info: info(id: "o/m-plain", siblings: [])))
    }

    func testParameterCountHeuristic() {
        XCTAssertEqual(ModelCompatibility.detectParameterCount(info: info(id: "o/Qwen3-4B-4bit", siblings: [])), 4.0)
        XCTAssertEqual(ModelCompatibility.detectParameterCount(info: info(id: "o/tiny-0.5B", siblings: [])), 0.5)
        XCTAssertEqual(ModelCompatibility.detectParameterCount(info: info(id: "o/m-1.5b-instruct", siblings: [])), 1.5)
        XCTAssertNil(ModelCompatibility.detectParameterCount(info: info(id: "o/model", siblings: [])))
    }

    func testNeededFilesSkipNonEssentials() {
        let i = info(siblings: [
            HFSibling(path: "model.safetensors", size: 100, lfsSHA256: nil),
            HFSibling(path: "config.json", size: 10, lfsSHA256: nil),
            HFSibling(path: "tokenizer.json", size: 10, lfsSHA256: nil),
            HFSibling(path: "chat_template.jinja", size: 5, lfsSHA256: nil),
            HFSibling(path: "README.md", size: 9999, lfsSHA256: nil),
            HFSibling(path: ".gitattributes", size: 50, lfsSHA256: nil),
            HFSibling(path: "demo.png", size: 9999, lfsSHA256: nil)
        ])
        let paths = ModelCompatibility.neededFiles(info: i, format: .mlx).map(\.path)
        XCTAssertTrue(paths.contains("model.safetensors"))
        XCTAssertTrue(paths.contains("config.json"))
        XCTAssertFalse(paths.contains("README.md"))
        XCTAssertFalse(paths.contains(".gitattributes"))
        XCTAssertFalse(paths.contains("demo.png"))
    }

    func testCompatibleVerdict() {
        let i = info(siblings: [HFSibling(path: "model.safetensors", size: 2_000_000_000, lfsSHA256: nil)])
        let report = ModelCompatibility.evaluate(info: i, deviceRAMBytes: 16_000_000_000,
                                                 availableStorageBytes: 50_000_000_000)
        guard case .compatible = report.verdict else {
            return XCTFail("expected compatible, got \(report.verdict)")
        }
        XCTAssertEqual(report.downloadBytes, 2_000_000_000)
        XCTAssertEqual(report.estimatedMemoryBytes, Int64(2_000_000_000.0 * 1.2) + 512 * 1024 * 1024)
    }

    func testMayNotRunReliablyWhenOverSixtyPercent() {
        // 8 GB device; 60% = 4.8 GB. A 4.5 GB download -> est ~5.9 GB -> warning.
        let i = info(siblings: [HFSibling(path: "model.safetensors", size: 4_500_000_000, lfsSHA256: nil)])
        let report = ModelCompatibility.evaluate(info: i, deviceRAMBytes: 8_000_000_000,
                                                 availableStorageBytes: 50_000_000_000)
        guard case .mayNotRunReliably = report.verdict else {
            return XCTFail("expected mayNotRunReliably, got \(report.verdict)")
        }
    }

    func testInsufficientStorage() {
        let i = info(siblings: [HFSibling(path: "model.safetensors", size: 5_000_000_000, lfsSHA256: nil)])
        let report = ModelCompatibility.evaluate(info: i, deviceRAMBytes: 64_000_000_000,
                                                 availableStorageBytes: 1_000_000_000)
        guard case .insufficientStorage(let needed, let available) = report.verdict else {
            return XCTFail("expected insufficientStorage, got \(report.verdict)")
        }
        XCTAssertEqual(needed, 5_000_000_000)
        XCTAssertEqual(available, 1_000_000_000)
    }
}
