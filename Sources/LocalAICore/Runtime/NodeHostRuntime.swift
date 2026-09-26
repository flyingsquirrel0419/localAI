import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Resolve POSIX calls whose names collide with members (connect/close).
@inline(__always) private func posixConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 {
    #if canImport(Glibc)
    return SwiftGlibc.connect(fd, addr, len)
    #else
    return Darwin.connect(fd, addr, len)
    #endif
}

@inline(__always) private func posixClose(_ fd: Int32) {
    #if canImport(Glibc)
    _ = SwiftGlibc.close(fd)
    #else
    _ = Darwin.close(fd)
    #endif
}

/// Starts a NodeHost instance. On iOS the App implements this with NodeMobile;
/// on macOS/Linux tests use `ProcessNodeHostLauncher` (below) which spawns
/// `node NodeHost/host.js`.
public protocol NodeHostLauncher: Sendable {
    /// Start the host bound to 127.0.0.1:`port` authenticating with `token`.
    /// Must return once the host is accepting connections (or throw).
    func start(port: Int, token: String) async throws
    /// Stop the host. Called when the runtime is no longer needed.
    func stop() async
}

public enum NodeHostRuntimeError: Error, Equatable, Sendable {
    case notStarted
    /// The host rejected our token.
    case unauthorized
    /// Protocol-level error reported by the host.
    case hostError(String)
    /// The socket died mid-command.
    case connectionLost
}

