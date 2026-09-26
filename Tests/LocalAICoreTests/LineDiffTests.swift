import XCTest
@testable import LocalAICore

final class LineDiffTests: XCTestCase {
    func testNoChangesProducesNoHunks() {
        let hunks = LineDiff.diff(old: "a\nb\nc\n", new: "a\nb\nc\n")
        XCTAssertTrue(hunks.isEmpty)
    }

    func testSimpleReplacement() {
        let hunks = LineDiff.diff(old: "a\nb\nc\n", new: "a\nx\nc\n")
        XCTAssertEqual(hunks.count, 1)
        let h = hunks[0]
        let kinds = h.lines.map(\.kind)
        XCTAssertTrue(kinds.contains(.removed))
        XCTAssertTrue(kinds.contains(.added))
        XCTAssertEqual(h.lines.first(where: { $0.kind == .removed })?.text, "b")
        XCTAssertEqual(h.lines.first(where: { $0.kind == .added })?.text, "x")
    }

    func testInsertion() {
        let hunks = LineDiff.diff(old: "a\nc\n", new: "a\nb\nc\n")
        XCTAssertEqual(hunks.count, 1)
        let added = hunks[0].lines.filter { $0.kind == .added }
        XCTAssertEqual(added.map(\.text), ["b"])
        XCTAssertEqual(added.first?.newLineNumber, 2)
    }

    func testDeletion() {
        let hunks = LineDiff.diff(old: "a\nb\nc\n", new: "a\nc\n")
        let removed = hunks[0].lines.filter { $0.kind == .removed }
        XCTAssertEqual(removed.map(\.text), ["b"])
        XCTAssertEqual(removed.first?.oldLineNumber, 2)
    }

    func testStats() {
        let hunks = LineDiff.diff(old: "a\nb\nc\nd\n", new: "a\nx\ny\nd\n")
        let stats = LineDiff.stats(hunks: hunks)
        XCTAssertEqual(stats.added, 2)
        XCTAssertEqual(stats.removed, 2)
    }

    func testDistantChangesProduceSeparateHunks() {
        let oldLines = (1...20).map { "line\($0)" }
        var newLines = oldLines
        newLines[1] = "CHANGED1"
        newLines[17] = "CHANGED2"
        let hunks = LineDiff.diff(old: oldLines.joined(separator: "\n"),
                                  new: newLines.joined(separator: "\n"))
        XCTAssertEqual(hunks.count, 2)
    }

    func testUnifiedRenderFormat() {
        let old = "line1\nline2\nline3\nline4\nline5\n"
        let new = "line1\nline2\nCHANGED\nline4\nline5\n"
        let text = UnifiedDiff.render(oldPath: "a/f.txt", newPath: "b/f.txt", old: old, new: new)
        XCTAssertTrue(text.contains("--- a/f.txt"))
        XCTAssertTrue(text.contains("+++ b/f.txt"))
        XCTAssertTrue(text.contains("@@ -"))
        XCTAssertTrue(text.contains("-line3"))
        XCTAssertTrue(text.contains("+CHANGED"))
    }

    func testRoundTripSingleFile() throws {
        let old = "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\neta\ntheta\n"
        let new = "alpha\nBETA\ngamma\ndelta\nEPSILON\nzeta\neta\nTHETA\niota\n"
        let diffText = UnifiedDiff.render(oldPath: "a/f.txt", newPath: "b/f.txt", old: old, new: new)
        let parsed = try UnifiedDiff.parse(diffText)
        XCTAssertEqual(parsed.count, 1)
        let patched = try PatchApplier.apply(hunks: parsed[0].hunks, to: old)
        XCTAssertEqual(patched, new)
    }

