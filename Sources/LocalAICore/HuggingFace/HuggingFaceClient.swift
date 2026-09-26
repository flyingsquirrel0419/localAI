import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP abstraction so tests can inject a mock.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HuggingFaceError.unexpectedResponse
        }
        return (data, http)
    }
}

public enum HuggingFaceError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case unexpectedResponse
    case malformedJSON(String)
}

public struct HFSibling: Sendable, Equatable, Codable {
    public let path: String
    /// Byte size, present when the API is queried with `blobs=true`.
    public let size: Int?
    /// LFS SHA-256 (nil for small non-LFS files).
    public let lfsSHA256: String?
}

public struct HFModelInfo: Sendable, Equatable {
    public let id: String
    public let sha: String?
    public let gated: Bool
    public let pipelineTag: String?
    public let tags: [String]
    public let libraryName: String?
    public let modelType: String?
    public let siblings: [HFSibling]
}

public struct HFUser: Sendable, Equatable {
    public let name: String
    public let fullname: String?
}

/// Hugging Face Hub API client. The bearer token is attached to requests when
/// present and is never logged or included in error details.
public struct HuggingFaceClient: Sendable {
    public static let apiBase = "https://huggingface.co"

    private let http: HTTPClient
    private let token: String?

    public init(http: HTTPClient = URLSessionHTTPClient(), token: String? = nil) {
        self.http = http
        self.token = token
    }

    public func withToken(_ token: String?) -> HuggingFaceClient {
        HuggingFaceClient(http: http, token: token)
    }

    // MARK: - API

    /// GET /api/whoami-v2 — validates a token.
    public func whoami() async throws -> HFUser {
        let (data, response) = try await send(path: "/api/whoami-v2")
        try checkStatus(response, repo: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String else {
            throw HuggingFaceError.malformedJSON("whoami")
        }
        return HFUser(name: name, fullname: json["fullname"] as? String)
    }

    /// GET /api/models/{repo}/revision/{rev}?blobs=true
    public func modelInfo(repo: HFRepoReference) async throws -> HFModelInfo {
        let encoded = repo.id.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        let rev = repo.revision.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo.revision
        let path = "/api/models/\(encoded)/revision/\(rev)?blobs=true"
        let (data, response) = try await send(path: path)
        try checkStatus(response, repo: repo)
        return try Self.parseModelInfo(data)
    }

    /// File listing for a model repo (uses modelInfo siblings).
    public func listFiles(repo: HFRepoReference) async throws -> [HFSibling] {
        try await modelInfo(repo: repo).siblings
    }

    // MARK: - Internals

    private func send(path: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: Self.apiBase + path) else {
            throw HuggingFaceError.unexpectedResponse
        }
        var request = URLRequest(url: url)
        request.setValue("localai-ios/1.0", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await http.data(for: request)
    }

    private func checkStatus(_ response: HTTPURLResponse, repo: HFRepoReference?) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw UserFacingError(
                title: "Sign in required",
                message: "Your Hugging Face token is missing or expired. Sign in again to continue.",
                recoveryAction: .signIn,
                developerDetails: "GET \(repo?.id ?? "whoami") returned 401"
            )
        case 403:
            let page = repo?.pageURL ?? URL(string: Self.apiBase)!
            throw UserFacingError(
                title: "Access required",
                message: "This model requires permission from its Hugging Face page.",
                recoveryAction: .openURL(page),
                developerDetails: "GET \(repo?.id ?? "") returned 403 (gated)"
            )
        default:
            throw HuggingFaceError.httpStatus(response.statusCode)
        }
    }

    static func parseModelInfo(_ data: Data) throws -> HFModelInfo {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String ?? json["modelId"] as? String else {
            throw HuggingFaceError.malformedJSON("modelInfo")
        }
        var siblings: [HFSibling] = []
        if let rawSiblings = json["siblings"] as? [[String: Any]] {
            for s in rawSiblings {
                guard let path = s["rfilename"] as? String else { continue }
                var size: Int? = nil
                var sha: String? = nil
                if let n = s["size"] as? NSNumber { size = n.intValue }
                if let lfs = s["lfs"] as? [String: Any] {
                    if let n = lfs["size"] as? NSNumber { size = n.intValue }
                    sha = lfs["oid"] as? String
                }
                siblings.append(HFSibling(path: path, size: size, lfsSHA256: sha))
            }
        }
        let gated: Bool
        if let g = json["gated"] as? Bool {
            gated = g
        } else if let g = json["gated"] as? String {
            gated = g != "false"
        } else {
            gated = false
        }
        let config = json["config"] as? [String: Any]
        return HFModelInfo(
            id: id,
            sha: json["sha"] as? String,
            gated: gated,
            pipelineTag: json["pipeline_tag"] as? String ?? json["pipelineTag"] as? String,
            tags: (json["tags"] as? [String]) ?? [],
            libraryName: json["library_name"] as? String ?? json["libraryName"] as? String,
            modelType: config?["model_type"] as? String,
            siblings: siblings
        )
    }
}