/// JavaScriptRuntimeService client for NodeHost's NDJSON-over-TCP protocol.
///
/// One TCP connection per command (the host speaks request/response per line
/// and interleaves events by id, but separate connections keep backpressure
/// and cancellation simple). Events stream back as `RuntimeEvent` until
/// `exit`, matching `ProcessJavaScriptRuntime` semantics. Cancelling the
/// consuming task sends `{"cmd":"cancel","target":<id>}` on a short-lived
/// control connection; a per-command timeout is forwarded as `timeoutMs` and
/// the host enforces it (exit 124 → `RuntimeError.timedOut`).
public final class NodeHostJavaScriptRuntime: JavaScriptRuntimeService, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let token: String

    public init(port: Int, token: String, host: String = "127.0.0.1") {
        self.host = host
        self.port = port
        self.token = token
    }

    // MARK: - JavaScriptRuntimeService

    public func run(
        _ command: RuntimeCommand,
        in directory: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID().uuidString.lowercased()
            let started = Date()
            let cancelFlag = CancelFlag()

            let cmd: String
            let args: [String]
            switch command {
            case .node(let script, let scriptArgs):
                cmd = "node"
                args = [script] + scriptArgs
            case .npm(let npmArgs):
                cmd = "npm"
                args = npmArgs
            }

            let task = Task { [weak self] in
                guard let self else { return }
                await self.executeCommand(
                    id: id, cmd: cmd, args: args,
                    cwd: directory.path, env: environment,
                    timeoutMs: Int(timeout * 1000),
                    started: started, continuation: continuation
                )
                // The command finished (or errored). Any further cancels are
                // no-ops; mark delivered so the retry loop stops spinning.
                cancelFlag.markDelivered()
            }
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination {
                    cancelFlag.mark()
                    guard let self else { task.cancel(); return }
                    // Send cancel, then retry briefly: if the host hadn't
                    // registered the id yet, the first cancel is a no-op, so
                    // retry until the command task reports it is registered.
                    Task {
                        for _ in 0..<20 {
                            await self.sendCancel(target: id)
                            if cancelFlag.wasDelivered { break }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        task.cancel()
                    }
                    return
                }
                task.cancel()
            }
        }
    }

    /// Shared cancellation marker between onTermination and the command task.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var delivered = false
        var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        var wasDelivered: Bool { lock.lock(); defer { lock.unlock() }; return delivered }
        func mark() { lock.lock(); cancelled = true; lock.unlock() }
        func markDelivered() { lock.lock(); delivered = true; lock.unlock() }
    }

    /// Convenience: verify connectivity and token with a `ping`.
    public func ping() async throws {
        _ = try await roundTrip(cmd: "ping", target: nil)
    }

    private func sendCancel(target: String) async {
        try? await roundTrip(cmd: "cancel", target: target)
    }

    // MARK: - Command plumbing

    private func executeCommand(
        id: String,
        cmd: String,
        args: [String],
        cwd: String,
        env: [String: String],
        timeoutMs: Int,
        started: Date,
        continuation: AsyncThrowingStream<RuntimeEvent, Error>.Continuation
    ) async {
        let socket: LineSocket
        do {
            socket = try LineSocket.open(host: host, port: port)
        } catch {
            continuation.finish(throwing: error)
            return
        }
        defer { socket.close() }

        var request: [String: Any] = [
            "id": id, "token": token, "cmd": cmd,
            "args": args, "cwd": cwd, "env": env
        ]
        if timeoutMs > 0 { request["timeoutMs"] = timeoutMs }

        do {
            try socket.sendJSON(request)
        } catch {
            continuation.finish(throwing: error)
            return
        }

        do {
            for try await line in socket.lines() {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (obj["id"] as? String) == id,
                      let type = obj["type"] as? String
                else { continue }
                switch type {
                case "stdout":
                    if let d = obj["data"] as? String { continuation.yield(.stdout(d)) }
                case "stderr":
                    if let d = obj["data"] as? String { continuation.yield(.stderr(d)) }
                case "exit":
                    let code = Int32((obj["code"] as? Int) ?? -1)
                    let durationMs = (obj["durationMs"] as? Int)
                        .map { TimeInterval($0) / 1000 }
                        ?? Date().timeIntervalSince(started)
                    continuation.yield(.exited(code: code, duration: durationMs))
                    if timeoutMs > 0 && code == 124 {
                        continuation.finish(throwing: RuntimeError.timedOut(seconds: timeoutMs / 1000))
                    } else {
                        continuation.finish()
                    }
                    return
                case "error":
                    let message = (obj["message"] as? String) ?? "unknown host error"
                    if message == "unauthorized" {
                        continuation.finish(throwing: NodeHostRuntimeError.unauthorized)
                    } else {
                        continuation.finish(throwing: NodeHostRuntimeError.hostError(message))
                    }
                    return
                default:
                    continue
                }
            }
            continuation.finish(throwing: NodeHostRuntimeError.connectionLost)
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Open a short-lived connection, send one control command, return the
    /// first reply line for it.
    private func roundTrip(cmd: String, target: String?) async throws -> [String: Any] {
        let socket = try LineSocket.open(host: host, port: port)
        defer { socket.close() }
        let id = UUID().uuidString.lowercased()
        var request: [String: Any] = ["id": id, "token": token, "cmd": cmd]
        if let target { request["target"] = target }
        try socket.sendJSON(request)
        var iterator = socket.lines().makeAsyncIterator()
        while let line = try await iterator.next() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (obj["id"] as? String) == id
            else { continue }
            if let type = obj["type"] as? String, type == "error" {
                let message = (obj["message"] as? String) ?? "host error"
                if message == "unauthorized" { throw NodeHostRuntimeError.unauthorized }
                throw NodeHostRuntimeError.hostError(message)
            }
            return obj
        }
        throw NodeHostRuntimeError.connectionLost
    }
}

// MARK: - LineSocket

