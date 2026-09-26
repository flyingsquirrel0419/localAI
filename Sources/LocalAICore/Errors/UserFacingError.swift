import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A suggested recovery action the UI can surface to the user.
public enum RecoveryAction: Sendable, Equatable {
    case retry
    case resume
    case openURL(URL)
    case signIn
    case dismiss
}

/// A user-presentable error. `developerDetails` is intended for logs/diagnostics
/// and must already be redacted — never put raw tokens in it.
public struct UserFacingError: Error, Sendable, Equatable {
    public let title: String
    public let message: String
    public let recoveryAction: RecoveryAction?
    public let developerDetails: String

    public init(
        title: String,
        message: String,
        recoveryAction: RecoveryAction? = nil,
        developerDetails: String
    ) {
        self.title = title
        self.message = message
        self.recoveryAction = recoveryAction
        self.developerDetails = developerDetails
    }
}

/// Types that can describe themselves as a user-facing error.
public protocol UserFacingErrorConvertible {
    var userFacingError: UserFacingError { get }
}

public enum UserFacingErrorMapper {
    /// Map any error to a UserFacingError. Raw system errors are never shown verbatim.
    public static func map(_ error: Error) -> UserFacingError {
        if let uf = error as? UserFacingError { return uf }
        if let convertible = error as? UserFacingErrorConvertible {
            return convertible.userFacingError
        }
        if let urlError = error as? URLError {
            return map(urlError)
        }
        if let fsError = error as? FileSystemError {
            return map(fsError)
        }
        return UserFacingError(
            title: "Something went wrong",
            message: "An unexpected error occurred. Please try again.",
            recoveryAction: .retry,
            developerDetails: SecretRedactor.redact(String(describing: error))
        )
    }

    public static func map(_ error: URLError) -> UserFacingError {
        let details = SecretRedactor.redact("URLError code=\(error.code.rawValue) \(error.localizedDescription)")
        switch error.code {
        case .notConnectedToInternet:
            return UserFacingError(
                title: "No internet connection",
                message: "You appear to be offline. Connect to the internet and try again.",
                recoveryAction: .retry,
                developerDetails: details
            )
        case .networkConnectionLost:
            return UserFacingError(
                title: "Download interrupted",
                message: "Your network connection was lost. You can resume where it left off.",
                recoveryAction: .resume,
                developerDetails: details
            )
        case .timedOut:
            return UserFacingError(
                title: "Request timed out",
                message: "The server took too long to respond. Try again in a moment.",
                recoveryAction: .retry,
                developerDetails: details
            )
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return UserFacingError(
                title: "Server unreachable",
                message: "We couldn't reach the server. Check your connection and try again.",
                recoveryAction: .retry,
                developerDetails: details
            )
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return UserFacingError(
                title: "Secure connection failed",
                message: "We couldn't establish a secure connection. This can happen on restricted networks.",
                recoveryAction: .retry,
                developerDetails: details
            )
        case .cancelled:
            return UserFacingError(
                title: "Cancelled",
                message: "The operation was cancelled.",
                recoveryAction: .dismiss,
                developerDetails: details
            )
        case .badServerResponse, .cannotParseResponse:
            return UserFacingError(
                title: "Unexpected server response",
                message: "The server returned something we couldn't understand. Please try again later.",
                recoveryAction: .retry,
                developerDetails: details
            )
        case .resourceUnavailable, .fileDoesNotExist:
            return UserFacingError(
                title: "Not found",
                message: "The requested item no longer exists or was moved.",
                recoveryAction: .dismiss,
                developerDetails: details
            )
        default:
            return UserFacingError(
                title: "Network error",
                message: "A network error occurred. Please try again.",
                recoveryAction: .retry,
                developerDetails: details
            )
        }
    }

    public static func map(_ error: FileSystemError) -> UserFacingError {
        switch error {
        case .pathEscapesSandbox(let path):
            return UserFacingError(
                title: "Invalid path",
                message: "That location is outside the workspace and cannot be accessed.",
                recoveryAction: .dismiss,
                developerDetails: "Path escape attempt: \(SecretRedactor.redact(path))"
            )
        case .notFound(let path):
            return UserFacingError(
                title: "File not found",
                message: "\"\(path)\" doesn't exist in this workspace.",
                recoveryAction: .dismiss,
                developerDetails: "notFound: \(path)"
            )
        case .fileTooLarge(let path, let size, let limit):
            return UserFacingError(
                title: "File too large",
                message: "\"\(path)\" is \(size) bytes; the limit is \(limit) bytes.",
                recoveryAction: .dismiss,
                developerDetails: "fileTooLarge size=\(size) limit=\(limit)"
            )
        case .notUTF8(let path):
            return UserFacingError(
                title: "Binary file",
                message: "\"\(path)\" isn't a text file and can't be displayed here.",
                recoveryAction: .dismiss,
                developerDetails: "notUTF8: \(path)"
            )
        default:
            return UserFacingError(
                title: "File operation failed",
                message: "The file operation could not be completed.",
                recoveryAction: .retry,
                developerDetails: SecretRedactor.redact(String(describing: error))
            )
        }
    }
}
