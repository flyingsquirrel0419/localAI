#if os(macOS) || os(Linux)
import XCTest
@testable import LocalAICore

final class JavaScriptRuntimeTests: XCTestCase {
    var runtime: ProcessJavaScriptRuntime!

    override func setUp() async throws {
        try await super.setUp()
        runtime = ProcessJavaScriptRuntime()
    }

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private func collect(
        _ stream: AsyncThrowingStream<RuntimeEvent, Error>
    ) async throws -> (stdout: String, stderr: String, code: Int32?, duration: TimeInterval) {
        var out = ""
        var err = ""
        var code: Int32?
        var duration: TimeInterval = 0
        for try await event in stream {
            switch event {
            case .stdout(let s): out += s
            case .stderr(let s): err += s
            case .exited(let c, let d):
                code = c
                duration = d
            }
        }
        return (out, err, code, duration)
    }

    func testRunNodeStreamsOutput() async throws {
        let dir = fixtureURL("simple-js")
        let result = try await collect(
            runtime.run(.node(script: "index.js", args: []), in: dir, environment: [:], timeout: 10)
        )
        XCTAssertTrue(result.stdout.contains("hello from fixture"))
        XCTAssertTrue(result.stderr.contains("a warning"))
        XCTAssertEqual(result.code, 0)
        XCTAssertGreaterThan(result.duration, 0)
    }

    func testNpmTestPasses() async throws {
        let dir = fixtureURL("passing-tests")
        let result = try await collect(
            runtime.run(.npm(args: ["test"]), in: dir, environment: [:], timeout: 60)
        )
        XCTAssertEqual(result.code, 0)
        let combined = result.stdout + result.stderr
        // Older node: "# pass 2"; newer node: "ℹ pass 2"
        XCTAssertTrue(
            combined.contains("# pass 2") || combined.contains("ℹ pass 2") || combined.contains("pass 2"),
            "expected TAP pass summary in: \(combined)"
        )
    }

    func testNpmTestFailureExitCode() async throws {
        let dir = fixtureURL("failing-tests")
        let result = try await collect(
            runtime.run(.npm(args: ["test"]), in: dir, environment: [:], timeout: 60)
        )
        XCTAssertNotEqual(result.code, 0)
        let combined = result.stdout + result.stderr
        XCTAssertTrue(
            combined.contains("# fail 1") || combined.contains("ℹ fail 1") || combined.contains("fail 1"),
            "expected TAP fail summary in: \(combined)"
        )
    }

    func testTimeoutKills() async throws {
        let dir = fixtureURL("simple-js")
        do {
            _ = try await collect(
                runtime.run(.node(script: "-e", args: ["setInterval(()=>{},1000)"]),
                            in: dir, environment: [:], timeout: 1)
            )
            XCTFail("expected timedOut")
        } catch RuntimeError.timedOut(let seconds) {
            XCTAssertEqual(seconds, 1)
        }
    }

    func testNativeAddonDetectorFromPackageJSON() throws {
        let dir = fixtureURL("native-package")
        let found = NativeAddonDetector().detectNativePackages(in: dir)
        XCTAssertTrue(found.contains("better-sqlite3"))
        XCTAssertTrue(found.contains("sharp"))
        XCTAssertEqual(NativeAddonDetector.userMessage,
            "This package requires a native Node addon that is not supported by the current mobile runtime.")
    }

    func testNativeAddonDetectorDetectsBindingGyp() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-gyp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try #"{"name":"native-thing","gypfile":true}"#
            .write(to: tmp.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "{}".write(to: tmp.appendingPathComponent("binding.gyp"), atomically: true, encoding: .utf8)

        let found = NativeAddonDetector().detectNativePackages(in: tmp)
        XCTAssertTrue(found.contains("native-thing"))
    }

    func testNativeAddonDetectorCleanPackage() throws {
        let dir = fixtureURL("passing-tests")
        let found = NativeAddonDetector().detectNativePackages(in: dir)
        XCTAssertTrue(found.isEmpty)
    }
}
#endif
