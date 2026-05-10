import Foundation
import InferAppCore

/// On-disk persistence for `LogEvent`s. Daily-rotated JSONL files
/// under `Application Support/Infer/logs/`. Each line is one
/// JSON-encoded record; partial writes (process killed mid-line)
/// at worst lose the in-flight event, and the next launch picks up
/// from the same daily file or rotates to today's bucket.
///
/// **Sync writes from the main actor.** Matches the existing
/// stderr mirror (`LogCenter.log` writes both); each file write is
/// a single `FileHandle.write` call which is fast (kernel-buffered)
/// even at boot-time bursts. Async + actor-hop was rejected because
/// per-event Task creation costs more than the syscall it'd save,
/// and the ordering guarantee (events appear in the file in the
/// order they were logged) is preserved trivially with sync writes.
///
/// Failures are silently dropped — the persister is best-effort
/// observability, NOT a transactional log. A broken disk shouldn't
/// fail a chat turn.
@MainActor
final class LogPersister {

    /// Days of history to keep on disk. Older daily files are
    /// pruned at launch and after each daily rotation. 14 days fits
    /// "I had a problem last week, can you check the logs" without
    /// growing unbounded; tweak via the `retentionDays` init
    /// parameter for testing or per-deployment policy.
    private let retentionDays: Int

    /// Calendar used to bucket events by day. Pinned at init so
    /// midnight-boundary rotation behaves deterministically; tests
    /// inject a fixture, production uses `.current`.
    private let calendar: Calendar

    /// Root logs directory. Created at first use if absent. Public
    /// so callers (e.g. the "Reveal logs…" button) can hand it
    /// straight to `NSWorkspace`.
    let directory: URL

    private var currentBucket: String?
    private var currentFileURL: URL?
    private var fileHandle: FileHandle?
    private var encoder: JSONEncoder

    init(
        directory: URL? = nil,
        retentionDays: Int = 14,
        calendar: Calendar = .current
    ) {
        self.directory = directory ?? Self.defaultDirectory()
        self.retentionDays = retentionDays
        self.calendar = calendar
        let enc = JSONEncoder()
        // No `prettyPrinted` — the format is JSONL; one record per
        // line so each `\n` terminates a complete value. Sorted keys
        // for deterministic output (helps diffs and tests).
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = enc
        // Opportunistic prune at startup; failures here are silent
        // (worst case the dir holds a few extra days of files).
        self.pruneOldLogs()
    }

    /// Write one event to today's log file. Performs daily-bucket
    /// rotation transparently — when the bucket changes (midnight
    /// crossover, or a clock skip), closes the current handle and
    /// opens the new file.
    func append(_ event: LogEvent) {
        let bucket = LogPersistenceHelpers.dateBucket(for: event.timestamp, calendar: calendar)
        if bucket != currentBucket {
            rotateTo(bucket: bucket)
        }
        guard let fileHandle else { return }
        guard let line = encode(event) else { return }
        do {
            try fileHandle.write(contentsOf: line)
        } catch {
            // Best-effort: drop the write. Don't crash a chat turn
            // because the log disk filled up. Could log to stderr
            // but that risks a feedback loop if stderr is wedged.
        }
    }

    /// Close the current file handle. Called by `AppDelegate.applicationWillTerminate`
    /// alongside the rest of the per-runner shutdowns so any
    /// kernel-buffered bytes flush before exit.
    func close() {
        try? fileHandle?.close()
        fileHandle = nil
        currentBucket = nil
        currentFileURL = nil
    }

    // MARK: - Private

    private func rotateTo(bucket: String) {
        try? fileHandle?.close()
        fileHandle = nil
        currentBucket = bucket
        currentFileURL = nil

        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return
        }
        let url = directory.appendingPathComponent(
            LogPersistenceHelpers.filename(forBucket: bucket)
        )
        currentFileURL = url
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        do {
            let fh = try FileHandle(forWritingTo: url)
            try fh.seekToEnd()
            fileHandle = fh
        } catch {
            fileHandle = nil
        }
        // Prune after rotation too: the user keeps the app open
        // across midnight, so we'd otherwise wait until the next
        // launch to drop yesterday's-yesterday-yesterday.
        pruneOldLogs()
    }

    private func encode(_ event: LogEvent) -> Data? {
        let record = LogRecord(event: event)
        guard var line = try? encoder.encode(record) else { return nil }
        line.append(0x0A) // '\n' — JSONL line terminator
        return line
    }

    /// Drop log files whose bucket is older than the retention
    /// horizon. Best-effort: failures are silent (a permission
    /// hiccup mustn't block the app).
    private func pruneOldLogs() {
        let bucketToday = LogPersistenceHelpers.dateBucket(for: Date(), calendar: calendar)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return
        }
        let toPrune = LogPersistenceHelpers.filenamesToPrune(
            in: names,
            currentBucket: bucketToday,
            horizonDays: retentionDays,
            calendar: calendar
        )
        for name in toPrune {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("Infer", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }
}

/// On-disk shape for a `LogEvent`. Distinct from `LogEvent` itself
/// because the in-memory type uses a SwiftUI `Color` indirectly via
/// `LogLevel.tint`, and we don't want SwiftUI in the on-disk
/// schema. Fields are short ("ts", "lvl") to keep individual lines
/// compact — at 14 days × N events / day this saves real bytes.
private struct LogRecord: Codable, Sendable, Equatable {
    let id: String
    let ts: TimeInterval
    let lvl: String
    let src: String
    let msg: String
    let pld: String?

    init(event: LogEvent) {
        self.id = event.id.uuidString
        self.ts = event.timestamp.timeIntervalSince1970
        self.lvl = event.level.label
        self.src = event.source
        self.msg = event.message
        self.pld = event.payload
    }
}
