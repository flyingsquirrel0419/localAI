import XCTest
@testable import LocalAICore

final class StopSequenceFilterTests: XCTestCase {
    /// Feed all chunks through the filter, collecting emitted text.
    /// Returns (emitted, stoppedAfterWhichChunkIndex or nil).
    private func run(
        _ chunks: [String],
        stops: [String]
    ) -> (emitted: String, stopped: Bool) {
        var filter = StopSequenceFilter(stopSequences: stops)
        var out = ""
        var stopped = false
        for chunk in chunks {
            let r = filter.feed(chunk)
            out += r.emit
            if r.stopped { stopped = true; break }
        }
        if !stopped { out += filter.finish() }
        return (out, stopped)
    }

    func testNoStopsIsPassThrough() {
        let (out, stopped) = run(["hello ", "world"], stops: [])
        XCTAssertEqual(out, "hello world")
        XCTAssertFalse(stopped)
    }

    func testNoStopEmitsEverything() {
        let (out, stopped) = run(["abc", "def", "ghi"], stops: ["</tool_call>"])
        XCTAssertEqual(out, "abcdefghi")
        XCTAssertFalse(stopped)
    }

    func testStopWithinSingleChunk() {
        let (out, stopped) = run(["foo</tool_call>bar baz"], stops: ["</tool_call>"])
        XCTAssertEqual(out, "foo</tool_call>")
        XCTAssertTrue(stopped)
    }

    func testStopSplitAcrossTwoChunks() {
        let (out, stopped) = run(["foo</tool", "_call>bar"], stops: ["</tool_call>"])
        XCTAssertEqual(out, "foo</tool_call>")
        XCTAssertTrue(stopped)
    }

    func testStopSplitAcrossThreeChunks() {
        let (out, stopped) = run(["foo</to", "ol_ca", "ll>junk"], stops: ["</tool_call>"])
        XCTAssertEqual(out, "foo</tool_call>")
        XCTAssertTrue(stopped)
    }

    func testStopAtChunkStart() {
        let (out, stopped) = run(["</tool_call>", "ignored"], stops: ["</tool_call>"])
        XCTAssertEqual(out, "</tool_call>")
        XCTAssertTrue(stopped)
    }

    func testStopAtChunkEnd() {
        let (out, stopped) = run(["hello</tool_call>"], stops: ["</tool_call>"])
        XCTAssertEqual(out, "hello</tool_call>")
        XCTAssertTrue(stopped)
    }

    func testStopAtVeryStartOfStream() {
        let (out, stopped) = run(["</tool_call>everything after is dropped"], stops: ["</tool_call>"])
        XCTAssertEqual(out, "</tool_call>")
        XCTAssertTrue(stopped)
    }

    func testMultipleStopsEarliestWins() {
        let (out, stopped) = run(
            ["the answer is 42. END. Or maybe STOP now"],
            stops: ["STOP", "END."]
        )
        XCTAssertEqual(out, "the answer is 42. END.")
        XCTAssertTrue(stopped)
    }

    func testMultipleStopsSecondNeverReached() {
        // Only the first stop is emitted; stream ends there.
        let (out, stopped) = run(["aSTOPbENDc"], stops: ["STOP", "END"])
        XCTAssertEqual(out, "aSTOP")
        XCTAssertTrue(stopped)
    }

    func testPartialPrefixAtEndIsFlushedByFinish() {
        // Stream ends with a dangling partial stop — it was real text.
        let (out, stopped) = run(["foo</to"], stops: ["</tool_call>"])
        XCTAssertEqual(out, "foo</to")
        XCTAssertFalse(stopped)
    }

    func testHeldTextAcrossManyChunksWithoutStop() {
        // Force the hold/release path repeatedly without ever completing.
        let chunks = ["<", "</", "</t", "x</", "y"]
        let (out, stopped) = run(chunks, stops: ["</tool_call>"])
        XCTAssertEqual(out, chunks.joined())
        XCTAssertFalse(stopped)
    }

