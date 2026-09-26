import XCTest
@testable import LocalAICore

final class ToolCallParserTests: XCTestCase {

    func testPrimaryFormat() {
        let text = #"<tool_call>{"tool":"read_file","arguments":{"path":"src/a.ts"}}</tool_call>"#
        guard case .toolCall(let call, _) = ToolCallParser.parse(text) else {
            XCTFail("expected toolCall"); return
        }
        XCTAssertEqual(call.tool, "read_file")
        XCTAssertEqual(call.arguments["path"] as? String, "src/a.ts")
    }

    func testQwenStyleName() {
        let text = #"<tool_call>{"name":"git_status","arguments":{}}</tool_call>"#
        guard case .toolCall(let call, _) = ToolCallParser.parse(text) else {
            XCTFail("expected toolCall"); return
        }
        XCTAssertEqual(call.tool, "git_status")
    }

    func testFencedJSON() {
        let text = """
        Let me read that file.
        ```json
        {"tool": "read_file", "arguments": {"path": "x.ts"}}
        ```
        """
        guard case .toolCall(let call, _) = ToolCallParser.parse(text) else {
            XCTFail("expected toolCall"); return
        }
        XCTAssertEqual(call.tool, "read_file")
        XCTAssertEqual(call.arguments["path"] as? String, "x.ts")
    }

    func testTrailingCommas() {
        let text = #"<tool_call>{"tool":"git_add","arguments":{"paths":["a","b",],},}</tool_call>"#
        guard case .toolCall(let call, _) = ToolCallParser.parse(text) else {
            XCTFail("expected toolCall"); return
        }
        XCTAssertEqual(call.tool, "git_add")
        XCTAssertEqual(call.arguments["paths"] as? [String], ["a", "b"])
    }

    func testFinalAnswer() {
        let text = "Done! I fixed the bug in router.ts."
        guard case .finalAnswer(let answer) = ToolCallParser.parse(text) else {
            XCTFail("expected finalAnswer"); return
        }
        XCTAssertEqual(answer, text)
    }

    func testParseErrorOnMalformedJSON() {
        let text = "<tool_call>{not json}</tool_call>"
        guard case .parseError(let message, _) = ToolCallParser.parse(text) else {
            XCTFail("expected parseError"); return
        }
        XCTAssertTrue(message.contains("Could not parse"))
    }

    func testParseErrorOnMissingToolField() {
        let text = #"<tool_call>{"arguments":{}}</tool_call>"#
        guard case .parseError = ToolCallParser.parse(text) else {
            XCTFail("expected parseError"); return
        }
    }
}
