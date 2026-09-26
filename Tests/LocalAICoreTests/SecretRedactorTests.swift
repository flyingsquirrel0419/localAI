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
}
