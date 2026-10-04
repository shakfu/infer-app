import Foundation

/// Streaming stop-sequence detector for the local runners (llama, MLX).
/// Cloud providers apply `stop` / `stop_sequences` server-side.
///
/// `feed(_:)` returns the text safe to emit. A tail that could be the
/// start of a stop sequence is held back until the next chunk decides
/// it. On a match, output ends before the stop sequence (matching the
/// cloud APIs, which exclude it) and `stopped` becomes true; later
/// feeds return "". `flush()` releases the held tail at end-of-stream.
public struct StopSequenceMatcher: Sendable {
    public let stops: [String]
    public private(set) var stopped = false
    private var pending = ""

    public init(_ stops: [String]) {
        self.stops = stops.filter { !$0.isEmpty }
    }

    public mutating func feed(_ chunk: String) -> String {
        guard !stopped else { return "" }
        guard !stops.isEmpty else { return chunk }
        pending += chunk

        var cut: String.Index?
        for stop in stops {
            if let r = pending.range(of: stop, options: .literal),
               cut.map({ r.lowerBound < $0 }) ?? true {
                cut = r.lowerBound
            }
        }
        if let cut {
            stopped = true
            let out = String(pending[..<cut])
            pending = ""
            return out
        }

        let hold = heldTailLength()
        let out = String(pending.dropLast(hold))
        pending = String(pending.suffix(hold))
        return out
    }

    public mutating func flush() -> String {
        defer { pending = "" }
        return stopped ? "" : pending
    }

    /// Length of the longest suffix of `pending` that is a proper
    /// prefix of some stop sequence.
    private func heldTailLength() -> Int {
        let longest = stops.map(\.count).max() ?? 0
        let maxLen = Swift.min(pending.count, longest - 1)
        guard maxLen > 0 else { return 0 }
        for n in stride(from: maxLen, through: 1, by: -1) {
            let tail = pending.suffix(n)
            if stops.contains(where: { $0.hasPrefix(tail) }) { return n }
        }
        return 0
    }
}
