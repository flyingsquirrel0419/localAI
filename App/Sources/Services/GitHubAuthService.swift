import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import LocalAICore

/// Validates a GitHub personal access token against /user, and implements the
/// OAuth Device Authorization Grant for GitHub Apps / OAuth Apps that have
/// device flow enabled.
public struct GitHubAuthService: Sendable {

    public struct ValidatedUser: Sendable, Equatable {
        public let login: String
        public let name: String?
    }

    public enum AuthError: Error, Equatable, Sendable {
        case invalidToken
        case httpStatus(Int)
        case malformedResponse
        case deviceFlowUnsupported
        case expired
        case authorizationPending
        case slowDown
        case accessDenied
        case networkFailure
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - PAT validation

    /// Validate a PAT by calling GET /user. Throws AuthError.invalidToken on 401.
    public func validatePAT(_ token: String) async throws -> ValidatedUser {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("localai-ios/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.networkFailure }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw AuthError.invalidToken
        default:
            throw AuthError.httpStatus(http.statusCode)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let login = json["login"] as? String else {
            throw AuthError.malformedResponse
        }
        return ValidatedUser(login: login, name: json["name"] as? String)
    }

    /// Best-effort commit-author identity for a token: GET /user, then
    /// `name` (falling back to `login`) + the canonical noreply address.
    /// Returns nil when the token is missing or invalid.
    public func commitAuthor(token: String) async -> GitAuthor? {
        guard let user = try? await validatePAT(token) else { return nil }
        let displayName = (user.name?.isEmpty == false ? user.name! : user.login)
        // GitHub's per-user noreply address — safe to embed in commit headers.
        let email = "\(user.login)@users.noreply.github.com"
        return GitAuthor(name: displayName, email: email)
    }

    // MARK: - Device flow

    public struct DeviceCode: Sendable, Equatable {
        public let deviceCode: String
        public let userCode: String
        public let verificationURL: URL
        public let expiresIn: Int
        public let interval: Int
    }

    public func startDeviceFlow(clientID: String, scope: String = "repo read:user") async throws -> DeviceCode {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(clientID)&scope=\(scope.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? scope)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.deviceFlowUnsupported
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let verificationString = json["verification_uri"] as? String,
              let verificationURL = URL(string: verificationString),
              let expiresIn = json["expires_in"] as? Int,
              let interval = json["interval"] as? Int else {
            throw AuthError.malformedResponse
        }
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            expiresIn: expiresIn,
            interval: interval
        )
    }

    /// Poll until the user authorizes. Returns the access token on success.
    /// Throws AuthError.authorizationPending / .slowDown to signal "keep polling".
    public func pollDeviceFlow(clientID: String, deviceCode: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let bodyFields = [
            "client_id=\(clientID)",
            "device_code=\(deviceCode)",
            "grant_type=urn:ietf:params:oauth:grant-type:device_code"
        ]
        request.httpBody = bodyFields.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.malformedResponse
        }
        if let token = json["access_token"] as? String {
            return token
        }
        switch json["error"] as? String {
        case "authorization_pending": throw AuthError.authorizationPending
        case "slow_down": throw AuthError.slowDown
        case "expired_token": throw AuthError.expired
        case "access_denied": throw AuthError.accessDenied
        default: throw AuthError.malformedResponse
        }
    }
}
