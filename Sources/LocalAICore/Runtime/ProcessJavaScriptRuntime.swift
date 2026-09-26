#if os(macOS) || os(Linux)
import Foundation

/// Locates a node/npm executable. Prefers the conventional /usr/bin path
/// (Linux containers); falls back to a PATH lookup so macOS runners with
/// Homebrew-installed Node (/opt/homebrew/bin, /usr/bin is SIP read-only)
/// work without configuration.
public enum NodePathResolver {
    public static func resolve(_ name: String) -> String {
        let usrBin = "/usr/bin/\(name)"
        if FileManager.default.isExecutableFile(atPath: usrBin) { return usrBin }
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return usrBin // keep the conventional default; launch will fail loudly
    }
}

/// JavaScriptRuntimeService backed by system `node` / `npm` via Process.
/// Streams stdout/stderr, enforces a wall-clock timeout, and kills the child
/// on task cancellation.
public final class ProcessJavaScriptRuntime: JavaScriptRuntimeService, @unchecked Sendable {
    public let nodePath: String
    public let npmPath: String

    public init(nodePath: String = NodePathResolver.resolve("node"),
                npmPath: String = NodePathResolver.resolve("npm")) {
        self.nodePath = nodePath
        self.npmPath = npmPath
    }

    private func resolve(_ command: RuntimeCommand) -> (executable: URL, args: [String]) {
        switch command {
        case .node(let script, let args):
            return (URL(fileURLWithPath: nodePath), [script] + args)
        case .npm(let args):
            return (URL(fileURLWithPath: npmPath), args)
        }
    }

    public func run(
        _ command: RuntimeCommand,
        in directory: URL,
        environment: [String: String],
        timeout: TimeInterval
    ) -> AsyncThrowingStream<RuntimeEvent, Error> {
        let (executable, args) = resolve(command)
        return AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = args
            process.currentDirectoryURL = directory
            var env = ProcessInfo.processInfo.environment
            for (k, v) in environment { env[k] = v }
            env["CI"] = "true"
            env["NO_COLOR"] = "1"
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let started = Date()
            let state = RunState()

            continuation.onTermination = { termination in
                let killed = state.markTerminated()
                if !killed {
                    // Stream ended normally or was cancelled after exit; no-op.
                }
                switch termination {
                case .cancelled:
                    if process.isRunning { process.terminate() }
                default:
                    break
                }
            }

            do {
                try process.run()
            } catch {
                continuation.yield(.stderr(error.localizedDescription))
                continuation.finish(throwing: RuntimeError.launchFailed("\(executable.path): \(error.localizedDescription)"))
                return
            }

            // Timeout watchdog.
            let watchdog = Task.detached {
                guard timeout > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if process.isRunning, !state.wasTerminated {
                    process.terminate()
                    state.markTimedOut()
                }
            }

            // Stream stdout/stderr chunks.
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                continuation.yield(.stdout(text))
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                continuation.yield(.stderr(text))
            }

            let waiter = Task.detached {
                process.waitUntilExit()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                // Drain any buffered remainder.
                let remainingOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: remainingOut, encoding: .utf8), !text.isEmpty {
                    continuation.yield(.stdout(text))
                }
                let remainingErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                if let text = String(data: remainingErr, encoding: .utf8), !text.isEmpty {
                    continuation.yield(.stderr(text))
                }
                watchdog.cancel()
                let duration = Date().timeIntervalSince(started)
                continuation.yield(.exited(code: process.terminationStatus, duration: duration))
                if state.didTimeOut {
                    continuation.finish(throwing: RuntimeError.timedOut(seconds: Int(timeout)))
                } else {
                    continuation.finish()
                }
            }

            state.track(waiter: waiter, watchdog: watchdog)
        }
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var terminated = false
        private var timedOut = false
        private var tasks: [Task<Void, Never>] = []

        var wasTerminated: Bool {
            lock.lock(); defer { lock.unlock() }
            return terminated
        }

        var didTimeOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return timedOut
        }

        @discardableResult
        func markTerminated() -> Bool {
            lock.lock(); defer { lock.unlock() }
            let was = terminated
            terminated = true
            return was
        }

        func markTimedOut() {
            lock.lock(); defer { lock.unlock() }
            timedOut = true
            terminated = true
        }

        func track(waiter: Task<Void, Never>, watchdog: Task<Void, Never>) {
            lock.lock(); defer { lock.unlock() }
            tasks = [waiter, watchdog]
        }
    }
}
#endif
