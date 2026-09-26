import Foundation

public struct ToolCall: Equatable {
    public let id: String
    public let tool: String
    /// JSON-decoded arguments. Values are String, Int, Double, Bool, arrays/dicts of those.
    public let arguments: [String: Any]

    public static func == (lhs: ToolCall, rhs: ToolCall) -> Bool {
        lhs.id == rhs.id && lhs.tool == rhs.tool && NSDictionary(dictionary: lhs.arguments).isEqual(rhs.arguments)
    }

    public init(id: String = UUID().uuidString, tool: String, arguments: [String: Any]) {
        self.id = id
        self.tool = tool
        self.arguments = arguments
    }
}

extension ToolCall: Sendable {
    // JSON-typed values only (String/Number/Bool/Array/Dict/NSNull); safe to share.
}

public enum ParsedOutput: Sendable, Equatable {
    /// A complete, parseable tool call.
    case toolCall(ToolCall, remainingText: String)
    /// No tool call — the model's answer text.
    case finalAnswer(String)
    /// Something that looked like a tool call but failed validation; the
    /// associated message should be fed back to the model.
    case parseError(message: String, raw: String)
}

/// Extracts tool calls from model output. Accepts:
///   <tool_call>{"tool":"read_file","arguments":{"path":"a"}}</tool_call>
///   <tool_call>{"name":"read_file","arguments":{"path":"a"}}</tool_call>   (Qwen/Hermes)
///   ```json {"tool": "..."} ```                                          (fenced)
/// Tolerates trailing commas. Never fabricates arguments — malformed input
/// becomes `.parseError` for the loop to feed back to the model.
public enum ToolCallParser {

    public static func parse(_ text: String) -> ParsedOutput {
        // Strip <think>...</think> (and trailing unclosed <think>) so a model
        // that reasons before its first <tool_call> doesn't get mis-parsed.
        let cleaned = stripThinkBlocks(text)
        // 1. <tool_call> ... </tool_call>
        if let range = cleaned.range(of: "<tool_call>") {
            let afterOpen = cleaned[range.upperBound...]
            let bodyEnd = afterOpen.range(of: "</tool_call>")
            let body = bodyEnd.map { String(afterOpen[afterOpen.startIndex..<$0.lowerBound]) }
                ?? String(afterOpen)
            let remaining = bodyEnd.map { String(afterOpen[$0.upperBound...]) } ?? ""
            return interpret(body: body, remaining: remaining, fallback: cleaned)
        }
        // 2. ```json ... ```
        if let fenced = extractFencedJSON(from: cleaned) {
            return interpret(body: fenced.body, remaining: fenced.remaining, fallback: cleaned)
        }
        // 3. No markup — treat as final answer.
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return .finalAnswer(trimmed)
    }

    /// Remove all complete and trailing-unclosed <think>...</think> spans.
    /// Exposed for direct callers that don't go through `parse` (e.g. tests).
    public static func stripThinkBlocks(_ text: String) -> String {
        var out = ""
        var s = text
        while let open = s.range(of: "<think>") {
            out += s[s.startIndex..<open.lowerBound]
            let after = s[open.upperBound...]
            if let close = after.range(of: "</think>") {
                s = String(after[close.upperBound...])
            } else {
                return out
            }
        }
        out += s
        return out
    }

    private static func interpret(body: String, remaining: String, fallback: String) -> ParsedOutput {
        let cleaned = stripTrailingCommas(body.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = cleaned.data(using: .utf8) else {
            return .parseError(message: "Tool call body is not valid UTF-8.", raw: body)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .parseError(
                message: "Could not parse tool call JSON. Use the format <tool_call>{\"tool\":\"name\",\"arguments\":{...}}</tool_call>.",
                raw: body
            )
        }
        let toolName = (obj["tool"] as? String) ?? (obj["name"] as? String)
        guard let toolName, !toolName.isEmpty else {
            return .parseError(message: "Tool call is missing the \"tool\" field.", raw: body)
        }
        let arguments = (obj["arguments"] as? [String: Any]) ?? (obj["parameters"] as? [String: Any]) ?? [:]
        guard JSONSerialization.isValidJSONObject(arguments) else {
            return .parseError(message: "Tool arguments are not valid JSON.", raw: body)
        }
        return .toolCall(ToolCall(tool: toolName, arguments: arguments), remainingText: remaining)
    }

    /// Extract the first fenced ```json ... ``` block, or a bare ``` block
    /// whose first non-space character is `{`.
    private static func extractFencedJSON(from text: String) -> (body: String, remaining: String)? {
        guard let open = text.range(of: "```") else { return nil }
        let afterOpen = text[open.upperBound...]
        // Consume an optional language tag up to the newline.
        guard let newline = afterOpen.firstIndex(of: "\n") else { return nil }
        let tag = String(afterOpen[afterOpen.startIndex..<newline]).trimmingCharacters(in: .whitespaces)
        guard tag.isEmpty || tag.lowercased() == "json" else { return nil }
        let contentStart = afterOpen.index(after: newline)
        guard let close = text.range(of: "```", range: contentStart..<text.endIndex) else { return nil }
        let body = String(text[contentStart..<close.lowerBound])
        if tag.isEmpty {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{") else { return nil }
        }
        let remaining = String(text[close.upperBound...])
        return (body, remaining)
    }

    /// Remove trailing commas before `}` or `]` — a common small-model slip.
    static func stripTrailingCommas(_ text: String) -> String {
        // Only safe outside string literals; do a small state machine.
        var result = ""
        result.reserveCapacity(text.count)
        var inString = false
        var escaped = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                result.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" {
                inString = true
                result.append(c)
                i += 1
                continue
            }
            if c == "," {
                // Look ahead past whitespace.
                var j = i + 1
                while j < chars.count && (chars[j] == " " || chars[j] == "\n" || chars[j] == "\t" || chars[j] == "\r") {
                    j += 1
                }
                if j < chars.count && (chars[j] == "}" || chars[j] == "]") {
                    i += 1 // drop the comma
                    continue
                }
            }
            result.append(c)
            i += 1
        }
        return result
    }
}
