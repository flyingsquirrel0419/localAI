import XCTest
@testable import LocalAICore

final class CredentialStoreTests: XCTestCase {
    func testInMemorySetGetDelete() throws {
        let store = InMemoryCredentialStore()
        XCTAssertNil(try store.get(.huggingFaceToken))

        try store.set("hf_abc123", for: .huggingFaceToken)
        try store.set("ghp_xyz789", for: .githubToken)
        XCTAssertEqual(try store.get(.huggingFaceToken), "hf_abc123")
        XCTAssertEqual(try store.get(.githubToken), "ghp_xyz789")

        try store.set("hf_new", for: .huggingFaceToken) // overwrite
        XCTAssertEqual(try store.get(.huggingFaceToken), "hf_new")

        try store.delete(.huggingFaceToken)
        XCTAssertNil(try store.get(.huggingFaceToken))
        XCTAssertEqual(try store.get(.githubToken), "ghp_xyz789")

        try store.delete(.huggingFaceToken) // delete missing: no throw
    }

    func testAllKeysIndependent() throws {
        let store = InMemoryCredentialStore()
        for key in CredentialKey.allCases {
            try store.set("value-\(key.rawValue)", for: key)
        }
        for key in CredentialKey.allCases {
            XCTAssertEqual(try store.get(key), "value-\(key.rawValue)")
        }
    }
}
