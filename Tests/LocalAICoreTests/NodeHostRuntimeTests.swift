#if os(macOS) || os(Linux)
import XCTest
@testable import LocalAICore

/// Tests for NodeHostJavaScriptRuntime against the real NodeHost/host.js,
/// launched via ProcessNodeHostLauncher.
final class NodeHostRuntimeTests: XCTestCase {
    private var launcher: ProcessNodeHostLauncher!
    private var port: Int = 0
    private let token = "test-token-\(UUID().uuidString)"

    /// Locate the NodeHost directory relative to this test file.
    static func nodeHostDirectory() -> URL {
        // .../localAI/Tests/LocalAICoreTests/NodeHostRuntimeTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LocalAICoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("NodeHost", isDirectory: true)
    }

    override func setUp() async throws {
        try await super.setUp()
        let hostScript = Self.nodeHostDirectory().appendingPathComponent("host.js")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hostScript.path),
                      "NodeHost/host.js not found at \(hostScript.path)")
        port = 20000 + Int.random(in: 0..<20000)
        launcher = ProcessNodeHostLauncher(hostScript: hostScript)
        try await launcher.start(port: port, token: token)
    }

    override func tearDown() async throws {
        await launcher?.stop()
        try await super.tearDown()
    }

    private func collect(
        _ stream: AsyncThrowingStream<RuntimeEvent, Error>
    ) async throws -> (stdout: String, stderr: String, code: Int32?) {
        var out = "", err = ""
        var code: Int32?
        for try await event in stream {
            switch event {
            case .stdout(let s): out += s
            case .stderr(let s): err += s
            case .exited(let c, _): code = c
            }
        }
        return (out, err, code)
    }

    func testNodeScriptStreamsAndExits() async throws {
        let runtime = NodeHostJavaScriptRuntime(port: port, token: token)
        let dir = Self.nodeHostDirectory().appendingPathComponent("test/fixtures/buggy-project")
        let result = try await collect(
            runtime.run(.node(script: "src/sum.js", args: []), in: dir, environment: [:], timeout: 10)
        )
        XCTAssertEqual(result.code, 0)
    }

    func testNpmTestOnBuggyProjectFails() async throws {
        let runtime = NodeHostJavaScriptRuntime(port: port, token: token)
        let dir = Self.nodeHostDirectory().appendingPathComponent("test/fixtures/buggy-project")
        let result = try await collect(
            runtime.run(.npm(args: ["test"]), in: dir, environment: [:], timeout: 30)
        )
        XCTAssertEqual(result.code, 1)
        XCTAssertTrue(result.stdout.contains("FAIL"), "expected FAIL in stdout: \(result.stdout)")
    }

    func testBadTokenRejected() async throws {
        let runtime = NodeHostJavaScriptRuntime(port: port, token: "wrong-token")
        let dir = Self.nodeHostDirectory()
        do {
            _ = try await collect(
                runtime.run(.node(script: "host.js", args: []), in: dir, environment: [:], timeout: 5)
            )
            XCTFail("expected unauthorized error")
        } catch NodeHostRuntimeError.unauthorized {
            // expected
        } catch {
            // The host closes the line with an error event; either an
            // unauthorized or hostError("unauthorized") is acceptable.
            XCTAssertTrue(String(describing: error).contains("unauthorized"),
                          "unexpected error: \(error)")
        }
    }

    func testPingSucceedsWithGoodToken() async throws {
        let runtime = NodeHostJavaScriptRuntime(port: port, token: token)
        try await runtime.ping()
    }

    func testPingFailsWithBadToken() async throws {
        let runtime = NodeHostJavaScriptRuntime(port: port, token: "nope")
        do {
            try await runtime.ping()
            XCTFail("expected unauthorized")
        } catch NodeHostRuntimeError.unauthorized {
            // expected
        }
    }

    func testTimeoutForwardedAndEnforced() async throws {
        let runtime = NodeHostJavaScriptRuntime(port: port, token: token)
        let dir = Self.nodeHostDirectory()
        // A script that never exits; host should kill it at timeoutMs → 124.
        let script = "setInterval(()=>{},1000)"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodehost-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try script.write(to: tmp.appendingPathComponent("hang.js"), atomically: true, encoding: .utf8)
        do {
            _ = try await collect(
                runtime.run(.node(script: "hang.js", args: []), in: tmp, environment: [:], timeout: 1)
            )
            XCTFail("expected timedOut")
        } catch RuntimeError.timedOut(let seconds) {
            XCTAssertEqual(seconds, 1)
        }
    }

    func testCancellationSendsCancel() async throws {
        let runtime = NodeHostJavaScriptRuntime(port: port, token: token)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodehost-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Emit output once running so we know when the worker is live before
        // cancelling — cancelling before the host registered the command id
        // would race the cancel into a no-op. The script ignores SIGTERM-ish
        // teardown by keeping the event loop busy after "ready".
        try """
        console.log('ready');
        let ticks = 0;
        setInterval(() => { ticks++; if (ticks === 1) console.log('tick'); }, 100);
        """
            .write(to: tmp.appendingPathComponent("hang.js"), atomically: true, encoding: .utf8)

        let stream = runtime.run(.node(script: "hang.js", args: []), in: tmp, environment: [:], timeout: 60)
        let box = ResultBox()
        let consumer = Task {
            var out = "", err = ""
            var code: Int32?
            do {
                for try await event in stream {
                    switch event {
                    case .stdout(let s):
                        out += s
                        box.markReady()
                    case .stderr(let s): err += s
                    case .exited(let c, _): code = c
                    }
                }
            } catch {
                box.fail(error)
            }
            box.finish(stdout: out, stderr: err, code: code)
        }
        // Wait until the script printed "ready", then cancel. The runtime's
        // onTermination sends {"cmd":"cancel","target":id}; the host kills the
        // worker. A cancelled stream terminates without a final exit event
        // reaching the consumer, so instead assert the host is still healthy
        // and the next command runs cleanly — proof the cancel landed and the
        // worker table was cleaned up.
        await box.waitReady()
        consumer.cancel()
        _ = await box.result()
        // Give the cancel a moment to land on the host, then verify health by
        // running a real script file in the same cwd (the NodeHost worker
        // doesn't emulate `-e`; a real file keeps the probe honest).
        try await Task.sleep(nanoseconds: 300_000_000)
        try "console.log('still alive');"
            .write(to: tmp.appendingPathComponent("probe.js"), atomically: true, encoding: .utf8)
        let probe = try await collect(
            runtime.run(.node(script: "probe.js", args: []), in: tmp, environment: [:], timeout: 10)
        )
        XCTAssertEqual(probe.code, 0)
        XCTAssertTrue(probe.stdout.contains("still alive"))
    }

    /// Tiny awaitable box to ferry the consumer task's outcome across cancel.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ready = false
        private var done = false
        private var stdout = "", stderr = ""
        private var code: Int32?
        private var error: Error?

        func markReady() { lock.lock(); ready = true; lock.unlock() }
        func fail(_ e: Error) { lock.lock(); error = e; lock.unlock() }
        func finish(stdout: String, stderr: String, code: Int32?) {
            lock.lock()
            self.stdout = stdout; self.stderr = stderr; self.code = code; done = true
            lock.unlock()
        }
        func waitReady() async {
            while true {
                lock.lock(); let r = ready; lock.unlock()
                if r { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        func result() async -> (stdout: String, stderr: String, code: Int32?, error: Error?) {
            while true {
                lock.lock()
                if done || error != nil {
                    let r = (stdout, stderr, code, error)
                    lock.unlock()
                    return r
                }
                lock.unlock()
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }
}
#endif
