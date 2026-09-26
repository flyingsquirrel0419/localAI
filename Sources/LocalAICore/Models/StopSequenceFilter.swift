import Foundation

/// Streaming stop-sequence filter for token-by-token generation.
///
/// Feed it chunks; it returns the text that is safe to emit, guaranteeing:
/// - Everything up to AND INCLUDING the first stop string is emitted exactly
///   once (no drops, no duplicates).
/// - After a stop is found, all further input is swallowed (`stopped == true`).
/// - If no stop ever appears, `finish()` flushes the held-back tail verbatim.
///
/// A stop string can be split across chunk boundaries, so the filter holds
/// back only the longest trailing prefix of any stop string. With stops
/// `["</tool_call>"]` and chunks `["foo</tool", "_call>bar"]`, the emits are
/// `"foo"` (holding `</tool`) then `"</tool_call>"` and stopped.
///
/// Pure value type: no async, no Foundation streaming, trivially testable.
public struct StopSequenceFilter: Sendable {
    private let stops: [String]
    /// Longest stop-string length; 0 when there are no stops (pass-through).
    private let maxStopLength: Int
    /// Text not yet emitted because it might be the start of a stop string.
    private var held: String = ""
    public private(set) var stopped: Bool = false

    public init(stopSequences: [String]) {
        let cleaned = stopSequences.filter { !$0.isEmpty }
        self.stops = cleaned
        self.maxStopLength = cleaned.map(\.count).max() ?? 0
    }

    /// Feed one chunk. Returns the text to emit now (possibly empty) and
    /// whether a stop string was just hit (after which the caller should stop
    /// feeding; later chunks are ignored).
    public mutating func feed(_ chunk: String) -> (emit: String, stopped: Bool) {
        if stopped { return ("", true) }
        if stops.isEmpty { return (chunk, false) }
        held += chunk
        if let hit = Self.firstStop(in: held, stops: stops) {
            // Emit through the end of the stop marker, swallow the rest.
            let endOffset = hit.lowerBoundOffset + hit.length
            let emit = String(held.prefix(endOffset))
            held = ""
            stopped = true
            return (emit, true)
        }
        // No stop: release everything except a trailing partial-stop prefix.
        let holdCount = Self.partialStopPrefixLength(of: held, stops: stops)
        let emitCount = held.count - holdCount
        if emitCount <= 0 { return ("", false) }
        let emit = String(held.prefix(emitCount))
        held = String(held.suffix(holdCount))
        return (emit, false)
    }

    /// Flush any held text. Call once at end-of-stream. Returns the remaining
    /// tail verbatim when no stop was ever hit (a trailing partial stop prefix
    /// is real text in that case), or "" when a stop already fired.
    public mutating func finish() -> String {
        defer { held = "" }
        if stopped { return "" }
        // A complete stop could be sitting entirely inside `held` when the
        // stream ended before we could emit it — but feed() checks for stops
        // before holding, so `held` can only contain a *partial* prefix.
        return held
    }

    // MARK: - Internals (static for testability)

    /// Earliest occurrence of any stop string in `text`, as a character offset
    /// from `text.startIndex` plus the matched stop's length. Offsets (not
    /// String.Index) are returned because indices from `range(of:)` are not
    /// portable across String values.
    static func firstStop(
        in text: String,
        stops: [String]
    ) -> (lowerBoundOffset: Int, length: Int)? {
        var best: (Int, Int)? = nil
        for stop in stops where !stop.isEmpty {
            if let range = text.range(of: stop) {
                let offset = text.distance(from: text.startIndex, to: range.lowerBound)
                if let current = best {
                    if offset < current.0 { best = (offset, stop.count) }
                } else {
                    best = (offset, stop.count)
                }
            }
        }
        return best
    }

    /// Length of the longest suffix of `text` that is a proper prefix of any
    /// stop string — i.e. how many trailing characters could still become a
    /// stop string with more input. 0 when no stop can start at the tail.
    static func partialStopPrefixLength(of text: String, stops: [String]) -> Int {
        let maxLen = stops.map(\.count).max() ?? 0
        guard maxLen > 1, !text.isEmpty else { return 0 }
        let textChars = Array(text)
        let upper = min(textChars.count, maxLen - 1)
        for length in stride(from: upper, through: 1, by: -1) {
            let tail = textChars[(textChars.count - length)...]
            for stop in stops {
                let stopChars = Array(stop)
                if stopChars.count > length, Array(stopChars[..<length]) == Array(tail) {
                    return length
                }
            }
        }
        return 0
    }
}
