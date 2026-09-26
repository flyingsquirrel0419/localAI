import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LocalAICore

final class UserFacingErrorMapperTests: XCTestCase {
    func testNetworkConnectionLostMapsToResume() {
        let err = URLError(.networkConnectionLost)
        let uf = UserFacingErrorMapper.map(err)
        XCTAssertEqual(uf.title, "Download interrupted")
        XCTAssertEqual(uf.recoveryAction, .resume)
    }

    func testNotConnectedMapsToRetry() {
        let uf = UserFacingErrorMapper.map(URLError(.notConnectedToInternet))
        XCTAssertEqual(uf.title, "No internet connection")
        XCTAssertEqual(uf.recoveryAction, .retry)
    }

    func testTimeoutMapsToRetry() {
        let uf = UserFacingErrorMapper.map(URLError(.timedOut))
        XCTAssertEqual(uf.recoveryAction, .retry)
    }

    func testCancelledMapsToDismiss() {
        let uf = UserFacingErrorMapper.map(URLError(.cancelled))
        XCTAssertEqual(uf.recoveryAction, .dismiss)
    }

    func testCertificateErrorMapsToSecureConnectionFailed() {
        let uf = UserFacingErrorMapper.map(URLError(.serverCertificateUntrusted))
        XCTAssertEqual(uf.title, "Secure connection failed")
    }

    func testUnknownErrorGetsGenericMessage() {
        struct Weird: Error {}
        let uf = UserFacingErrorMapper.map(Weird())
        XCTAssertEqual(uf.title, "Something went wrong")
        XCTAssertFalse(uf.developerDetails.isEmpty)
    }

    func testFileSystemErrorMapping() {
        let uf = UserFacingErrorMapper.map(FileSystemError.pathEscapesSandbox("../evil"))
        XCTAssertEqual(uf.title, "Invalid path")
    }

    func testUserFacingErrorPassesThrough() {
        let original = UserFacingError(
            title: "Custom",
            message: "custom message",
            recoveryAction: .signIn,
            developerDetails: "details"
        )
        let mapped = UserFacingErrorMapper.map(original)
        XCTAssertEqual(mapped, original)
    }

    func testDeveloperDetailsAreRedacted() {
        // Construct an error whose description embeds a token and ensure mapping redacts it.
        struct TokenError: Error, CustomStringConvertible {
            var description: String { "failed with hf_" + String(repeating: "aB", count: 20) }
        }
        let uf = UserFacingErrorMapper.map(TokenError())
        XCTAssertFalse(uf.developerDetails.contains("hf_" + String(repeating: "aB", count: 20)))
        XCTAssertTrue(uf.developerDetails.contains(SecretRedactor.replacement))
    }
}