/// Minimal blocking POSIX TCP client with line-oriented reads. Reads run on a
/// dedicated DispatchQueue and are bridged into an AsyncThrowingStream.
/// Works on Linux (Glibc) and Apple (Darwin) — iOS 17 included.
final class LineSocket: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var isOpenFlag = true

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return isOpenFlag
    }

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func open(host: String, port: Int) throws -> LineSocket {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        #if canImport(Glibc)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let info = result else {
            throw NodeHostRuntimeError.hostError("getaddrinfo \(host) failed: \(status)")
        }
        defer { freeaddrinfo(result) }
        let descriptor = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard descriptor >= 0 else {
            throw NodeHostRuntimeError.hostError("socket() failed: errno \(errno)")
        }
        #if canImport(Darwin)
        // Darwin has no MSG_NOSIGNAL; suppress SIGPIPE on this socket instead.
        var one: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        if posixConnect(descriptor, info.pointee.ai_addr, info.pointee.ai_addrlen) != 0 {
            let e = errno
            posixClose(descriptor)
            throw NodeHostRuntimeError.hostError("connect \(host):\(port) failed: errno \(e)")
        }
        return LineSocket(descriptor: descriptor)
    }

    func sendJSON(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var line = String(decoding: data, as: UTF8.self)
        line.append("\n")
        try write(line)
    }

    private func write(_ text: String) throws {
        let bytes = Array(text.utf8)
        try bytes.withUnsafeBytes { ptr in
            var written = 0
            while written < bytes.count {
                #if canImport(Glibc)
                let flags = MSG_NOSIGNAL
                #else
                let flags: Int32 = 0 // SO_NOSIGPIPE set at open() time on Darwin
                #endif
                let n = send(descriptor, ptr.baseAddress!.advanced(by: written), bytes.count - written, flags)
                if n < 0 {
                    if errno == EINTR { continue }
                    markClosed()
                    throw NodeHostRuntimeError.connectionLost
                }
                written += n
            }
        }
    }

    /// Stream of newline-delimited lines. Reading happens on a background
    /// queue; the stream finishes when the peer closes, errors, or the stream
    /// is cancelled (which also closes the socket).
    func lines() -> AsyncThrowingStream<String, Error> {
        let descriptor = self.descriptor
        return AsyncThrowingStream { continuation in
            let queue = DispatchQueue(label: "localai.nodehost.linesocket.\(descriptor)")
            queue.async { [weak self] in
                guard let self else { continuation.finish(); return }
                var pending = Data()
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = chunk.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, $0.count, 0) }
                    if n == 0 { break } // orderly shutdown
                    if n < 0 {
                        if errno == EINTR { continue }
                        // EBADF/ECONNRESET after close() — treat as end.
                        self.markClosed()
                        continuation.finish()
                        return
                    }
                    pending.append(contentsOf: chunk[0..<n])
                    // Scan for complete lines using explicit indices — avoid
                    // Data subscripting while mutating, which can crash.
                    var searchFrom = pending.startIndex
                    while searchFrom < pending.endIndex,
                          let nl = pending[searchFrom...].firstIndex(of: 0x0A) {
                        let lineData = pending[pending.startIndex..<nl]
                        pending = pending.subdata(in: pending.index(after: nl)..<pending.endIndex)
                        searchFrom = pending.startIndex
                        if !lineData.isEmpty,
                           let line = String(data: lineData, encoding: .utf8) {
                            continuation.yield(line)
                        }
                    }
                }
                self.markClosed()
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                self?.close()
            }
        }
    }

    private func markClosed() {
        lock.lock(); isOpenFlag = false; lock.unlock()
    }

    func close() {
        lock.lock()
        guard isOpenFlag else { lock.unlock(); return }
        isOpenFlag = false
        lock.unlock()
        shutdown(descriptor, Int32(SHUT_RDWR))
        posixClose(descriptor)
    }

    deinit { close() }
}

#if os(macOS) || os(Linux)
/// Development/test launcher: spawns `node NodeHost/host.js` as a subprocess
/// and waits until `ping` succeeds. Not available on iOS — there the App
/// starts NodeMobile instead.
public final class ProcessNodeHostLauncher: NodeHostLauncher, @unchecked Sendable {
    private let hostScript: URL
    private let nodePath: String
    private var process: Process?
    private let lock = NSLock()

    public init(hostScript: URL, nodePath: String = "/usr/bin/node") {
        self.hostScript = hostScript
        self.nodePath = nodePath
    }

    public func start(port: Int, token: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = [hostScript.path]
        var env = ProcessInfo.processInfo.environment
        env["LOCALAI_HOST_PORT"] = String(port)
        env["LOCALAI_HOST_TOKEN"] = token
        process.environment = env
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        lock.lock()
        self.process = process
        lock.unlock()

        let runtime = NodeHostJavaScriptRuntime(port: port, token: token)
        let deadline = Date().addingTimeInterval(10)
        var lastError: Error = NodeHostRuntimeError.notStarted
        while Date() < deadline {
            do {
                try await runtime.ping()
                return
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await stop()
        throw lastError
    }

    public func stop() async {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}
#endif
