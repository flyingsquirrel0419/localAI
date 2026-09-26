import XCTest
@testable import LocalAICore

final class GitIgnoreMatcherTests: XCTestCase {
    private func matcher(_ contents: String, base: String = "") -> GitIgnoreMatcher {
        var m = GitIgnoreMatcher()
        m.addGitIgnore(contents: contents, baseDirectory: base)
        return m
    }

    func testSimpleGlob() {
        let m = matcher("*.log\n")
        XCTAssertTrue(m.isIgnored(relativePath: "debug.log", isDirectory: false))
        XCTAssertTrue(m.isIgnored(relativePath: "a/b/debug.log", isDirectory: false))
        XCTAssertFalse(m.isIgnored(relativePath: "log.txt", isDirectory: false))
    }

    func testDoubleStar() {
        let m = matcher("**/temp/**")
        XCTAssertTrue(m.isIgnored(relativePath: "temp/x.txt", isDirectory: false))
        XCTAssertTrue(m.isIgnored(relativePath: "a/temp/x.txt", isDirectory: false))
        XCTAssertTrue(m.isIgnored(relativePath: "a/b/temp/deep/x.txt", isDirectory: false))
    }

    func testQuestionMark() {
        let m = matcher("file?.txt")
        XCTAssertTrue(m.isIgnored(relativePath: "file1.txt", isDirectory: false))
        XCTAssertFalse(m.isIgnored(relativePath: "file12.txt", isDirectory: false))
    }

    func testLeadingSlashAnchors() {
        let m = matcher("/build")
        XCTAssertTrue(m.isIgnored(relativePath: "build", isDirectory: true))
        XCTAssertFalse(m.isIgnored(relativePath: "src/build", isDirectory: true))
    }

    func testTrailingSlashDirectoryOnly() {
        let m = matcher("logs/")
        XCTAssertTrue(m.isIgnored(relativePath: "logs", isDirectory: true))
        XCTAssertFalse(m.isIgnored(relativePath: "logs", isDirectory: false))
    }

    func testNegation() {
        let m = matcher("*.log\n!important.log\n")
        XCTAssertTrue(m.isIgnored(relativePath: "debug.log", isDirectory: false))
        XCTAssertFalse(m.isIgnored(relativePath: "important.log", isDirectory: false))
    }

    func testCommentsAndBlankLines() {
        let m = matcher("# comment\n\n*.o\n")
        XCTAssertEqual(m.patterns.count, 1)
        XCTAssertTrue(m.isIgnored(relativePath: "x.o", isDirectory: false))
    }

    func testNestedGitignore() {
        var m = GitIgnoreMatcher()
        m.addGitIgnore(contents: "*.log", baseDirectory: "")
        m.addGitIgnore(contents: "generated/", baseDirectory: "sub")
        XCTAssertTrue(m.isIgnored(relativePath: "a.log", isDirectory: false))
        XCTAssertTrue(m.isIgnored(relativePath: "sub/generated", isDirectory: true))
        XCTAssertFalse(m.isIgnored(relativePath: "other/generated", isDirectory: true))
    }

    func testNestedGitignoreFromDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitIgnoreNested-\(UUID().uuidString)", isDirectory: true)
        let fs = try SandboxedFileSystem(rootURL: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try fs.write(".gitignore", contents: "*.log\n")
        try fs.write("sub/.gitignore", contents: "out/\n!important.txt\n")
        try fs.write("sub/out/file.txt", contents: "x")

        let m = GitIgnoreMatcher(fileSystem: fs)
        XCTAssertTrue(m.isIgnored(relativePath: "top.log", isDirectory: false))
        XCTAssertTrue(m.isIgnored(relativePath: "sub/out", isDirectory: true))
        XCTAssertFalse(m.isIgnored(relativePath: "sub/important.txt", isDirectory: false))
    }

    func testAnchoredPatternWithSlash() {
        let m = matcher("doc/*.txt")
        XCTAssertTrue(m.isIgnored(relativePath: "doc/a.txt", isDirectory: false))
        XCTAssertFalse(m.isIgnored(relativePath: "src/doc/a.txt", isDirectory: false))
    }
}
