import XCTest
@testable import InferAppCore

final class LogPersistenceHelpersTests: XCTestCase {

    // Use a UTC calendar so test results don't drift with the host
    // machine's locale / DST. Production picks `.current` and pins
    // it for the persister's lifetime, which has the same property.
    private let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = hour
        comps.timeZone = TimeZone(identifier: "UTC")!
        return Calendar(identifier: .gregorian).date(from: comps)!
    }

    // MARK: - dateBucket

    func testDateBucketProducesIso8601DateOnly() {
        let d = date(2026, 5, 10)
        XCTAssertEqual(LogPersistenceHelpers.dateBucket(for: d, calendar: utc), "2026-05-10")
    }

    func testDateBucketPadsSingleDigitMonthAndDay() {
        let d = date(2026, 1, 3)
        XCTAssertEqual(LogPersistenceHelpers.dateBucket(for: d, calendar: utc), "2026-01-03")
    }

    func testDateBucketIgnoresTimeOfDay() {
        // Midnight UTC and 23:59 UTC on the same day produce the
        // same bucket. The persister relies on this for rotation —
        // the bucket changes only when the calendar day changes.
        let morning = date(2026, 5, 10, hour: 0)
        let evening = date(2026, 5, 10, hour: 23)
        XCTAssertEqual(
            LogPersistenceHelpers.dateBucket(for: morning, calendar: utc),
            LogPersistenceHelpers.dateBucket(for: evening, calendar: utc)
        )
    }

    // MARK: - filename / bucket round-trip

    func testFilenameAppendsExtension() {
        XCTAssertEqual(LogPersistenceHelpers.filename(forBucket: "2026-05-10"), "2026-05-10.jsonl")
    }

    func testBucketRoundTripsThroughFilename() {
        let bucket = "2026-05-10"
        let name = LogPersistenceHelpers.filename(forBucket: bucket)
        XCTAssertEqual(LogPersistenceHelpers.bucket(fromFilename: name), bucket)
    }

    func testBucketRejectsNonLogFile() {
        // Any file the user / OS parks in the directory that doesn't
        // match `YYYY-MM-DD.jsonl` is NOT considered a log file.
        // Retention won't prune it, and the persister won't try to
        // append to it.
        XCTAssertNil(LogPersistenceHelpers.bucket(fromFilename: "crash.jsonl"))
        XCTAssertNil(LogPersistenceHelpers.bucket(fromFilename: "2026-05-10.txt"))
        XCTAssertNil(LogPersistenceHelpers.bucket(fromFilename: ".DS_Store"))
        XCTAssertNil(LogPersistenceHelpers.bucket(fromFilename: "2026/05/10.jsonl"))
        XCTAssertNil(LogPersistenceHelpers.bucket(fromFilename: "2026-5-10.jsonl"),
                     "bucket parser requires zero-padded month/day")
    }

    // MARK: - parseBucket

    func testParseBucketReturnsMidnightInGivenCalendar() {
        let parsed = LogPersistenceHelpers.parseBucket("2026-05-10", calendar: utc)
        XCTAssertNotNil(parsed)
        let comps = utc.dateComponents([.year, .month, .day, .hour, .minute], from: parsed!)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 5)
        XCTAssertEqual(comps.day, 10)
        XCTAssertEqual(comps.hour, 0)
        XCTAssertEqual(comps.minute, 0)
    }

    func testParseBucketReturnsNilForMalformedInput() {
        XCTAssertNil(LogPersistenceHelpers.parseBucket("not-a-date", calendar: utc))
        XCTAssertNil(LogPersistenceHelpers.parseBucket("2026-05", calendar: utc))
        XCTAssertNil(LogPersistenceHelpers.parseBucket("", calendar: utc))
    }

    // MARK: - filenamesToPrune

    func testFilenamesToPruneKeepsTodayAndPriorThirteenDays() {
        // 14-day retention: today + 13 prior days are kept; the
        // 14th-day-back (and beyond) gets pruned.
        let listing = [
            "2026-04-25.jsonl", // 15 days back → prune
            "2026-04-26.jsonl", // 14 days back → prune
            "2026-04-27.jsonl", // 13 days back → keep (the boundary day)
            "2026-05-09.jsonl", // 1 day back → keep
            "2026-05-10.jsonl", // today → keep
        ]
        let pruned = LogPersistenceHelpers.filenamesToPrune(
            in: listing,
            currentBucket: "2026-05-10",
            horizonDays: 14,
            calendar: utc
        )
        XCTAssertEqual(pruned, ["2026-04-25.jsonl", "2026-04-26.jsonl"])
    }

    func testFilenamesToPruneIgnoresNonLogFiles() {
        // A `.DS_Store` or hand-edited log file in the directory
        // must not be returned as prune-eligible — the persister
        // only deletes files it owns.
        let listing = [
            "2026-04-01.jsonl", // far past, prune-eligible
            ".DS_Store",        // not ours
            "crash.txt",        // not ours
            "2026-05-10.jsonl", // today
        ]
        let pruned = LogPersistenceHelpers.filenamesToPrune(
            in: listing,
            currentBucket: "2026-05-10",
            horizonDays: 14,
            calendar: utc
        )
        XCTAssertEqual(pruned, ["2026-04-01.jsonl"],
                       "non-log files must not appear in the prune list")
    }

    func testFilenamesToPruneReturnsEmptyForZeroOrNegativeHorizon() {
        let listing = ["2026-04-01.jsonl", "2026-05-10.jsonl"]
        XCTAssertEqual(
            LogPersistenceHelpers.filenamesToPrune(
                in: listing,
                currentBucket: "2026-05-10",
                horizonDays: 0,
                calendar: utc
            ),
            [],
            "horizonDays = 0 disables pruning rather than pruning everything"
        )
        XCTAssertEqual(
            LogPersistenceHelpers.filenamesToPrune(
                in: listing,
                currentBucket: "2026-05-10",
                horizonDays: -5,
                calendar: utc
            ),
            []
        )
    }

    func testFilenamesToPruneReturnsEmptyForMalformedCurrentBucket() {
        // Defensive: if the persister somehow passes a bad current
        // bucket, the prune routine refuses to delete anything
        // (better to keep extra files than blow away real data).
        let pruned = LogPersistenceHelpers.filenamesToPrune(
            in: ["2026-04-01.jsonl", "2026-05-10.jsonl"],
            currentBucket: "not-a-date",
            horizonDays: 14,
            calendar: utc
        )
        XCTAssertEqual(pruned, [])
    }

    func testFilenamesToPruneIsSorted() {
        // Stable sort makes test assertions and any UI listing
        // deterministic, regardless of FileManager's filesystem
        // ordering.
        let listing = [
            "2026-03-15.jsonl",
            "2026-01-02.jsonl",
            "2026-02-10.jsonl",
        ]
        let pruned = LogPersistenceHelpers.filenamesToPrune(
            in: listing,
            currentBucket: "2026-05-10",
            horizonDays: 14,
            calendar: utc
        )
        XCTAssertEqual(pruned, [
            "2026-01-02.jsonl",
            "2026-02-10.jsonl",
            "2026-03-15.jsonl",
        ])
    }
}
