import XCTest
@testable import InferRAG

/// Stateful coverage for `VectorStore` — the actor that owns
/// `vectors.sqlite`. The pre-existing `InferRAGTests` cover only pure
/// functions (RRF fusion, FTS query construction); nothing exercised
/// insert / query / delete, workspace isolation, the manual cascade
/// into `vec_items`, or the `chunks` <-> `chunks_fts` trigger parity.
///
/// Every test runs against its own temp-file database rather than
/// `VectorStore.defaultURL()`, so the suite never touches the user's
/// real corpus and cases cannot leak into each other. These are
/// deliberately NOT `*ExternalTests`: SQLiteVec is statically linked,
/// so there is no external binary, network, or model file involved —
/// only the local filesystem, same as `WikiStoreTests`.
/// `RAG.initialize()` registers vec0 with SQLiteVec's bundled SQLite —
/// the app does this once at launch (`InferApp.swift:153`), and without
/// it every `CREATE VIRTUAL TABLE ... USING vec0` fails with "no such
/// module: vec0". It registers a process-wide auto-extension, so run it
/// exactly once for the whole bundle rather than per test; repeated
/// registration is not documented as safe at the C layer.
private let ragInitFailure: String? = {
    do {
        try RAG.initialize()
        return nil
    } catch {
        return String(describing: error)
    }
}()

private struct VectorStoreTestSetupError: Error, CustomStringConvertible {
    let description: String
}

