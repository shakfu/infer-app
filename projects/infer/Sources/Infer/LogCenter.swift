import Foundation
import SwiftUI

/// Severity of a log event. Ordered so the Console filter can
/// show "errors and above" without string comparisons.
enum LogLevel: Int, CaseIterable, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .warning: return "warn"
        case .error: return "error"
        }
    }

    var tint: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// A single structured observability record. Created at call sites that
/// previously wrote to stderr; displayed in the Console tab. `payload`
/// is a free-form string (often a stringified error or a small chunk of
/// JSON); kept as `String` rather than `Codable Any` so the type stays
/// trivially `Sendable` and the UI has a single rendering path.
struct LogEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    /// Short subsystem label ("vault", "whisper", "agents", "model").
    /// Used by the Console filter and shown monospaced in the row.
    let source: String
    let message: String
    /// Optional additional detail. Rendered as a secondary line in the
    /// row, truncated to a few lines but fully selectable / copyable.
    let payload: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        source: String,
        message: String,
        payload: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.source = source
        self.message = message
        self.payload = payload
    }
}

/// In-memory ring buffer of `LogEvent`s. One shared instance on
/// `ChatViewModel`; any `@MainActor` code can call `log(_:_:_:)`.
/// Capacity-bounded (oldest entries dropped); not persisted to disk —
/// intentional, the Console is a live observability surface, not an
/// audit log.
///
/// Non-`@MainActor` callers (speech taps, vault write continuations)
/// should hop via `Task { @MainActor in ... }` or use the thread-safe
/// `logFromBackground` convenience that schedules the append on the
/// main actor.
@Observable
@MainActor
final class LogCenter {
    static let capacity = 500

    private(set) var events: [LogEvent] = []
    /// Incremented on each append. Observers can bind to this to auto-
    /// scroll the Console to the bottom without diffing the full array.
    private(set) var appendCount: Int = 0

    func log(
        _ level: LogLevel,
        source: String,
        message: String,
        payload: String? = nil
    ) {
        let event = LogEvent(
            level: level,
            source: source,
            message: message,
            payload: payload
        )
        events.append(event)
        if events.count > Self.capacity {
            // Drop in chunks of 50 so the copy cost amortises over many
            // appends rather than firing on every single overflow.
            events.removeFirst(events.count - Self.capacity + 50)
        }
        appendCount &+= 1
        // Also mirror to stderr so a developer running the binary from
        // a shell still sees the output; the Console is additive, not
        // a replacement.
        let prefix = "[\(level.label)] [\(source)] "
        var line = prefix + message
        if let payload, !payload.isEmpty { line += " — " + payload }
        line += "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    func clear() {
        events.removeAll()
    }

    /// Format events as plain text for the clipboard. Respects an
    /// optional filter (same one the UI uses) so the user copies what
    /// they see.
    func formatForCopy(_ filter: LogFilter = LogFilter()) -> String {
        let df = ISO8601DateFormatter()
        return events
            .filter(filter.matches)
            .map { e in
                var line = "\(df.string(from: e.timestamp)) [\(e.level.label)] [\(e.source)] \(e.message)"
                if let p = e.payload, !p.isEmpty { line += "\n    " + p.replacingOccurrences(of: "\n", with: "\n    ") }
                return line
            }
            .joined(separator: "\n")
    }
}

/// Nonisolated schedule helper for call sites that can't easily hop to
/// the main actor (e.g. inside a `Task.detached` or a C callback).
/// Because `LogCenter` is `@MainActor`-isolated, this wraps the append
/// in `Task { @MainActor in ... }`.
extension LogCenter {
    nonisolated func logFromBackground(
        _ level: LogLevel,
        source: String,
        message: String,
        payload: String? = nil
    ) {
        Task { @MainActor [weak self] in
            self?.log(level, source: source, message: message, payload: payload)
        }
    }
}

/// Filter state for the Console UI. Kept as a value type so it's cheap
/// to share between the view and `formatForCopy`.
struct LogFilter: Equatable {
    var minLevel: LogLevel = .debug
    /// Empty means "all sources."
    var sources: Set<String> = []
    /// Case-insensitive substring applied to message + payload.
    var query: String = ""

    func matches(_ event: LogEvent) -> Bool {
        if event.level < minLevel { return false }
        if !sources.isEmpty, !sources.contains(event.source) { return false }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let haystack = event.message + " " + (event.payload ?? "")
            if haystack.range(of: q, options: .caseInsensitive) == nil { return false }
        }
        return true
    }
}
