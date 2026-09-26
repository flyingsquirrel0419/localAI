import XCTest
@testable import LocalAICore

final class SandboxedFileSystemTests: XCTestCase {
    private var tempRoot: URL!
    private var fs: SandboxedFileSystem!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SandboxedFileSystemTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        fs = try SandboxedFileSystem(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Basic operations

    func testWriteAndRead() throws {
        try fs.write("hello.txt", contents: "hello world")
        XCTAssertEqual(try fs.read("hello.txt"), "hello world")
        XCTAssertTrue(fs.exists("hello.txt"))
    }

    func testWriteCreatesIntermediateDirectories() throws {
        try fs.write("a/b/c/file.txt", contents: "deep")
        XCTAssertEqual(try fs.read("a/b/c/file.txt"), "deep")
    }

    func testListDirectorySortsDirectoriesFirst() throws {
        try fs.createDirectory("zdir")
        try fs.createDirectory("adir")
        try fs.write("bfile.txt", contents: "x")
        try fs.write("afile.txt", contents: "x")

        let nodes = try fs.listDirectory(".")
        XCTAssertEqual(nodes.map(\.name), ["adir", "zdir", "afile.txt", "bfile.txt"])
        XCTAssertTrue(nodes[0].isDirectory)
        XCTAssertFalse(nodes[2].isDirectory)
    }

    func testStat() throws {
        try fs.write("sized.txt", contents: "12345")
        let stat = try fs.stat("sized.txt")
        XCTAssertFalse(stat.isDirectory)
        XCTAssertEqual(stat.size, 5)
        XCTAssertNotNil(stat.modifiedAt)
    }

    func testReadEnforcesSizeLimit() throws {
        let big = String(repeating: "x", count: 2048)
        try fs.write("big.txt", contents: big)
        XCTAssertThrowsError(try fs.read("big.txt", maxBytes: 100)) { error in
            guard case FileSystemError.fileTooLarge = error else {
                return XCTFail("expected fileTooLarge, got \(error)")
            }
        }
    }

    func testReadRejectsDirectory() throws {
        try fs.createDirectory("d")
        XCTAssertThrowsError(try fs.read("d")) { error in
            XCTAssertEqual(error as? FileSystemError, .isDirectory("d"))
        }
    }

    func testReadRejectsMissingFile() throws {
        XCTAssertThrowsError(try fs.read("nope.txt")) { error in
            XCTAssertEqual(error as? FileSystemError, .notFound("nope.txt"))
        }
    }

    func testCreateFileRefusesOverwrite() throws {
        try fs.createFile("f.txt", contents: "1")
        XCTAssertThrowsError(try fs.createFile("f.txt", contents: "2")) { error in
            XCTAssertEqual(error as? FileSystemError, .alreadyExists("f.txt"))
        }
        XCTAssertEqual(try fs.read("f.txt"), "1")
    }

    func testDeleteFile() throws {
        try fs.write("gone.txt", contents: "x")
        try fs.delete("gone.txt")
        XCTAssertFalse(fs.exists("gone.txt"))
    }

    func testDeleteNonEmptyDirectoryRequiresRecursive() throws {
        try fs.write("dir/file.txt", contents: "x")
        XCTAssertThrowsError(try fs.delete("dir")) { error in
            XCTAssertEqual(error as? FileSystemError, .recursiveDeleteRequiresFlag("dir"))
        }
        try fs.delete("dir", recursive: true)
        XCTAssertFalse(fs.exists("dir"))
    }

    func testDeleteRootIsRefused() throws {
        XCTAssertThrowsError(try fs.delete(".", recursive: true)) { error in
            XCTAssertEqual(error as? FileSystemError, .cannotDeleteRoot)
        }
    }

    func testMove() throws {
        try fs.write("old.txt", contents: "content")
        try fs.move(from: "old.txt", to: "sub/new.txt")
        XCTAssertFalse(fs.exists("old.txt"))
        XCTAssertEqual(try fs.read("sub/new.txt"), "content")
    }

    func testMoveRefusesExistingDestination() throws {
        try fs.write("a.txt", contents: "a")
        try fs.write("b.txt", contents: "b")
        XCTAssertThrowsError(try fs.move(from: "a.txt", to: "b.txt")) { error in
            XCTAssertEqual(error as? FileSystemError, .alreadyExists("b.txt"))
        }
    }

    // MARK: - Path traversal protection

    func testDotDotEscapeRejected() {
        XCTAssertThrowsError(try fs.resolve("../outside.txt")) { error in
            guard case FileSystemError.pathEscapesSandbox = error else {
                return XCTFail("expected pathEscapesSandbox, got \(error)")
            }
        }
    }

    func testNestedDotDotEscapeRejected() {
        XCTAssertThrowsError(try fs.resolve("a/../../outside.txt")) { error in
            guard case FileSystemError.pathEscapesSandbox = error else {
                return XCTFail("expected pathEscapesSandbox, got \(error)")
            }
        }
    }

    func testAbsolutePathRejected() {
        XCTAssertThrowsError(try fs.resolve("/etc/passwd")) { error in
            guard case FileSystemError.pathEscapesSandbox = error else {
                return XCTFail("expected pathEscapesSandbox, got \(error)")
            }
        }
    }

    func testReadEtcPasswdRejected() {
        XCTAssertThrowsError(try fs.read("/etc/passwd")) { error in
            guard case FileSystemError.pathEscapesSandbox = error else {
                return XCTFail("expected pathEscapesSandbox, got \(error)")
            }
        }
    }

    func testSymlinkEscapeRejected() throws {
        // Create a directory outside the sandbox and a symlink inside pointing to it.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))

        let linkURL = tempRoot.appendingPathComponent("evil-link")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outside)

        XCTAssertThrowsError(try fs.read("evil-link/secret.txt")) { error in
            guard case FileSystemError.pathEscapesSandbox = error else {
                return XCTFail("expected pathEscapesSandbox, got \(error)")
            }
        }
        XCTAssertThrowsError(try fs.listDirectory("evil-link")) { error in
            guard case FileSystemError.pathEscapesSandbox = error else {
                return XCTFail("expected pathEscapesSandbox, got \(error)")
            }
        }
    }

    func testInternalSymlinkAllowed() throws {
        try fs.write("real/file.txt", contents: "ok")
        let linkURL = tempRoot.appendingPathComponent("link-to-real")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: tempRoot.appendingPathComponent("real")
        )
        XCTAssertEqual(try fs.read("link-to-real/file.txt"), "ok")
    }

    func testWriteThroughEscapingSymlinkRejected() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let linkURL = tempRoot.appendingPathComponent("out-link")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outside)

        XCTAssertThrowsError(try fs.write("out-link/new.txt", contents: "bad")) { error in
            guard case FileSystemError.pathEscapesSandbox = error else {
                return XCTFail("expected pathEscapesSandbox, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))
    }

    func testInnocuousDotDotInsideSandboxAllowed() throws {
        // "sub/../file.txt" resolves to "file.txt" which is still inside.
        try fs.createDirectory("sub")
        try fs.write("sub/../file.txt", contents: "fine")
        XCTAssertEqual(try fs.read("file.txt"), "fine")
    }
}
