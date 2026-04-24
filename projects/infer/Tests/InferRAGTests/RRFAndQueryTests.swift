import XCTest
@testable import InferRAG

final class RRFTests: XCTestCase {
    private func hit(_ id: Int64, distance: Double = 1.0) -> VectorSearchHit {
        VectorSearchHit(
            chunkId: id,
            sourceId: 1,
            sourceURI: "/tmp/x.md",
            ord: 0,
            content: "content \(id)",
            distance: distance
        )
    }

    // MARK: - Basic fusion

    func testSinglyRankedChunkKeepsItsRank() {
        // Vector alone returns [A, B, C]; FTS empty. Output == vector.
        let v = [hit(1), hit(2), hit(3)]
        let fused = VectorStore.rrfFuse(vectorHits: v, ftsHits: [], k: 3)
        XCTAssertEqual(fused.map(\.chunkId), [1, 2, 3])
    }

    func testFTSOnlyKeepsRank() {
        let f = [hit(1), hit(2), hit(3)]
        let fused = VectorStore.rrfFuse(vectorHits: [], ftsHits: f, k: 3)
        XCTAssertEqual(fused.map(\.chunkId), [1, 2, 3])
    }

    func testAgreementRaisesConsensusChunks() {
        // Chunk 99 is rank 3 in one list and rank 3 in the other.
        // Chunk 1 is rank 1 in vector but absent from FTS.
        // Under RRF with k=60: 99 scores 2/(60+3) ≈ 0.0317; 1 scores
        // 1/61 ≈ 0.0164. 99 wins even though both lists had 1 higher.
        let v = [hit(1), hit(2), hit(99)]
        let f = [hit(7), hit(8), hit(99)]
        let fused = VectorStore.rrfFuse(vectorHits: v, ftsHits: f, k: 3)
        XCTAssertEqual(fused.first?.chunkId, 99)
    }

    func testDedupByChunkId() {
        // Chunk 5 appears in both; output contains it once.
        let v = [hit(5, distance: 0.2), hit(10)]
        let f = [hit(5, distance: 0.8), hit(11)]
        let fused = VectorStore.rrfFuse(vectorHits: v, ftsHits: f, k: 10)
        let ids = fused.map(\.chunkId)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicates in fused output")
        XCTAssertTrue(ids.contains(5))
    }

    func testPrefersVectorPathDistanceWhenBothPresent() {
        // For a chunk in both lists, the surviving hit should carry
        // the vector-path distance (direct, not subquery-computed).
        let v = [hit(5, distance: 0.2)]
        let f = [hit(5, distance: 0.8)]
        let fused = VectorStore.rrfFuse(vectorHits: v, ftsHits: f, k: 1)
        XCTAssertEqual(fused.first?.distance, 0.2)
    }

    func testKCapLimitsResults() {
        let v = (1...10).map { hit(Int64($0)) }
        let f = (20...29).map { hit(Int64($0)) }
        let fused = VectorStore.rrfFuse(vectorHits: v, ftsHits: f, k: 5)
        XCTAssertEqual(fused.count, 5)
    }

    func testTieBreakByDistance() {
        // Two chunks each rank-1 in their own list (same RRF score).
        // Tiebreaker goes to the smaller distance.
        let v = [hit(1, distance: 0.9)]
        let f = [hit(2, distance: 0.1)]
        let fused = VectorStore.rrfFuse(vectorHits: v, ftsHits: f, k: 2)
        XCTAssertEqual(fused.map(\.chunkId), [2, 1])
    }

    // MARK: - FTS query sanitizer
    //
    // Sanitizer OR-joins tokens for RAG (see docstring on
    // `buildFTSQuery`). Tokenization mirrors unicode61: split on
    // anything non-alphanumeric, drop single-char tokens.

    func testFTSQueryOrJoinsQuotedTokens() {
        let q = VectorStore.buildFTSQuery("vector database choice")
        XCTAssertEqual(q, "\"vector\" OR \"database\" OR \"choice\"")
    }

    func testFTSQuerySplitsOnPunctuationLikeUnicode61() {
        // Apostrophe, question mark, colon all become token
        // boundaries — matches what the stored text gets tokenized
        // to, so "pawnbroker's" in the query produces the same
        // tokens as the stored "pawnbroker's".
        let q = VectorStore.buildFTSQuery("Raskolnikov hide pawnbroker's money?")
        XCTAssertEqual(
            q,
            "\"Raskolnikov\" OR \"hide\" OR \"pawnbroker\" OR \"money\""
        )
    }

    func testFTSQueryDropsSingleCharacterTokens() {
        // "s" (from "pawnbroker's") and "a" and "I" are single-char
        // noise — dropped to keep the query focused on content words.
        let q = VectorStore.buildFTSQuery("a cat I saw")
        XCTAssertEqual(q, "\"cat\" OR \"saw\"")
    }

    func testFTSQueryEmptyWhenNoUsableTokens() {
        XCTAssertEqual(VectorStore.buildFTSQuery(""), "")
        XCTAssertEqual(VectorStore.buildFTSQuery("   \n   "), "")
        // Pure punctuation collapses to empty.
        XCTAssertEqual(VectorStore.buildFTSQuery("*()\"^-?!"), "")
        // All single-char tokens also collapse to empty.
        XCTAssertEqual(VectorStore.buildFTSQuery("a b c d"), "")
    }

    func testFTSQueryCollapsesWhitespaceRuns() {
        let q = VectorStore.buildFTSQuery("   many    spaces    between words   ")
        XCTAssertEqual(
            q,
            "\"many\" OR \"spaces\" OR \"between\" OR \"words\""
        )
    }

    func testFTSQueryHandlesReservedWordsViaQuoting() {
        // "AND", "OR", "NOT", "NEAR" are FTS5 reserved words; phrase-
        // quoting is what protects us from them turning into
        // operators in the emitted query.
        let q = VectorStore.buildFTSQuery("SQLiteVec OR GRDB AND NEAR")
        XCTAssertEqual(
            q,
            "\"SQLiteVec\" OR \"OR\" OR \"GRDB\" OR \"AND\" OR \"NEAR\""
        )
    }
}
