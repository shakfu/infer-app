import Foundation
import SQLiteVec
import GRDB

// Spike verifying SQLiteVec + sqlite-vec round-trip end-to-end on
// macOS with Apple's stripped system SQLite present in the link
// graph (from GRDB). SQLiteVec bundles its own SQLite amalgamation
// with `SQLITE_CORE`, so sqlite-vec is registered via
// `sqlite3_auto_extension` against the bundled SQLite — not Apple's.
//
// Throwaway after RAG Phase 1 confirms the approach.
//
// What this checks:
//   1. `SQLiteVec.initialize()` succeeds (registers the extension
//      with the bundled SQLite's auto-extension machinery).
//   2. `Database(.inMemory)` opens a connection using the bundled
//      SQLite; sqlite-vec's `vec0` virtual table is available.
//   3. Inserts of `[Float]` vectors via the MATCH operator work.
//   4. KNN query via MATCH returns rows in ascending-distance order.
//   5. Distances match expected values for well-known vectors.
//
// If all five pass, Phase 1 of `docs/dev/rag.plan` is unblocked.

enum SmokeError: Error {
    case unexpectedOrder([Int])
    case zeroRows
    case distanceOutOfRange(Double)
}

@main
struct Main {
    static func main() async {
        do {
            try await run()
            print("SQLiteVec smoke: OK")
            exit(0)
        } catch {
            print("SQLiteVec smoke: FAILED — \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        print("SQLiteVec smoke test")

        // 1. Initialize SQLiteVec — registers sqlite-vec with the
        //    bundled SQLite's auto-extension table so every subsequent
        //    connection gets `vec0` and friends.
        try SQLiteVec.initialize()

        // 2. Open an in-memory DB and create a `vec0` virtual table.
        let db = try Database(.inMemory)
        try await db.execute(
            "CREATE VIRTUAL TABLE vec_items USING vec0(embedding float[4])"
        )

        // 3. Insert synthetic 4-dim vectors. `north` == the query
        //    (distance 0); `north2` ≈ the query; `east` and `south`
        //    are orthogonal / antiparallel; `random` is a
        //    general-direction distractor.
        let samples: [(index: Int, label: String, vector: [Float])] = [
            (1, "north",  [0.0,  1.0,  0.0,  0.0]),
            (2, "north2", [0.01, 0.99, 0.0,  0.0]),
            (3, "east",   [1.0,  0.0,  0.0,  0.0]),
            (4, "south",  [0.0, -1.0,  0.0,  0.0]),
            (5, "random", [0.5,  0.3, -0.2,  0.7]),
        ]
        for row in samples {
            try await db.execute(
                """
                    INSERT INTO vec_items(rowid, embedding)
                    VALUES (?, ?)
                """,
                params: [row.index, row.vector]
            )
        }

        // 4. KNN query: a vector pointing north. Expect `north` first
        //    (distance 0), then `north2` (tiny distance).
        let query: [Float] = [0.0, 1.0, 0.0, 0.0]
        let rows = try await db.query(
            """
                SELECT rowid, distance
                FROM vec_items
                WHERE embedding MATCH ?
                ORDER BY distance
                LIMIT 5
            """,
            params: [query]
        )

        guard !rows.isEmpty else { throw SmokeError.zeroRows }
        print("  returned \(rows.count) rows:")
        // SQLiteVec returns numeric columns as `Int` / `Double` on macOS
        // (not `Int64`). Cast accordingly.
        for row in rows {
            let rowid = (row["rowid"] as? Int) ?? Int(row["rowid"] as? Int64 ?? -1)
            let dist = row["distance"] as? Double ?? .nan
            let label = samples.first { $0.index == rowid }?.label ?? "?"
            print("    rowid=\(rowid) label=\(label) distance=\(String(format: "%.4f", dist))")
        }

        // 5. Assertions.
        let orderedIds: [Int] = rows.compactMap { row in
            (row["rowid"] as? Int)
                ?? (row["rowid"] as? Int64).map(Int.init)
        }
        // `north` must be the top hit.
        guard orderedIds.first == 1 else {
            throw SmokeError.unexpectedOrder(orderedIds)
        }
        print("  ✓ north is the top hit")

        // `north2` second.
        guard orderedIds.count >= 2, orderedIds[1] == 2 else {
            throw SmokeError.unexpectedOrder(orderedIds)
        }
        print("  ✓ north2 is the second hit")

        // Top-hit distance should be ~0.
        let topDist = rows.first?["distance"] as? Double ?? .nan
        guard topDist.isFinite, topDist < 0.001 else {
            throw SmokeError.distanceOutOfRange(topDist)
        }
        print("  ✓ top-hit distance is ~0 (\(topDist))")

        // 6. Coexistence check — GRDB (using Apple's system SQLite)
        //    and SQLiteVec (using its own bundled SQLite) must live in
        //    the same process without linker symbol collisions or
        //    state bleed-through. Prove it by opening a GRDB queue,
        //    doing a trivial write+read, and confirming both DBs are
        //    alive simultaneously.
        let grdbQueue = try DatabaseQueue()  // in-memory
        try await grdbQueue.write { db in
            try db.execute(sql: "CREATE TABLE notes (id INTEGER PRIMARY KEY, txt TEXT)")
            try db.execute(sql: "INSERT INTO notes (txt) VALUES (?)", arguments: ["hello"])
        }
        let count = try await grdbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? -1
        }
        guard count == 1 else {
            throw SmokeError.distanceOutOfRange(Double(count))
        }
        print("  ✓ GRDB + SQLiteVec coexist (GRDB count=\(count))")

        // Also verify the SQLiteVec db is still usable after the GRDB
        // round-trip — catches any global state that got clobbered.
        let recheck = try await db.query(
            "SELECT COUNT(*) as n FROM vec_items"
        )
        let vecCount = (recheck.first?["n"] as? Int)
            ?? Int(recheck.first?["n"] as? Int64 ?? -1)
        guard vecCount == samples.count else {
            throw SmokeError.distanceOutOfRange(Double(vecCount))
        }
        print("  ✓ SQLiteVec survives GRDB usage (vec count=\(vecCount))")
    }
}
