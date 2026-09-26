import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LocalAICore

/// Mock HTTP client: returns canned responses keyed by URL path, records requests.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    struct RecordedRequest {
        let url: URL
        let authorizationHeader: String?
    }
    private let lock = NSLock()
    private var responses: [String: (Int, Data)] = [:]
    private(set) var recorded: [RecordedRequest] = []

    func stub(pathContains substring: String, status: Int, json: String) {
        lock.lock(); defer { lock.unlock() }
        responses[substring] = (status, Data(json.utf8))
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        recorded.append(RecordedRequest(
            url: request.url!,
            authorizationHeader: request.value(forHTTPHeaderField: "Authorization")
        ))
        let match = responses.first { request.url!.absoluteString.contains($0.key) }
        lock.unlock()
        let url = request.url!
        let (status, data) = match?.value ?? (404, Data("{}".utf8))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

final class HuggingFaceClientTests: XCTestCase {
    private func makeClient(_ mock: MockHTTPClient, token: String? = nil) -> HuggingFaceClient {
        HuggingFaceClient(http: mock, token: token)
    }

    func testWhoami() async throws {
        let mock = MockHTTPClient()
        mock.stub(pathContains: "/api/whoami-v2", status: 200, json: #"{"name":"alice","fullname":"Alice A"}"#)
        let client = makeClient(mock, token: "hf_test_token_abcdefghijklmnopqrstuvwxyz")
        let user = try await client.whoami()
        XCTAssertEqual(user.name, "alice")
        XCTAssertEqual(mock.recorded.first?.authorizationHeader, "Bearer hf_test_token_abcdefghijklmnopqrstuvwxyz")
    }

    func testNoAuthorizationHeaderWithoutToken() async throws {
        let mock = MockHTTPClient()
        mock.stub(pathContains: "/api/whoami-v2", status: 200, json: #"{"name":"bob"}"#)
        _ = try await makeClient(mock).whoami()
        XCTAssertNil(mock.recorded.first?.authorizationHeader)
    }

    func testModelInfoParsesSiblings() async throws {
        let mock = MockHTTPClient()
        let json = """
        {
          "id": "org/model-4bit",
          "sha": "abc123",
          "gated": false,
          "pipeline_tag": "text-generation",
          "tags": ["mlx", "text-generation"],
          "library_name": "mlx",
          "config": {"model_type": "qwen3"},
          "siblings": [
            {"rfilename": "config.json", "size": 512},
            {"rfilename": "model.safetensors", "lfs": {"oid": "deadbeef", "size": 4000000000}}
          ]
        }
        """
        mock.stub(pathContains: "/api/models/org/model-4bit/revision/main", status: 200, json: json)
        let client = makeClient(mock)
        let ref = try HFRepoReference.parse("org/model-4bit")
        let info = try await client.modelInfo(repo: ref)
        XCTAssertEqual(info.id, "org/model-4bit")
        XCTAssertEqual(info.modelType, "qwen3")
        XCTAssertEqual(info.pipelineTag, "text-generation")
        XCTAssertTrue(info.tags.contains("mlx"))
        XCTAssertEqual(info.siblings.count, 2)
        XCTAssertEqual(info.siblings[1].size, 4_000_000_000)
        XCTAssertEqual(info.siblings[1].lfsSHA256, "deadbeef")
        XCTAssertFalse(info.gated)
    }

    func test401MapsToSignIn() async throws {
        let mock = MockHTTPClient()
        mock.stub(pathContains: "/api/models/", status: 401, json: #"{"error":"unauthorized"}"#)
        let client = makeClient(mock)
        let ref = try HFRepoReference.parse("org/model")
        do {
            _ = try await client.modelInfo(repo: ref)
            XCTFail("expected error")
        } catch let e as UserFacingError {
            XCTAssertEqual(e.recoveryAction, .signIn)
            XCTAssertFalse(e.developerDetails.contains("hf_"))
        }
    }

    func test403GatedMapsToOpenURL() async throws {
        let mock = MockHTTPClient()
        mock.stub(pathContains: "/api/models/", status: 403, json: #"{"error":"gated"}"#)
        let client = makeClient(mock)
        let ref = try HFRepoReference.parse("org/gated-model")
        do {
            _ = try await client.modelInfo(repo: ref)
            XCTFail("expected error")
        } catch let e as UserFacingError {
            XCTAssertEqual(e.title, "Access required")
            guard case .openURL(let url) = e.recoveryAction else {
                return XCTFail("expected openURL, got \(String(describing: e.recoveryAction))")
            }
            XCTAssertEqual(url.absoluteString, "https://huggingface.co/org/gated-model")
        }
    }

    func testListFiles() async throws {
        let mock = MockHTTPClient()
        let json = """
        {"id": "o/m", "siblings": [{"rfilename": "a.json", "size": 1}, {"rfilename": "b.bin", "size": 2}]}
        """
        mock.stub(pathContains: "/api/models/", status: 200, json: json)
        let files = try await makeClient(mock).listFiles(repo: HFRepoReference.parse("o/m"))
        XCTAssertEqual(files.map(\.path), ["a.json", "b.bin"])
    }
}