final class VectorStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        if let ragInitFailure {
            throw VectorStoreTestSetupError(
                description: "RAG.initialize() failed, vec0 unavailable: \(ragInitFailure)"
            )
        }
        directory = FileManager.default.temporaryDirectory
            .appending(path: "VectorStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func makeStore(named name: String = "vectors.sqlite") -> VectorStore {
        VectorStore(url: directory.appending(path: name))
    }

    // MARK: - Fixtures

    private let model = "bge-small-en-v1.5"

    /// A unit vector with all its weight on `axis`. Two such vectors
    /// with different axes are orthogonal (cosine distance 1.0) and a
    /// vector matches itself exactly (distance 0.0), which makes
    /// nearest-neighbour ordering assertions exact rather than
    /// approximate.
    private func embedding(axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: VectorStore.dimension)
        v[axis % VectorStore.dimension] = 1
        return v
    }

    /// A vector leaning mostly on `axis` with a small component on
    /// `secondary`, for cases needing a near-but-not-exact match.
    private func embedding(axis: Int, tilt secondary: Int, by weight: Float = 0.25) -> [Float] {
        var v = embedding(axis: axis)
        v[secondary % VectorStore.dimension] = weight
        return v
    }

    private func chunk(_ content: String, axis: Int, ord: Int = 0) -> VectorChunk {
        VectorChunk(
            content: content,
            offsetStart: ord * 100,
            offsetEnd: ord * 100 + content.count,
            embedding: embedding(axis: axis)
        )
    }

    @discardableResult
    private func initialize(
        _ store: VectorStore,
        workspace: Int64,
        model overrideModel: String? = nil
    ) async throws -> VectorWorkspaceMeta {
        try await store.ensureInitialized(
            workspaceId: workspace,
            embeddingModel: overrideModel ?? model,
            dimension: VectorStore.dimension,
            chunkSize: 512,
            chunkOverlap: 64
        )
    }

    // MARK: - Initialization and metadata

    func testEnsureInitializedCreatesMetadataAndIsIdempotent() async throws {
        let store = makeStore()
        let first = try await initialize(store, workspace: 1)
        XCTAssertEqual(first.workspaceId, 1)
        XCTAssertEqual(first.dimension, VectorStore.dimension)
        XCTAssertEqual(first.metric, "cosine")

        let second = try await initialize(store, workspace: 1)
        XCTAssertEqual(second, first, "re-initializing must return the stored row, not a new one")

        let stored = try await store.workspaceMeta(workspaceId: 1)
        XCTAssertEqual(stored, first)
    }

    func testWorkspaceMetaIsNilBeforeInitialization() async throws {
        let store = makeStore()
        let meta = try await store.workspaceMeta(workspaceId: 99)
        XCTAssertNil(meta)
    }

    func testEnsureInitializedRejectsDimensionChange() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        do {
            _ = try await store.ensureInitialized(
                workspaceId: 1,
                embeddingModel: model,
                dimension: VectorStore.dimension + 1,
                chunkSize: 512,
                chunkOverlap: 64
            )
            XCTFail("expected metadataMismatch")
        } catch let error as VectorStoreError {
            guard case .metadataMismatch = error else {
                return XCTFail("wrong VectorStoreError: \(error)")
            }
        }
    }

    func testEnsureInitializedRejectsModelChange() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        do {
            try await initialize(store, workspace: 1, model: "some-other-model")
            XCTFail("expected metadataMismatch")
        } catch let error as VectorStoreError {
            guard case .metadataMismatch = error else {
                return XCTFail("wrong VectorStoreError: \(error)")
            }
        }
    }

    /// The compiled-in `vec_items` dimension is authoritative even for a
    /// workspace that has no metadata row yet — otherwise the row would
    /// be written and every later insert would fail against the virtual
    /// table.
    func testEnsureInitializedRejectsDimensionUnsupportedByVecItems() async throws {
        let store = makeStore()
        do {
            _ = try await store.ensureInitialized(
                workspaceId: 7,
                embeddingModel: model,
                dimension: VectorStore.dimension * 2,
                chunkSize: 512,
                chunkOverlap: 64
            )
            XCTFail("expected metadataMismatch")
        } catch let error as VectorStoreError {
            guard case .metadataMismatch = error else {
                return XCTFail("wrong VectorStoreError: \(error)")
            }
        }
        let meta = try await store.workspaceMeta(workspaceId: 7)
        XCTAssertNil(meta, "a rejected initialization must not leave a metadata row behind")
    }

    // MARK: - Ingest

    func testIngestStoresSourceAndChunks() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        let sourceId = try await store.ingest(
            workspaceId: 1,
            uri: "/notes/alpha.md",
            contentHash: "hash-alpha",
            kind: "markdown",
            chunks: [chunk("first chunk", axis: 0, ord: 0), chunk("second chunk", axis: 1, ord: 1)]
        )
        XCTAssertGreaterThan(sourceId, 0)

        let sources = try await store.listSources(workspaceId: 1)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.uri, "/notes/alpha.md")
        XCTAssertEqual(sources.first?.kind, "markdown")
        XCTAssertEqual(sources.first?.chunkCount, 2)

        let stats = try await store.sourceStatistics(workspaceId: 1)
        XCTAssertEqual(stats.sources, 1)
        XCTAssertEqual(stats.chunks, 2)
    }

    func testIngestRejectsWrongDimensionEmbedding() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        let bad = VectorChunk(content: "x", offsetStart: 0, offsetEnd: 1, embedding: [0.5, 0.5])
        do {
            _ = try await store.ingest(
                workspaceId: 1,
                uri: "/notes/bad.md",
                contentHash: "hash-bad",
                kind: "markdown",
                chunks: [bad]
            )
            XCTFail("expected metadataMismatch")
        } catch let error as VectorStoreError {
            guard case .metadataMismatch = error else {
                return XCTFail("wrong VectorStoreError: \(error)")
            }
        }
        let stats = try await store.sourceStatistics(workspaceId: 1)
        XCTAssertEqual(stats.sources, 0, "a rejected ingest must not write a partial source row")
    }

    /// Dedup is on `(workspace_id, content_hash)`. Re-ingesting an
    /// unchanged file must be a no-op returning the original id, or the
    /// wiki auto-ingest path would duplicate a page's chunks on every
    /// save.
    func testIngestDeduplicatesOnContentHash() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        let first = try await store.ingest(
            workspaceId: 1,
            uri: "/notes/alpha.md",
            contentHash: "same-hash",
            kind: "markdown",
            chunks: [chunk("only chunk", axis: 0)]
        )
        let second = try await store.ingest(
            workspaceId: 1,
            uri: "/notes/alpha-renamed.md",
            contentHash: "same-hash",
            kind: "markdown",
            chunks: [chunk("only chunk", axis: 0)]
        )
        XCTAssertEqual(second, first, "same hash must return the existing source id")

        let stats = try await store.sourceStatistics(workspaceId: 1)
        XCTAssertEqual(stats.sources, 1)
        XCTAssertEqual(stats.chunks, 1, "dedup must skip chunk writes, not just the source row")
    }

    /// The same content hash in a different workspace is a different
    /// source — dedup is scoped, not global.
    func testIngestDedupIsScopedToWorkspace() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        try await initialize(store, workspace: 2)
        let a = try await store.ingest(
            workspaceId: 1, uri: "/shared.md", contentHash: "h", kind: "markdown",
            chunks: [chunk("shared", axis: 0)]
        )
        let b = try await store.ingest(
            workspaceId: 2, uri: "/shared.md", contentHash: "h", kind: "markdown",
            chunks: [chunk("shared", axis: 0)]
        )
        XCTAssertNotEqual(a, b)
        let statsOne = try await store.sourceStatistics(workspaceId: 1)
        let statsTwo = try await store.sourceStatistics(workspaceId: 2)
        XCTAssertEqual(statsOne.sources, 1)
        XCTAssertEqual(statsTwo.sources, 1)
    }

    // MARK: - Search

    func testVectorSearchRanksExactMatchFirst() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        try await store.ingest(
            workspaceId: 1, uri: "/a.md", contentHash: "ha", kind: "markdown",
            chunks: [
                chunk("apples on axis zero", axis: 0, ord: 0),
                chunk("bananas on axis one", axis: 1, ord: 1),
                chunk("cherries on axis two", axis: 2, ord: 2),
            ]
        )
        let hits = try await store.search(workspaceId: 1, queryEmbedding: embedding(axis: 1), k: 3)
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hits.first?.content, "bananas on axis one")
        XCTAssertEqual(hits.first?.distance ?? 1, 0, accuracy: 1e-5, "self-match is cosine distance 0")
    }

    func testSearchRespectsK() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        let many = (0..<10).map { chunk("chunk number \($0)", axis: $0, ord: $0) }
        try await store.ingest(
            workspaceId: 1, uri: "/many.md", contentHash: "hm", kind: "markdown", chunks: many
        )
        let hits = try await store.search(workspaceId: 1, queryEmbedding: embedding(axis: 0), k: 4)
        XCTAssertEqual(hits.count, 4)
    }

    /// The single most important invariant in this file: one
    /// workspace's corpus must never appear in another's results.
    func testSearchIsIsolatedByWorkspace() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        try await initialize(store, workspace: 2)
        try await store.ingest(
            workspaceId: 1, uri: "/one.md", contentHash: "h1", kind: "markdown",
            chunks: [chunk("workspace one private text", axis: 5)]
        )
        try await store.ingest(
            workspaceId: 2, uri: "/two.md", contentHash: "h2", kind: "markdown",
            chunks: [chunk("workspace two private text", axis: 5)]
        )

        // Identical embeddings and near-identical text in both
        // workspaces: only the scoping predicate can separate them.
        let one = try await store.search(
            workspaceId: 1, queryEmbedding: embedding(axis: 5), queryText: "private text", k: 10
        )
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.first?.content, "workspace one private text")

        let two = try await store.search(
            workspaceId: 2, queryEmbedding: embedding(axis: 5), queryText: "private text", k: 10
        )
        XCTAssertEqual(two.count, 1)
        XCTAssertEqual(two.first?.content, "workspace two private text")

        let empty = try await store.search(workspaceId: 3, queryEmbedding: embedding(axis: 5), k: 10)
        XCTAssertTrue(empty.isEmpty, "an uninitialized workspace must return nothing, not everything")
    }

    func testSearchSourceFilterRestrictsResults() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        let keep = try await store.ingest(
            workspaceId: 1, uri: "/keep.md", contentHash: "hk", kind: "markdown",
            chunks: [chunk("keep this one", axis: 3)]
        )
        _ = try await store.ingest(
            workspaceId: 1, uri: "/drop.md", contentHash: "hd", kind: "markdown",
            chunks: [chunk("drop this one", axis: 3)]
        )
        let hits = try await store.search(
            workspaceId: 1, queryEmbedding: embedding(axis: 3), k: 10, sourceFilter: [keep]
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.sourceId, keep)
    }

    func testSearchRejectsWrongQueryDimension() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        do {
            _ = try await store.search(workspaceId: 1, queryEmbedding: [1, 0, 0], k: 3)
            XCTFail("expected metadataMismatch")
        } catch let error as VectorStoreError {
            guard case .metadataMismatch = error else {
                return XCTFail("wrong VectorStoreError: \(error)")
            }
        }
    }

    /// Hybrid retrieval's reason for existing: a rare proper noun that
    /// the query embedding does not point at should still be retrieved
    /// through the keyword lane.
    func testHybridSearchRetrievesKeywordOnlyMatch() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        try await store.ingest(
            workspaceId: 1, uri: "/mixed.md", contentHash: "hx", kind: "markdown",
            chunks: [
                // Far from the query vector, but an exact keyword hit.
                chunk("SQLiteVec powers the embedded index", axis: 200, ord: 0),
                chunk("unrelated filler text about weather", axis: 0, ord: 1),
            ]
        )
        let hits = try await store.search(
            workspaceId: 1,
            queryEmbedding: embedding(axis: 0),
            queryText: "SQLiteVec",
            k: 5
        )
        XCTAssertTrue(
            hits.contains { $0.content.contains("SQLiteVec") },
            "keyword lane must contribute a chunk the vector lane ranks last; got \(hits.map(\.content))"
        )
        let diagnostics = await store.lastSearchDiagnostics
        XCTAssertEqual(diagnostics?.usedFusion, true)
        XCTAssertGreaterThan(diagnostics?.ftsHits ?? 0, 0)
    }

    /// With no query text there is no keyword lane, and the store must
    /// report that it fell through to vector-only rather than claiming
    /// fusion.
    func testSearchWithoutTextReportsNoFusion() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        try await store.ingest(
            workspaceId: 1, uri: "/v.md", contentHash: "hv", kind: "markdown",
            chunks: [chunk("vector only path", axis: 4)]
        )
        _ = try await store.search(workspaceId: 1, queryEmbedding: embedding(axis: 4), k: 3)
        let diagnostics = await store.lastSearchDiagnostics
        XCTAssertEqual(diagnostics?.usedFusion, false)
        XCTAssertEqual(diagnostics?.ftsHits, 0)
        XCTAssertTrue(diagnostics?.ftsQuery.isEmpty ?? false)
    }

    // MARK: - Deletion and cascade

    /// `vec_items` is a virtual table outside SQLite's foreign-key
    /// machinery, so every delete path cascades by hand. A missed
    /// cascade is invisible until a stale vector is returned for a
    /// document the user deleted — assert the vector lane really is
    /// empty afterwards, not just that the row count dropped.
    func testDeleteSourceCascadesIntoVectorAndFTSTables() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        let doomed = try await store.ingest(
            workspaceId: 1, uri: "/doomed.md", contentHash: "hdoom", kind: "markdown",
            chunks: [chunk("doomed content here", axis: 6, ord: 0), chunk("more doomed", axis: 7, ord: 1)]
        )
        _ = try await store.ingest(
            workspaceId: 1, uri: "/survivor.md", contentHash: "hsurv", kind: "markdown",
            chunks: [chunk("surviving content", axis: 8)]
        )

        try await store.deleteSource(id: doomed)

        let stats = try await store.sourceStatistics(workspaceId: 1)
        XCTAssertEqual(stats.sources, 1)
        XCTAssertEqual(stats.chunks, 1)

        let hits = try await store.search(workspaceId: 1, queryEmbedding: embedding(axis: 6), k: 10)
        XCTAssertFalse(
            hits.contains { $0.sourceId == doomed },
            "deleted source still reachable through vec_items"
        )

        let counts = try await store.rowCounts()
        XCTAssertEqual(counts.chunks, counts.fts, "delete trigger must keep chunks_fts in step")
    }

    func testDeleteSourcesByURIRemovesEveryMatchAndReportsCount() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        try await store.ingest(
            workspaceId: 1, uri: "/page.md", contentHash: "h1", kind: "wiki",
            chunks: [chunk("first revision", axis: 10)]
        )
        // Same URI, different hash — the shape the wiki path produces
        // when a page is edited without the prior row being cleared.
        try await store.ingest(
            workspaceId: 1, uri: "/page.md", contentHash: "h2", kind: "wiki",
            chunks: [chunk("second revision", axis: 11)]
        )
        try await store.ingest(
            workspaceId: 1, uri: "/other.md", contentHash: "h3", kind: "wiki",
            chunks: [chunk("unrelated", axis: 12)]
        )

        let deleted = try await store.deleteSourcesByURI(workspaceId: 1, uri: "/page.md")
        XCTAssertEqual(deleted, 2)

        let remaining = try await store.listSources(workspaceId: 1)
        XCTAssertEqual(remaining.map(\.uri), ["/other.md"])

        let counts = try await store.rowCounts()
        XCTAssertEqual(counts.chunks, 1)
        XCTAssertEqual(counts.fts, 1)
    }

    func testDeleteSourcesByURIReturnsZeroWhenNothingMatches() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        let deleted = try await store.deleteSourcesByURI(workspaceId: 1, uri: "/absent.md")
        XCTAssertEqual(deleted, 0)
    }

    func testDeleteWorkspaceDataLeavesOtherWorkspacesIntact() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        try await initialize(store, workspace: 2)
        try await store.ingest(
            workspaceId: 1, uri: "/one.md", contentHash: "h1", kind: "markdown",
            chunks: [chunk("workspace one", axis: 20, ord: 0), chunk("more one", axis: 21, ord: 1)]
        )
        try await store.ingest(
            workspaceId: 2, uri: "/two.md", contentHash: "h2", kind: "markdown",
            chunks: [chunk("workspace two", axis: 22)]
        )

        try await store.deleteWorkspaceData(workspaceId: 1)

        let gone = try await store.sourceStatistics(workspaceId: 1)
        XCTAssertEqual(gone.sources, 0)
        XCTAssertEqual(gone.chunks, 0)
        let goneMeta = try await store.workspaceMeta(workspaceId: 1)
        XCTAssertNil(
            goneMeta,
            "deleting a workspace must drop its metadata row too, or re-init would see a stale model"
        )

        let kept = try await store.sourceStatistics(workspaceId: 2)
        XCTAssertEqual(kept.sources, 1)
        XCTAssertEqual(kept.chunks, 1)
        let keptMeta = try await store.workspaceMeta(workspaceId: 2)
        XCTAssertNotNil(keptMeta)

        let counts = try await store.rowCounts()
        XCTAssertEqual(counts.chunks, 1)
        XCTAssertEqual(counts.fts, 1)
    }

    // MARK: - Index parity

    /// `chunks_fts` is an external-content FTS5 table kept in step by
    /// triggers. If insert and delete ever fall out of sync the keyword
    /// lane silently rots — matching stale text or missing new text —
    /// with no error anywhere.
    func testFTSIndexStaysInStepAcrossInsertsAndDeletes() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)

        for i in 0..<5 {
            try await store.ingest(
                workspaceId: 1, uri: "/doc\(i).md", contentHash: "h\(i)", kind: "markdown",
                chunks: [chunk("document number \(i)", axis: i, ord: 0), chunk("tail \(i)", axis: i + 50, ord: 1)]
            )
        }
        var counts = try await store.rowCounts()
        XCTAssertEqual(counts.chunks, 10)
        XCTAssertEqual(counts.fts, 10)

        _ = try await store.deleteSourcesByURI(workspaceId: 1, uri: "/doc2.md")
        counts = try await store.rowCounts()
        XCTAssertEqual(counts.chunks, 8)
        XCTAssertEqual(counts.fts, 8, "chunks_fts drifted from chunks after a delete")

        try await store.deleteWorkspaceData(workspaceId: 1)
        counts = try await store.rowCounts()
        XCTAssertEqual(counts.chunks, 0)
        XCTAssertEqual(counts.fts, 0)
    }

    // MARK: - Persistence and lifecycle

    func testDataSurvivesShutdownAndReopen() async throws {
        let url = directory.appending(path: "persist.sqlite")
        let first = VectorStore(url: url)
        try await first.ensureInitialized(
            workspaceId: 1, embeddingModel: model, dimension: VectorStore.dimension,
            chunkSize: 512, chunkOverlap: 64
        )
        try await first.ingest(
            workspaceId: 1, uri: "/persist.md", contentHash: "hp", kind: "markdown",
            chunks: [chunk("persisted content", axis: 30)]
        )
        await first.shutdown()

        let second = VectorStore(url: url)
        let meta = try await second.workspaceMeta(workspaceId: 1)
        XCTAssertEqual(meta?.embeddingModel, model)
        let hits = try await second.search(workspaceId: 1, queryEmbedding: embedding(axis: 30), k: 5)
        XCTAssertEqual(hits.first?.content, "persisted content")
    }

    /// `shutdown` drops the cached handle; the next call must reopen
    /// rather than throw or hand back a closed database.
    func testStoreIsUsableAfterShutdown() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        await store.shutdown()
        try await store.ingest(
            workspaceId: 1, uri: "/after.md", contentHash: "ha", kind: "markdown",
            chunks: [chunk("after shutdown", axis: 31)]
        )
        let stats = try await store.sourceStatistics(workspaceId: 1)
        XCTAssertEqual(stats.sources, 1)
    }

    func testBootstrapCreatesParentDirectory() async throws {
        let nested = directory.appending(path: "a/b/c/vectors.sqlite")
        let store = VectorStore(url: nested)
        try await store.ensureInitialized(
            workspaceId: 1, embeddingModel: model, dimension: VectorStore.dimension,
            chunkSize: 512, chunkOverlap: 64
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    // MARK: - Concurrency

    /// Concurrent ingests into distinct workspaces. The actor plus
    /// SQLite's single connection should serialize these; the test
    /// fails if any transaction interleaves badly enough to lose rows
    /// or trip the dedup unique index.
    func testConcurrentIngestsAcrossWorkspacesAllLand() async throws {
        let store = makeStore()
        for workspace in Int64(1)...Int64(4) {
            try await initialize(store, workspace: workspace)
        }

        // Build every fixture up front: the task-group closures may
        // only capture Sendable values, and `self` (an XCTestCase) is
        // not Sendable under Swift 6.
        struct IngestJob: Sendable {
            let workspace: Int64
            let uri: String
            let hash: String
            let chunk: VectorChunk
        }
        let jobs: [IngestJob] = (Int64(1)...Int64(4)).flatMap { workspace in
            (0..<5).map { doc in
                IngestJob(
                    workspace: workspace,
                    uri: "/ws\(workspace)/doc\(doc).md",
                    hash: "ws\(workspace)-doc\(doc)",
                    chunk: chunk("workspace \(workspace) document \(doc)", axis: doc)
                )
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for job in jobs {
                group.addTask {
                    try await store.ingest(
                        workspaceId: job.workspace,
                        uri: job.uri,
                        contentHash: job.hash,
                        kind: "markdown",
                        chunks: [job.chunk]
                    )
                }
            }
            try await group.waitForAll()
        }

        for workspace in Int64(1)...Int64(4) {
            let stats = try await store.sourceStatistics(workspaceId: workspace)
            XCTAssertEqual(stats.sources, 5, "workspace \(workspace) lost sources under concurrency")
            XCTAssertEqual(stats.chunks, 5, "workspace \(workspace) lost chunks under concurrency")
        }
        let counts = try await store.rowCounts()
        XCTAssertEqual(counts.chunks, 20)
        XCTAssertEqual(counts.fts, 20, "FTS triggers must hold under concurrent writes too")
    }

    /// Readers running against the same store while writes are in
    /// flight. Assertion is deliberately weak on ordering — the point
    /// is that no read throws, returns a torn row, or deadlocks.
    func testConcurrentReadsDuringWritesDoNotFail() async throws {
        let store = makeStore()
        try await initialize(store, workspace: 1)
        try await store.ingest(
            workspaceId: 1, uri: "/seed.md", contentHash: "seed", kind: "markdown",
            chunks: [chunk("seed content", axis: 0)]
        )

        // Same constraint as above: hoist fixtures so the closures
        // capture only Sendable values.
        let writes = (0..<8).map { (index: $0, chunk: chunk("written \($0)", axis: $0 + 1)) }
        let queryVector = embedding(axis: 0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for write in writes {
                group.addTask {
                    try await store.ingest(
                        workspaceId: 1,
                        uri: "/w\(write.index).md",
                        contentHash: "w\(write.index)",
                        kind: "markdown",
                        chunks: [write.chunk]
                    )
                }
                group.addTask {
                    let hits = try await store.search(
                        workspaceId: 1, queryEmbedding: queryVector, queryText: "content", k: 5
                    )
                    // The seed is always present; concurrent writers may
                    // or may not have landed yet.
                    XCTAssertGreaterThanOrEqual(hits.count, 1)
                    _ = try await store.listSources(workspaceId: 1)
                    _ = try await store.rowCounts()
                }
            }
            try await group.waitForAll()
        }

        let stats = try await store.sourceStatistics(workspaceId: 1)
        XCTAssertEqual(stats.sources, 9)
    }
}
