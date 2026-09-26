import Foundation

/// A parsed Hugging Face model repository reference.
public struct HFRepoReference: Sendable, Equatable, Codable {
    public let organization: String
    public let name: String
    /// Git revision (branch/tag/commit). Defaults to "main".
    public let revision: String
    /// Optional file path when the URL pointed at a blob.
    public let filePath: String?

    public var id: String { "\(organization)/\(name)" }

    /// Canonical huggingface.co page URL for this repository.
    public var pageURL: URL {
        URL(string: "https://huggingface.co/\(id)")!
    }

    public enum ParseError: Error, Equatable, Sendable {
        case empty
        case notARepositoryURL(String)
        /// datasets/spaces URLs are valid HF URLs but not model repos.
        case unsupportedRepoKind(String)
        case missingName
        case invalidCharacters(String)
    }

    /// Accepted forms:
    /// - `https://huggingface.co/org/name` (optionally `/tree/<rev>` or `/blob/<rev>/<file>`)
    /// - `https://hf.co/org/name`
    /// - `org/name`
    public static func parse(_ input: String) throws -> HFRepoReference {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ParseError.empty }

        var path = trimmed
        if trimmed.contains("://") || trimmed.hasPrefix("hf.co/") || trimmed.hasPrefix("www.") {
            guard let url = URL(string: trimmed.hasPrefix("hf.co/") ? "https://" + trimmed : trimmed),
                  let host = url.host?.lowercased() else {
                throw ParseError.notARepositoryURL(trimmed)
            }
            guard host == "huggingface.co" || host == "www.huggingface.co" || host == "hf.co" else {
                throw ParseError.notARepositoryURL(trimmed)
            }
            path = url.path
        }
        // Strip leading/trailing slashes and any query/fragment leftovers.
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        if let f = path.firstIndex(of: "#") { path = String(path[..<f]) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw ParseError.missingName }

        // Reject non-model repo kinds.
        if let first = components.first {
            if first == "datasets" || first == "spaces" {
                throw ParseError.unsupportedRepoKind(first)
            }
        }

        guard components.count >= 2 else { throw ParseError.missingName }
        let org = components[0]
        let name = components[1]
        try validateSegment(org, original: trimmed)
        try validateSegment(name, original: trimmed)

        var revision = "main"
        var filePath: String? = nil
        if components.count >= 4 {
            let marker = components[2]
            if marker == "tree" || marker == "blob" || marker == "resolve" {
                revision = components[3]
                if marker == "blob" || marker == "resolve", components.count > 4 {
                    filePath = components[4...].joined(separator: "/")
                }
            } else {
                throw ParseError.notARepositoryURL(trimmed)
            }
        } else if components.count == 3 {
            throw ParseError.notARepositoryURL(trimmed)
        }
        components = []

        return HFRepoReference(organization: org, name: name, revision: revision, filePath: filePath)
    }

    private static func validateSegment(_ segment: String, original: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        if segment.isEmpty || segment.unicodeScalars.contains(where: { !allowed.contains($0) })
            || segment.hasPrefix(".") || segment.hasPrefix("-") {
            throw ParseError.invalidCharacters(segment)
        }
    }
}
