#if os(macOS) || os(Linux)
import XCTest
@testable import LocalAICore

final class GitServiceTests: XCTestCase {
    var tempRoot: URL!
    var remoteURL: URL!     // bare
    var cloneA: URL!
    var cloneB: URL!
    var service: CLIGitService!

    override func setUp() async throws {
        try await super.setUp()
        service = CLIGitService()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        remoteURL = tempRoot.appendingPathComponent("remote.git", isDirectory: true)
        cloneA = tempRoot.appendingPathComponent("a", isDirectory: true)
        cloneB = tempRoot.appendingPathComponent("b", isDirectory: true)

        // Init bare remote and seed it with a first commit (via a temp workdir).
        let seed = tempRoot.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try Self.git(["init", "--bare", "--initial-branch=main", remoteURL.path], in: tempRoot)
        try Self.git(["init", "--initial-branch=main"], in: seed)
        try Self.git(["config", "user.email", "seed@local"], in: seed)
        try Self.git(["config", "user.name", "Seed"], in: seed)
        try "hello\n".write(to: seed.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try Self.git(["add", "README.md"], in: seed)
        try Self.git(["commit", "-m", "init"], in: seed)
        try Self.git(["push", remoteURL.path, "HEAD:main"], in: seed)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    private static func git(_ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        p.environment = env
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed"
            ])
        }
    }

    private func write(_ text: String, to path: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private let author = GitAuthor(name: "Tester", email: "tester@local")

    func testCloneStatusDiffCommitPushPull() async throws {
        try await service.clone(url: URL(fileURLWithPath: remoteURL.path), to: cloneA, branch: nil, credentials: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloneA.appendingPathComponent("README.md").path))

        // Untracked file appears in status.
        try write("new file\n", to: "src/main.swift", in: cloneA)
        var status = try await service.status(in: cloneA)
        XCTAssertTrue(status.contains { $0.path == "src/main.swift" && $0.kind == .untracked })

        // Modify tracked file.
        try write("hello v2\n", to: "README.md", in: cloneA)
        status = try await service.status(in: cloneA)
        XCTAssertTrue(status.contains { $0.path == "README.md" && $0.kind == .modified && !$0.staged })

        // Diff shows the change.
        let diffText = try await service.diff(in: cloneA, paths: nil, staged: false)
        XCTAssertTrue(diffText.contains("README.md"))
        XCTAssertTrue(diffText.contains("+hello v2"))

        // Stage, commit.
        try await service.stage(in: cloneA, paths: ["README.md", "src/main.swift"])
        status = try await service.status(in: cloneA)
        XCTAssertTrue(status.contains { $0.path == "README.md" && $0.staged })

        let sha = try await service.commit(in: cloneA, message: "add main.swift", author: author)
        XCTAssertEqual(sha.count, 40)

        // Push to remote.
        try await service.push(in: cloneA, remote: "origin", branch: "main", credentials: nil, force: false)

        // Second clone pulls fast-forward.
        try await service.clone(url: URL(fileURLWithPath: remoteURL.path), to: cloneB, branch: nil, credentials: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloneB.appendingPathComponent("src/main.swift").path))

        // Make another commit on A, push, then pull on B.
        try write("another\n", to: "notes.txt", in: cloneA)
        try await service.stage(in: cloneA, paths: ["notes.txt"])
        _ = try await service.commit(in: cloneA, message: "notes", author: author)
        try await service.push(in: cloneA, remote: "origin", branch: "main", credentials: nil, force: false)

        let pullResult = try await service.pull(in: cloneB, credentials: nil)
        guard case .fastForward(let commits) = pullResult else {
            XCTFail("expected fastForward, got \(pullResult)")
            return
        }
        XCTAssertGreaterThanOrEqual(commits, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloneB.appendingPathComponent("notes.txt").path))

        // Pull again -> upToDate.
        let again = try await service.pull(in: cloneB, credentials: nil)
        XCTAssertEqual(again, .upToDate)
    }

    func testBranchAndCheckout() async throws {
        try await service.clone(url: URL(fileURLWithPath: remoteURL.path), to: cloneA, branch: nil, credentials: nil)
        let initial = try await service.currentBranch(in: cloneA)
        XCTAssertEqual(initial, "main")

        try await service.checkout(in: cloneA, branch: "feature", create: true)
        let afterCreate = try await service.currentBranch(in: cloneA)
        XCTAssertEqual(afterCreate, "feature")

        let branches = try await service.branches(in: cloneA)
        XCTAssertTrue(branches.contains { $0.name == "feature" && $0.isCurrent })
        XCTAssertTrue(branches.contains { $0.name == "main" && !$0.isCurrent })

        try await service.checkout(in: cloneA, branch: "main", create: false)
        let afterSwitch = try await service.currentBranch(in: cloneA)
        XCTAssertEqual(afterSwitch, "main")

        // Duplicate create -> error.
        do {
            try await service.checkout(in: cloneA, branch: "feature", create: true)
            XCTFail("expected branchExists")
        } catch GitError.branchExists(let name) {
            XCTAssertEqual(name, "feature")
        }
    }

    func testNonFastForwardPushRejected() async throws {
        try await service.clone(url: URL(fileURLWithPath: remoteURL.path), to: cloneA, branch: nil, credentials: nil)
        try await service.clone(url: URL(fileURLWithPath: remoteURL.path), to: cloneB, branch: nil, credentials: nil)

        // A commits and pushes.
        try write("from A\n", to: "a.txt", in: cloneA)
        try await service.stage(in: cloneA, paths: ["a.txt"])
        _ = try await service.commit(in: cloneA, message: "A commit", author: author)
        try await service.push(in: cloneA, remote: "origin", branch: "main", credentials: nil, force: false)

        // B (stale) commits locally and tries to push -> rejected.
        try write("from B\n", to: "b.txt", in: cloneB)
        try await service.stage(in: cloneB, paths: ["b.txt"])
        _ = try await service.commit(in: cloneB, message: "B commit", author: author)

        do {
            try await service.push(in: cloneB, remote: "origin", branch: "main", credentials: nil, force: false)
            XCTFail("expected nonFastForward")
        } catch let error as GitError {
            guard case .nonFastForward = error else {
                XCTFail("expected nonFastForward, got \(error)")
                return
            }
            let uf = error.userFacingError
            XCTAssertEqual(uf.message, "Remote has new commits. Pull first.")
        }
    }

    func testGitErrorMapping() {
        let uf = GitError.authenticationFailed.userFacingError
        XCTAssertEqual(uf.title, "Authentication failed")
        XCTAssertEqual(uf.recoveryAction, .signIn)
    }
}
#endif
