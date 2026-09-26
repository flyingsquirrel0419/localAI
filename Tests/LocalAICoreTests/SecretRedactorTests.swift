import XCTest
@testable import LocalAICore

final class SecretRedactorTests: XCTestCase {
    func testRedactsHuggingFaceToken() {
        let token = "hf_AbCdEfGhIjKlMnOpQrStUvWxYz123456"
        let input = "Authorization: Bearer \(token) failed"
        let out = SecretRedactor.redact(input)
        XCTAssertFalse(out.contains(token))
        XCTAssertTrue(out.contains(SecretRedactor.replacement))
    }

    func testRedactsGitHubTokens() {
        let cases = [
            "ghp_" + String(repeating: "a1", count: 20),
            "gho_" + String(repeating: "b2", count: 15),
            "github_pat_" + String(repeating: "X9_", count: 12)
        ]
        for token in cases {
            let out = SecretRedactor.redact("token is \(token) ok")
            XCTAssertFalse(out.contains(token), "should redact \(token)")
        }
    }

    func testLeavesOrdinaryTextAlone() {
        let input = "cloned repository https://github.com/user/repo on branch main"
        XCTAssertEqual(SecretRedactor.redact(input), input)
    }

    func testDoesNotRedactShortLookalikes() {
        // Too short to be a real token — should not be touched.
        let input = "hf_short and ghp_alsoShort"
        XCTAssertEqual(SecretRedactor.redact(input), input)
    }

    func testKnownSecretsRedaction() {
        let weird = "totally-nonstandard-secret-value"
        let input = "error: server rejected \(weird)"
        let out = SecretRedactor.redact(input, knownSecrets: [weird])
        XCTAssertFalse(out.contains(weird))
    }

    func testMultipleTokensInOneString() {
        let hf = "hf_" + String(repeating: "q7", count: 18)
        let gh = "ghp_" + String(repeating: "z3", count: 18)
        let out = SecretRedactor.redact("hf=\(hf) gh=\(gh)")
        XCTAssertFalse(out.contains(hf))
        XCTAssertFalse(out.contains(gh))
    }

    func testRedactsGitLabToken() {
        let token = "glpat-abcdefghijklmnopqrstuv"
        let out = SecretRedactor.redact("gitlab token: \(token)")
        XCTAssertFalse(out.contains(token))
        XCTAssertTrue(out.contains(SecretRedactor.replacement))
    }

    func testRedactsURLUserInfo() {
        let input = "remote: https://user:ghp_abcdefghijklmnopqrs1234567890@github.com/org/repo"
        let out = SecretRedactor.redact(input)
        XCTAssertFalse(out.contains("user:ghp_"))
        XCTAssertFalse(out.contains("ghp_abcdefghijklmnopqrs1234567890"))
    }

    func testRedacts40HexAfterAuthorizationLabel() {
        let hex = String(repeating: "ab", count: 20) // 40 hex chars
        let input = "Authorization: Bearer \(hex)"
        let out = SecretRedactor.redact(input)
        XCTAssertFalse(out.contains(hex))
    }

    func testLeavesBare40HexAlone() {
        // Without an "authorization"/"token"/"bearer" label a 40-hex string
        // could just be a git SHA — must not be redacted.
        let hex = String(repeating: "cd", count: 20)
        let input = "HEAD is at \(hex)"
        XCTAssertEqual(SecretRedactor.redact(input), input)
    }
}
