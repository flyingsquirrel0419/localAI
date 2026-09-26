import Foundation
import LocalAICore
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Security)
import Security
#endif

/// Owns the app's in-process Node runtime. Singleton-per-process semantics
/// are enforced by `NodeMobileLauncher` itself; this coordinator picks the
/// port and token, starts the launcher, and exposes a ready-to-use
/// `JavaScriptRuntimeService` for the agent.
///
/// Why a separate type: the App layer needs something it can call from
/// `init()` and from SwiftUI `task` modifiers without knowing about ports,
/// tokens, or the launcher's start-once contract.
@MainActor
public final class NodeRuntimeCoordinator: ObservableObject {

    public enum State: Equatable {
        case idle
        case starting
        case ready(port: Int)
        case unavailable(reason: String)
    }

    @Published public private(set) var state: State = .idle

    private let launcher: NodeHostLauncher
    /// Token is generated once per process; regenerated on relaunch.
    private let token: String

    public init(launcher: NodeHostLauncher) {
        self.launcher = launcher
        self.token = Self.generateToken()
    }

    /// Start the runtime if it isn't already running. Safe to call repeatedly;
    /// subsequent calls await the existing start.
    public func ensureStarted() async {
        switch state {
        case .ready, .starting, .unavailable:
            return
        case .idle:
            break
        }
        state = .starting
        let port = Self.findFreePort()
        do {
            try await launcher.start(port: port, token: token)
            state = .ready(port: port)
        } catch {
            state = .unavailable(reason: UserFacingErrorMapper.map(error).message)
        }
    }

    /// A runtime bound to the running host, or nil if it hasn't started.
    public func makeRuntime() -> (any JavaScriptRuntimeService)? {
        guard case .ready(let port) = state else { return nil }
        return NodeHostJavaScriptRuntime(port: port, token: token)
    }

    // MARK: - Helpers

    /// 32 bytes of cryptographic randomness rendered as lowercase hex.
    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytesCompat(&bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Bind a socket to port 0 to learn a free port, then close it.
    /// Race-y (the OS may hand the port out between close and use) but the
    /// NodeHost retries internally if its bind fails.
    static func findFreePort() -> Int {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 38_000 }
        defer { _ = Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0)
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return 38_000 }
        var out = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &out) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &len)
            }
        }
        guard nameResult == 0 else { return 38_000 }
        return Int(UInt16(bigEndian: out.sin_port))
        #else
        return 38_000
        #endif
    }
}

/// Thin wrapper so the coordinator compiles on Linux tests too (Security
/// framework is iOS-only; on Linux the SecRandom path is a stub and we fall
/// back to /dev/urandom via `SystemRandomNumberGenerator`).
private func SecRandomCopyBytesCompat(_ bytes: inout [UInt8]) -> Int32 {
    #if canImport(Security)
    return bytes.withUnsafeMutableBytes { ptr in
        SecRandomCopyBytes(kSecRandomDefault, bytes.count, ptr.baseAddress!)
    }
    #else
    var generator = SystemRandomNumberGenerator()
    for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &generator) }
    return 0
    #endif
}