    func testRoundTripMultiHunk() throws {
        let oldLines = (1...30).map { "l\($0)" }
        var newLines = oldLines
        newLines[2] = "X2"
        newLines[15] = "X15"
        newLines[28] = "X28"
        let old = oldLines.joined(separator: "\n") + "\n"
        let new = newLines.joined(separator: "\n") + "\n"
        let diffText = UnifiedDiff.render(oldPath: "a/f", newPath: "b/f", old: old, new: new)
        let parsed = try UnifiedDiff.parse(diffText)
        XCTAssertGreaterThan(parsed[0].hunks.count, 1)
        let patched = try PatchApplier.apply(hunks: parsed[0].hunks, to: old)
        XCTAssertEqual(patched, new)
    }

    func testParseMultiFile() throws {
        let diff = """
        --- a/one.txt
        +++ b/one.txt
        @@ -1,1 +1,1 @@
        -a
        +b
        --- a/two.txt
        +++ b/two.txt
        @@ -1,1 +1,1 @@
        -c
        +d
        """
        let files = try UnifiedDiff.parse(diff)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].oldPath, "one.txt")
        XCTAssertEqual(files[1].newPath, "two.txt")
    }

    func testApplyMultiFileDiff() throws {
        let diff = """
        --- a/one.txt
        +++ b/one.txt
        @@ -1,1 +1,1 @@
        -a
        +b
        --- a/two.txt
        +++ b/two.txt
        @@ -1,1 +1,1 @@
        -c
        +d
        """
        let result = try PatchApplier.apply(unifiedDiff: diff, to: ["one.txt": "a\n", "two.txt": "c\n"])
        XCTAssertEqual(result["one.txt"], "b\n")
        XCTAssertEqual(result["two.txt"], "d\n")
    }

    func testFuzzOffset() throws {
        // Hunk says oldStart=1 but content actually starts at line 30 (offset +29,
        // within the ±50 fuzz radius).
        var lines = (1...40).map { "line\($0)" }
        lines[29] = "needle"
        let text = lines.joined(separator: "\n") + "\n"
        let hunk = DiffHunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
            lines: [DiffLine(kind: .removed, text: "needle", oldLineNumber: 1, newLineNumber: nil),
                    DiffLine(kind: .added, text: "replaced", oldLineNumber: nil, newLineNumber: 1)]
        )
        let patched = try PatchApplier.apply(hunks: [hunk], to: text)
        XCTAssertTrue(patched.contains("replaced"))
        XCTAssertFalse(patched.contains("needle"))
    }

    func testContextMismatchThrows() {
        let hunk = DiffHunk(
            oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
            lines: [DiffLine(kind: .removed, text: "not-there", oldLineNumber: 1, newLineNumber: nil)]
        )
        XCTAssertThrowsError(try PatchApplier.apply(hunks: [hunk], to: "entirely\ndifferent\n")) { error in
            guard case PatchError.contextMismatch = error else {
                return XCTFail("expected contextMismatch, got \(error)")
            }
        }
    }

    // MARK: - Search/replace edits

    func testSearchReplace() throws {
        let text = "hello world\nsecond line\n"
        let out = try PatchApplier.searchReplace(text: text, oldString: "world", newString: "there")
        XCTAssertEqual(out, "hello there\nsecond line\n")
    }

    func testSearchReplaceAmbiguousThrows() {
        let text = "dup and dup\n"
        XCTAssertThrowsError(try PatchApplier.searchReplace(text: text, oldString: "dup", newString: "x")) { error in
            guard case PatchError.ambiguousOldString(let n) = error, n > 1 else {
                return XCTFail("expected ambiguousOldString, got \(error)")
            }
        }
    }

    func testSearchReplaceNotFoundThrows() {
        XCTAssertThrowsError(try PatchApplier.searchReplace(text: "abc", oldString: "zzz", newString: "x")) { error in
            guard case PatchError.oldStringNotFound = error else {
                return XCTFail("expected oldStringNotFound, got \(error)")
            }
        }
    }

    func testSearchReplaceEditStruct() throws {
        let edit = SearchReplaceEdit(oldString: "a", newString: "b")
        XCTAssertEqual(try edit.apply(to: "a"), "b")
    }
}
