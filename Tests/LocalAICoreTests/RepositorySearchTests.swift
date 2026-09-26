import XCTest
@testable import LocalAICore

final class RepositorySearchTests: XCTestCase {
    private var tempRoot: URL!
    private var fs: SandboxedFileSystem!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RepositorySearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        fs = try SandboxedFileSystem(rootURL: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func populate() throws {
        try fs.write("Sources/main.swift", contents: "func main() {\n    print(\"hello world\")\n}\n")
        try fs.write("Sources/util.swift", contents: "func helper() {}\n// TODO: fix\n")
        try fs.write("README.md", contents: "# Demo\nhello there\n")
        try fs.write("node_modules/pkg/index.js", contents: "hello from module\n")
        try fs.write(".git/config", contents: "secret hello\n")
        try fs.write(".gitignore", contents: "ignored.txt\n")
        try fs.write("ignored.txt", contents: "hello ignored\n")
        try fs.write("binary.bin", contents: "hello\u{0}world")
    }

    func testSearchFilesByName() async throws {
        try populate()
        let search = RepositorySearch(fileSystem: fs)
        let results = try await search.searchFiles(query: "main")
        XCTAssertEqual(results.first?.relativePath, "Sources/main.swift")
    }

    func testSearchFilesRanksExactFirst() async throws {
        try fs.write("util.swift", contents: "")
        try fs.write("deep/utilities.swift", contents: "")
        let search = RepositorySearch(fileSystem: fs)
        let results = try await search.searchFiles(query: "util.swift")
        XCTAssertEqual(results.first?.fileName, "util.swift")
        XCTAssertEqual(results.first?.score, 100)
    }

    func testSearchFilesExtensionFilter() async throws {
        try populate()
        let search = RepositorySearch(fileSystem: fs)
        let results = try await search.searchFiles(query: "", extensions: ["swift"])
        XCTAssertTrue(results.allSatisfy { $0.relativePath.hasSuffix(".swift") })
        XCTAssertEqual(results.count, 2)
    }

    func testSearchTextPlain() async throws {
        try populate()
        let search = RepositorySearch(fileSystem: fs)
        let results = try await search.searchText(pattern: "hello")
        let paths = Set(results.map(\.relativePath))
        XCTAssertTrue(paths.contains("Sources/main.swift"))
        XCTAssertTrue(paths.contains("README.md"))
        // Default excludes + gitignore + binary skip.
        XCTAssertFalse(paths.contains("node_modules/pkg/index.js"))
        XCTAssertFalse(paths.contains(".git/config"))
        XCTAssertFalse(paths.contains("ignored.txt"))
        XCTAssertFalse(paths.contains("binary.bin"))
    }

    func testSearchTextCaseSensitivity() async throws {
        try fs.write("a.txt", contents: "Hello hello HELLO\n")
        let search = RepositorySearch(fileSystem: fs)
        let insensitive = try await search.searchText(pattern: "hello", caseSensitive: false)
        XCTAssertEqual(insensitive.count, 3)
        let sensitive = try await search.searchText(pattern: "hello", caseSensitive: true)
        XCTAssertEqual(sensitive.count, 1)
        XCTAssertEqual(sensitive.first?.column, 7)
    }

    func testSearchTextRegex() async throws {
        try fs.write("code.swift", contents: "let abc123 = 1\nlet abc = 2\n")
        let search = RepositorySearch(fileSystem: fs)
        let results = try await search.searchText(pattern: #"abc\d+"#, isRegex: true)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.line, 1)
    }

    func testSearchTextInvalidRegexThrows() async throws {
        let search = RepositorySearch(fileSystem: fs)
        await XCTAssertThrowsErrorAsync(try await search.searchText(pattern: "(", isRegex: true)) { error in
            guard case SearchError.invalidRegex = error else {
                return XCTFail("expected invalidRegex, got \(error)")
            }
        }
    }

    func testSearchTextLineAndColumn() async throws {
        try fs.write("x.txt", contents: "nothing here\nthe needle sits here\n")
        let search = RepositorySearch(fileSystem: fs)
        let results = try await search.searchText(pattern: "needle")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.line, 2)
        XCTAssertEqual(results.first?.column, 5)
    }

    func testIncludeIgnoredOption() async throws {
        try populate()
        let search = RepositorySearch(
            fileSystem: fs,
            options: SearchOptions(includeIgnored: true)
        )
        let results = try await search.searchText(pattern: "hello")
        let paths = Set(results.map(\.relativePath))
        XCTAssertTrue(paths.contains("ignored.txt"))
        XCTAssertTrue(paths.contains("node_modules/pkg/index.js"))
    }

    func testSkipsLargeFiles() async throws {
        let big = String(repeating: "needle\n", count: 300_000) // ~2.1 MB
        try fs.write("big.txt", contents: big)
        let search = RepositorySearch(fileSystem: fs)
        let results = try await search.searchText(pattern: "needle")
        XCTAssertTrue(results.isEmpty)
    }

    func testSearchLimit() async throws {
        var body = ""
        for i in 0..<50 { body += "match \(i)\n" }
        try fs.write("many.txt", contents: body)
        let search = RepositorySearch(fileSystem: fs)
        let results = try await search.searchText(pattern: "match", limit: 10)
        XCTAssertEqual(results.count, 10)
    }
}

func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected error: \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
