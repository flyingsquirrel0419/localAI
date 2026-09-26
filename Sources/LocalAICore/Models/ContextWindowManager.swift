import Foundation

/// Trims chat history to a token budget. Uses a ~4 chars/token heuristic,
/// keeps the system prompt and the most recent messages, and replaces dropped
/// tool outputs with "[truncated]" markers.
public struct ContextWindowManager: Sendable {
    public let tokenBudget: Int
    /// Rough chars-per-token estimate for English/code text.
    public static let charsPerToken = 4

    public init(tokenBudget: Int) {
        self.tokenBudget = tokenBudget
    }

    public func estimateTokens(_ text: String) -> Int {
        max(1, text.count / Self.charsPerToken)
    }

    public func estimateTokens(_ message: ChatMessage) -> Int {
        estimateTokens(message.content) + 4 // role/formatting overhead
    }

    /// Produce a history that fits within the budget.
    ///
    /// - System messages are always kept (first one, at minimum).
    /// - Newest non-system messages are kept greedily from the end.
    /// - Dropped tool messages contribute a single `[truncated]` marker at the
    ///   position of the earliest dropped region so the model knows context
    ///   was elided.
    public func trim(_ messages: [ChatMessage]) -> [ChatMessage] {
        let system = messages.filter { $0.role == .system }
        let conversation = messages.filter { $0.role != .system }

        var remaining = tokenBudget
        for s in system { remaining -= estimateTokens(s) }
        if remaining < 0 { remaining = 0 }

        // Walk conversation from newest to oldest, keeping what fits.
        var keptReversed: [ChatMessage] = []
        var droppedAny = false
        var droppedTool = false
        for message in conversation.reversed() {
            let cost = estimateTokens(message)
            if cost <= remaining {
                keptReversed.append(message)
                remaining -= cost
            } else {
                droppedAny = true
                if message.role == .tool { droppedTool = true }
            }
        }

        var result = system
        if droppedTool {
            result.append(ChatMessage(role: .tool, content: "[truncated]"))
        } else if droppedAny {
            result.append(ChatMessage(role: .assistant, content: "[truncated]"))
        }
        result.append(contentsOf: keptReversed.reversed())
        return result
    }
}
