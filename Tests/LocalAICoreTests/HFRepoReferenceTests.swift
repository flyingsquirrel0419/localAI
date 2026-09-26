import XCTest
@testable import LocalAICore

final class HFRepoReferenceTests: XCTestCase {
    func testPlainSlug() throws {
        let ref = try HFRepoReference.parse("mlx-community/Qwen3-4B-4bit")
        XCTAssertEqual(ref.organization, "mlx-community")
        XCTAssertEqual(ref.name, "Qwen3-4B-4bit")
        XCTAssertEqual(ref.revision, "main")
        XCTAssertNil(ref.filePath)
    }

    func testFullURL() throws {
        let ref = try HFRepoReference.parse("https://huggingface.co/org/name")
        XCTAssertEqual(ref.id, "org/name")
        XCTAssertEqual(ref.revision, "main")
    }

    func testTreeURL() throws {
        let ref = try HFRepoReference.parse("https://huggingface.co/org/name/tree/dev")
        XCTAssertEqual(ref.revision, "dev")
        XCTAssertNil(ref.filePath)
    }

    func testBlobURL() throws {
        let ref = try HFRepoReference.parse("https://huggingface.co/org/name/blob/main/config.json")
        XCTAssertEqual(ref.revision, "main")
        XCTAssertEqual(ref.filePath, "config.json")
    }

    func testBlobNestedFile() throws {
        let ref = try HFRepoReference.parse("https://huggingface.co/org/name/blob/main/a/b/c.safetensors")
        XCTAssertEqual(ref.filePath, "a/b/c.safetensors")
    }

    func testShortHost() throws {
        let ref = try HFRepoReference.parse("hf.co/org/name")
        XCTAssertEqual(ref.id, "org/name")
    }

    func testTrailingSlash() throws {
        let ref = try HFRepoReference.parse("https://huggingface.co/org/name/")
        XCTAssertEqual(ref.id, "org/name")
    }

    func testRejectsDatasets() {
        XCTAssertThrowsError(try HFRepoReference.parse("https://huggingface.co/datasets/org/data")) { error in
            guard case HFRepoReference.ParseError.unsupportedRepoKind = error else {
                return XCTFail("expected unsupportedRepoKind, got \(error)")
            }
        }
    }

    func testRejectsSpaces() {
        XCTAssertThrowsError(try HFRepoReference.parse("https://huggingface.co/spaces/org/demo")) { error in
            guard let parseError = error as? HFRepoReference.ParseError,
                  case .unsupportedRepoKind = parseError else {
                return XCTFail("expected unsupportedRepoKind, got \(error)")
            }
        }
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try HFRepoReference.parse(""))
        XCTAssertThrowsError(try HFRepoReference.parse("   "))
        XCTAssertThrowsError(try HFRepoReference.parse("justoneword"))
        XCTAssertThrowsError(try HFRepoReference.parse("https://example.com/org/name"))
        XCTAssertThrowsError(try HFRepoReference.parse("https://huggingface.co/org"))
        XCTAssertThrowsError(try HFRepoReference.parse("https://huggingface.co/org/name/unknown/x"))
    }

    func testPageURL() throws {
        let ref = try HFRepoReference.parse("org/name")
        XCTAssertEqual(ref.pageURL.absoluteString, "https://huggingface.co/org/name")
    }
}
