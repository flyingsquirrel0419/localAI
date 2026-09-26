import Foundation
import LocalAICore

#if canImport(NodeMobile)
import NodeMobile
#endif

/// `NodeHostLauncher` that runs Node.js **in-process** via the vendored
/// NodeMobile xcframework (nodejs-mobile v18.20.4).
///
/// Constraints (verified against `nodejs-mobile/doc_mobile/FAQ.md`):
/// - `node_start` may be called ONCE per process; we never re-enter it.
/// - It must run on a dedicated thread with a stack ≥ 2 MB.
/// - argv pointers must reference contiguous memory (libuv requirement) — we
///   pre-pack all argument bytes into a single buffer before calling in.
/// - No `child_process`, no `process.exit`. Our NodeHost `host.js` already
///   respects both — work runs in `worker_threads` inside this one process.
///
/// Port + token: we choose a random free TCP port and a random 32-byte hex
/// token, publish them via `setenv` before `node_start`, then poll `ping`
/// through `NodeHostJavaScriptRuntime` until the host is accepting requests.
public final class NodeMobileLauncher: NodeHostLauncher, @unchecked Sendable {

    public enum Error: Swift.Error, Equatable {
        case alreadyStarted
        case hostScriptMissing
        case pingTimeout(underlying: String)
    }

    /// Whether `node_start` has been invoked on this process. Set once;
    /// consulted before any further start attempt to honour the
    /// once-per-process contract.
    private static var didStartOnProcess = false
    private static let didStartLock = NSLock()

    /// Thread that hosts the long-running Node run loop. Retained for the
    /// lifetime of the process.
    private var nodeThread: Thread?

    /// Resolved at start() so `stop()` knows whether the runtime ever came up.
    private var runtime: NodeHostJavaScriptRuntime?

    public init() {}

    /// Start NodeMobile once per process. Throws on second invocation.
    ///
    /// - Parameters:
    ///   - port: TCP port the NodeHost should bind. Caller picks a free port.
    ///   - token: shared secret the host validates on every request.
    public func start(port: Int, token: String) async throws {
        #if canImport(NodeMobile)
        try Self.markStarted()

        guard let hostScript = Bundle.main.url(
            forResource: "host", withExtension: "js", subdirectory: "NodeHost"
        ) else {
            throw Error.hostScriptMissing
        }

        // Publish connection details via env BEFORE node_start. host.js reads
        // LOCALAI_HOST_PORT / LOCALAI_HOST_TOKEN at module load.
        setenv("LOCALAI_HOST_PORT", String(port), 1)
        setenv("LOCALAI_HOST_TOKEN", token, 1)

        // Start Node on a dedicated thread with a generous stack. libuv and
        // V8 both expect ≥ 1 MB; nodejs-mobile's own test app uses 4 MB and
        // we mirror that (NodeRunner.mm).
        let thread = Thread {
            // argv must reference a contiguous buffer (libuv). Build one
            // heap block holding "node\0<script-path>\0", then walk pointers
            // into it for each argv entry.
            let arguments = ["node", hostScript.path]
            var buffer: [Int8] = []
            buffer.reserveCapacity(arguments.reduce(0) { $0 + $1.utf8.count + 1 })
            for arg in arguments { buffer.append(contentsOf: arg.utf8CString) }
            buffer.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                var argv: [UnsafeMutablePointer<Int8>?] = []
                var offset = 0
                for arg in arguments {
                    let ptr = UnsafeMutablePointer(mutating: base.advanced(by: offset))
                    argv.append(ptr)
                    offset += arg.utf8.count + 1
                }
                var argvStorage = argv
                argvStorage.withUnsafeMutableBufferPointer { argvBuf in
                    _ = node_start(Int32(arguments.count), argvBuf.baseAddress)
                }
            }
            // If node_start ever returns, the runtime has exited. Per the
            // nodejs-mobile FAQ there is no supported restart path — surface
            // this via the runtime's connection errors going forward.
        }
        thread.stackSize = 4 << 20 // 4 MB
        thread.name = "localai.nodemobile"
        thread.start()
        self.nodeThread = thread

        // Wait until the host accepts our ping. Cold start of nodejs-mobile
        // on device is a few hundred ms; give it 10 s to be safe.
        let runtime = NodeHostJavaScriptRuntime(port: port, token: token)
        self.runtime = runtime
        let deadline = Date().addingTimeInterval(10)
        var lastError: Swift.Error = NodeHostRuntimeError.notStarted
        while Date() < deadline {
            do {
                try await runtime.ping()
                return
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw Error.pingTimeout(underlying: String(describing: lastError))
        #else
        // Compiled without NodeMobile (Linux tests, SPM-only builds, missing
        // framework download). Be honest: report unavailable, don't fake it.
        throw NodeHostRuntimeError.hostError(
            "Node runtime is not available in this build."
        )
        #endif
    }

    public func stop() async {
        // NodeMobile offers no supported stop API; the host thread lives for
        // the process. This is a no-op by design, matching the FAQ.
    }

    /// Mark the once-per-process flag. Throws if we already started.
    private static func markStarted() throws {
        didStartLock.lock()
        defer { didStartLock.unlock() }
        if didStartOnProcess { throw Error.alreadyStarted }
        didStartOnProcess = true
    }
}
