import XCTest
@testable import LocalAICore

final class WorkspaceStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(rootURL: tempRoot)
    }

    func testCreatePersistsMetadataAndRepositoryDirectory() async throws {
        let store = makeStore()
        let meta = try await store.create(name: "demo", repositoryURL: URL(string: "https://github.com/a/b"), branch: "main")
        XCTAssertEqual(meta.name, "demo")
        XCTAssertEqual(meta.branch, "main")

        let repoURL = try await store.repositoryURL(for: meta.id)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: repoURL.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)

        let fetched = try await store.metadata(for: meta.id)
        XCTAssertEqual(fetched, meta)
    }

    func testCreateRejectsEmptyName() async {
        let store = makeStore()
        do {
            _ = try await store.create(name: "   ")
            XCTFail("expected nameIsEmpty")
        } catch {
            XCTAssertEqual(error as? WorkspaceStoreError, .nameIsEmpty)
        }
    }

    func testListSortsByLastOpenedAtDescending() async throws {
        let store = makeStore()
        let a = try await store.create(name: "alpha")
        try await Task.sleep(nanoseconds: 20_000_000)
        let b = try await store.create(name: "beta")
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = try await store.open(id: a.id) // bump a to most recent

        let list = try await store.list()
        XCTAssertEqual(list.map(\.id), [a.id, b.id])
    }

    func testOpenUpdatesLastOpenedAt() async throws {
        let store = makeStore()
        let meta = try await store.create(name: "demo")
        let before = meta.lastOpenedAt
        try await Task.sleep(nanoseconds: 20_000_000)
        let opened = try await store.open(id: meta.id)
        XCTAssertGreaterThan(opened.lastOpenedAt, before)
    }

    func testRename() async throws {
        let store = makeStore()
        let meta = try await store.create(name: "old")
        let renamed = try await store.rename(id: meta.id, to: "new")
        XCTAssertEqual(renamed.name, "new")
        let fetched = try await store.metadata(for: meta.id)
        XCTAssertEqual(fetched.name, "new")
    }

    func testDeleteRequiresConfirmation() async throws {
        let store = makeStore()
        let meta = try await store.create(name: "demo")
        do {
            try await store.delete(id: meta.id, confirm: false)
            XCTFail("expected deletionNotConfirmed")
        } catch {
            XCTAssertEqual(error as? WorkspaceStoreError, .deletionNotConfirmed)
        }
        // Still there.
        let stillThere = try? await store.metadata(for: meta.id)
        XCTAssertNotNil(stillThere)

        try await store.delete(id: meta.id, confirm: true)
        do {
            _ = try await store.metadata(for: meta.id)
            XCTFail("expected workspaceNotFound")
        } catch {
            XCTAssertEqual(error as? WorkspaceStoreError, .workspaceNotFound(meta.id))
        }
    }

    func testRepositoryURLThrowsForMissingWorkspace() async {
        let store = makeStore()
        let missing = UUID()
        do {
            _ = try await store.repositoryURL(for: missing)
            XCTFail("expected workspaceNotFound")
        } catch {
            XCTAssertEqual(error as? WorkspaceStoreError, .workspaceNotFound(missing))
        }
    }

    func testListSkipsCorruptedMetadata() async throws {
        let store = makeStore()
        let good = try await store.create(name: "good")
        // Plant a corrupted workspace directory.
        let badID = UUID()
        let badDir = tempRoot
            .appendingPathComponent("Workspaces", isDirectory: true)
            .appendingPathComponent(badID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: badDir.appendingPathComponent("metadata.json"))

        let list = try await store.list()
        XCTAssertEqual(list.map(\.id), [good.id])
    }
}
