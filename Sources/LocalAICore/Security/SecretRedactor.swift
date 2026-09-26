import Foundation

/// Redacts known secret token shapes from arbitrary strings before they hit
/// logs, agent transcripts, or error messages.
public enum SecretRedactor {
    /// Patterns for tokens we may handle: Hugging Face, GitHub PATs, OAuth tokens.
    /// Each is matched case-sensitively; the entire match is replaced.
    private static let patterns: [NSRegularExpression] = {
        let raw: [String] = [
            #"\bhf_[A-Za-z0-9]{20,}\b"#,             // Hugging Face user access token
            #"\bghp_[A-Za-z0-9]{30,}\b"#,            // GitHub classic PAT
            #"\bgho_[A-Za-z0-9]{20,}\b"#,            // GitHub OAuth token
            #"\bghu_[A-Za-z0-9]{20,}\b"#,            // GitHub user-to-server
            #"\bghs_[A-Za-z0-9]{20,}\b"#,            // GitHub server-to-server
            #"\bghr_[A-Za-z0-9]{20,}\b"#,            // GitHub refresh
            #"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#,    // GitHub fine-grained PAT
            #"\bsk-[A-Za-z0-9\-_]{20,}\b"#           // OpenAI-style key (defensive)
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    public static let replacement = "[REDACTED]"

    /// Return a copy of `input` with any recognized secret replaced.
    public static func redact(_ input: String) -> String {
        var result = input
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: replacement
            )
        }
        return result
    }

    /// Convenience for redacting a specific known value (e.g. the stored token itself)
    /// in addition to shape-based redaction. Useful when a token doesn't match any shape.
    public static func redact(_ input: String, knownSecrets: [String]) -> String {
        var result = redact(input)
        for secret in knownSecrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: replacement)
        }
        return result
    }
}
