import Foundation

/// Pure-Swift helpers for the on-disk log persistence layer
/// (`LogPersister` lives in the executable target). Extracted here
/// so the rotation / retention logic is unit-testable without
/// `@testable`-importing `Infer` and without requiring real
/// filesystem state. Each helper is a function of primitives —
/// dates, filenames, calendars — so a test can drive them with
/// hand-built inputs.
public enum LogPersistenceHelpers {

    /// Filename-friendly daily bucket for a timestamp. Format
    /// `YYYY-MM-DD` so files sort lexically AND chronologically.
    /// Calendar is parameterised so tests don't depend on the host
    /// machine's locale; production passes `.current` or a UTC
    /// calendar — the persister picks one and sticks with it so
    /// midnight-boundary rotation is deterministic.
    public static func dateBucket(for timestamp: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: timestamp)
        let y = comps.year ?? 1970
        let m = comps.month ?? 1
        let d = comps.day ?? 1
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// Filename for a daily log file given its bucket. Centralised
    /// so reads and writes stay in lockstep.
    public static func filename(forBucket bucket: String) -> String {
        "\(bucket).jsonl"
    }

    /// Inverse of `filename(forBucket:)` — pull the bucket out of a
    /// filename, or nil if the filename doesn't match the
    /// `YYYY-MM-DD.jsonl` shape. Used by retention to filter the
    /// directory listing to log files (and ignore any other files
    /// the user / OS may have parked there).
    public static func bucket(fromFilename name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(".jsonl".count))
        // Validate the YYYY-MM-DD shape rather than just trusting
        // any `*.jsonl` — a stray `crash.jsonl` parked in the dir
        // shouldn't be treated as a log file the persister owns.
        guard stem.count == 10 else { return nil }
        let chars = Array(stem)
        for i in 0..<10 {
            switch i {
            case 4, 7:
                if chars[i] != "-" { return nil }
            default:
                if !chars[i].isASCII || !chars[i].isNumber { return nil }
            }
        }
        return stem
    }

    /// Filenames that have aged out of the retention horizon and
    /// should be deleted. `currentBucket` is today's bucket as the
    /// persister sees it; horizonDays is the inclusive look-back
    /// (e.g. `14` keeps today + the prior 13 days). Filenames are
    /// sorted ascending in the returned array so a test can assert
    /// the order easily.
    ///
    /// Files whose name doesn't match the persister's filename
    /// shape are NOT pruned — the persister doesn't own them, and
    /// silently deleting unknown files in a user-visible directory
    /// would be hostile.
    public static func filenamesToPrune(
        in directoryListing: [String],
        currentBucket: String,
        horizonDays: Int,
        calendar: Calendar
    ) -> [String] {
        guard horizonDays >= 1 else { return [] }
        guard let currentDate = parseBucket(currentBucket, calendar: calendar) else {
            return []
        }
        guard let horizonStart = calendar.date(
            byAdding: .day,
            value: -(horizonDays - 1),
            to: currentDate
        ) else { return [] }
        return directoryListing.compactMap { name -> String? in
            guard let bucket = self.bucket(fromFilename: name) else { return nil }
            guard let date = parseBucket(bucket, calendar: calendar) else { return nil }
            return date < horizonStart ? name : nil
        }.sorted()
    }

    /// Parse a `YYYY-MM-DD` bucket string back to a `Date`
    /// representing midnight on that day in the supplied calendar.
    /// Returns nil for malformed input — a defensive parse so
    /// hand-edited / corrupted directories don't crash the
    /// persister at startup.
    public static func parseBucket(_ bucket: String, calendar: Calendar) -> Date? {
        let parts = bucket.split(separator: "-")
        guard parts.count == 3 else { return nil }
        guard let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        return calendar.date(from: comps)
    }
}