    func testEmptyChunksAreHarmless() {
        let (out, stopped) = run(["", "foo", "", "</tool_call>", ""], stops: ["</tool_call>"])
        XCTAssertEqual(out, "foo</tool_call>")
        XCTAssertTrue(stopped)
    }

    func testEmptyStream() {
        let (out, stopped) = run([], stops: ["</tool_call>"])
        XCTAssertEqual(out, "")
        XCTAssertFalse(stopped)
    }

    func testUnicodeContentPassThrough() {
        let (out, stopped) = run(["한국어 텍스트 ", "🚀 이모지 ", "mixed"], stops: ["</tool_call>"])
        XCTAssertEqual(out, "한국어 텍스트 🚀 이모지 mixed")
        XCTAssertFalse(stopped)
    }

    func testUnicodeBeforeStop() {
        let (out, stopped) = run(["완료했습니다</tool_call>나머지"], stops: ["</tool_call>"])
        XCTAssertEqual(out, "완료했습니다</tool_call>")
        XCTAssertTrue(stopped)
    }

    func testUnicodeStopString() {
        let (out, stopped) = run(["결과를 출력합니다【끝】추가 텍스트"], stops: ["【끝】"])
        XCTAssertEqual(out, "결과를 출력합니다【끝】")
        XCTAssertTrue(stopped)
    }

    func testUnicodeStopSplitAcrossChunks() {
        // 【끝】 split across chunk boundaries.
        let (out, stopped) = run(["텍스트【", "끝", "】후속"], stops: ["【끝】"])
        XCTAssertEqual(out, "텍스트【끝】")
        XCTAssertTrue(stopped)
    }

    func testStopStringOverlappingPrefixes() {
        // Stops where one is a prefix of another: shortest (earliest-ending)
        // must win since feed() reports the first *complete* match.
        let (out, _) = run(["abcSTOP"], stops: ["STOP", "STOP!", "STOP NOW"])
        XCTAssertEqual(out, "abcSTOP")
    }

    func testStopAfterPartialPrefixFalseAlarm() {
        // "</x" is not a prefix of "</tool_call>", so it must be emitted
        // immediately; then the real stop follows.
        let (out, stopped) = run(["</x then </tool_call>done"], stops: ["</tool_call>"])
        XCTAssertEqual(out, "</x then </tool_call>")
        XCTAssertTrue(stopped)
    }

    func testRepeatedPartialPrefixes() {
        // "<<<<<" then real stop: each "<" is a one-char prefix of the stop
        // and must be held, then released when the next char isn't "/".
        let (out, stopped) = run(["<<<<<ok</tool_call>z"], stops: ["</tool_call>"])
        XCTAssertEqual(out, "<<<<<ok</tool_call>")
        XCTAssertTrue(stopped)
    }

    func testFeedAfterStopIsIgnored() {
        var filter = StopSequenceFilter(stopSequences: ["</tool_call>"])
        _ = filter.feed("a</tool_call>b")
        let r = filter.feed("more text")
        XCTAssertEqual(r.emit, "")
        XCTAssertTrue(r.stopped)
        XCTAssertEqual(filter.finish(), "")
    }

    func testConcatenatedEmitsEqualExpectation() {
        // Property-style: for random splits of the same logical stream the
        // emitted concatenation must be identical.
        let full = "prefix text with some words</tool_call>suffix that must never appear"
        let stops = ["</tool_call>"]
        let expected = "prefix text with some words</tool_call>"
        let chars = Array(full)
        // Try every 2-way split and a few 3-way splits.
        for i in 0...chars.count {
            let a = String(chars[..<i])
            let b = String(chars[i...])
            let (out, _) = run([a, b], stops: stops)
            XCTAssertEqual(out, expected, "split at \(i)")
        }
        for i in stride(from: 0, to: chars.count, by: 7) {
            for j in stride(from: i, to: chars.count, by: 11) {
                let a = String(chars[..<i])
                let b = String(chars[i..<j])
                let c = String(chars[j...])
                let (out, _) = run([a, b, c], stops: stops)
                XCTAssertEqual(out, expected, "split at \(i), \(j)")
            }
        }
    }
}
