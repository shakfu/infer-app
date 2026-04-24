import Foundation
import SQLiteVec

/// Errors raised by `VectorStore`. User-facing — surfaced through
/// `LogCenter` and sometimes through `errorMessage` on the VM.
public enum VectorStoreError: Error, CustomStringConvertible {
    case notInitializedForWorkspace(Int64)
    case metadataMismatch(String)
    case bootstrapFailed(String)

    public var description: String {
        switch self {
        case .notInitializedForWorkspace(let wid):
            return "vector store not initialized for workspace \(wid)"
        case .metadataMismatch(let msg):
            return "vector store metadata mismatch: \(msg)"
        case .bootstrapFailed(let msg):
            return "vector store bootstrap failed: \(msg)"
        }
    }
}

/// One row returned from a RAG search.
public struct VectorSearchHit: Sendable, Equatable {
    public let chunkId: Int64
    public let sourceId: Int64
    public let sourceURI: String
    public let ord: Int
    public let content: String
    /// Raw distance from sqlite-vec (smaller = closer). Under cosine
    /// distance this is in `[0, 2]`. The caller is responsible for
    /// converting to similarity if needed (`1 - distance / 2` under
    /// cosine, roughly).
    public let distance: Double

    public init(
        chunkId: Int64,
        sourceId: Int64,
        sourceURI: String,
        ord: Int,
        content: String,
        distance: Double
    ) {
        self.chunkId = chunkId
        self.sourceId = sourceId
        self.sourceURI = sourceURI
        self.ord = ord
        self.content = content
        self.distance = distance
    }
}

/// Summary of one ingested file, used by the sources panel.
public struct VectorSourceSummary: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let workspaceId: Int64
    public let uri: String
    public let kind: String
    public let ingestedAt: Date
    public let chunkCount: Int

    public init(
        id: Int64,
        workspaceId: Int64,
        uri: String,
        kind: String,
        ingestedAt: Date,
        chunkCount: Int
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.uri = uri
        self.kind = kind
        self.ingestedAt = ingestedAt
        self.chunkCount = chunkCount
    }
}

/// Bundle passed to `VectorStore.ingest`, one per chunk produced by
/// the splitter. `embedding` must match the workspace's declared
/// dimension (enforced in `ingest`).
public struct VectorChunk: Sendable {
    public let content: String
    public let offsetStart: Int
    public let offsetEnd: Int
    public let embedding: [Float]

    public init(content: String, offsetStart: Int, offsetEnd: Int, embedding: [Float]) {
        self.content = content
        self.offsetStart = offsetStart
        self.offsetEnd = offsetEnd
        self.embedding = embedding
    }
}

/// Metadata recorded on first ingest for a workspace. Used to hard-
/// fail subsequent ingests if the app's active embedding model has
/// changed (which would produce incompatible vectors) — rather than
/// silently corrupting the index.
public struct VectorWorkspaceMeta: Sendable, Equatable {
    public let workspaceId: Int64
    public let embeddingModel: String
    public let dimension: Int
    public let metric: String  // "cosine" in MVP
    public let chunkSize: Int
    public let chunkOverlap: Int
    public let createdAt: Date

    public init(
        workspaceId: Int64,
        embeddingModel: String,
        dimension: Int,
        metric: String,
        chunkSize: Int,
        chunkOverlap: Int,
        createdAt: Date
    ) {
        self.workspaceId = workspaceId
        self.embeddingModel = embeddingModel
        self.dimension = dimension
        self.metric = metric
        self.chunkSize = chunkSize
        self.chunkOverlap = chunkOverlap
        self.createdAt = createdAt
    }
}

/// Actor wrapping a single SQLiteVec `Database` for the whole app.
/// One shared file at `~/Library/Application Support/Infer/vectors.sqlite`
/// holds every workspace's RAG corpus, scoped via `sources.workspace_id`.
///
/// Why a single file and not per-workspace files:
/// - sqlite-vec's `vec0` virtual table is per-database; a per-workspace
///   file would mean one `vec0` per file and no cross-workspace queries
///   (we explicitly don't want those, but one file is simpler).
/// - Database handle lifecycle is easier with one actor.
/// - The whole vector DB is derived data — if it gets corrupted, we
///   can delete and re-ingest from workspace folders.
///
/// Schema is bootstrapped at first open rather than migrated because
/// there's no user content here that isn't recoverable by re-ingest.
/// Dimension is baked into the `vec_items` declaration (384 matches
/// bge-small); changing models breaks the index and forces a rebuild,
/// enforced via `workspace_meta` mismatch detection.
public actor VectorStore {
    /// Absolute on-disk path to the vector database file. Separate
    /// from the main vault (`vault.sqlite`) since they use different
    /// SQLite builds — SQLiteVec bundles its own (with sqlite-vec
    /// statically linked), while the vault uses Apple's system SQLite
    /// via GRDB.
    nonisolated public static func defaultURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Infer", isDirectory: true)
            .appendingPathComponent("vectors.sqlite")
    }

    private let databaseURL: URL
    private var database: Database?
    /// Dimension the `vec_items` virtual table is configured for.
    /// Must match the active embedding model at runtime — verified in
    /// `ensureInitialized`. Hard-coded to bge-small's 384 for MVP.
    public static let dimension: Int = 384

    public init(url: URL = VectorStore.defaultURL()) {
        self.databaseURL = url
    }

    /// Idempotent open-or-create. The first call creates the parent
    /// directory, opens the DB, and bootstraps the schema. Subsequent
    /// calls reuse the cached handle. Safe to call many times.
    @discardableResult
    private func db() async throws -> Database {
        if let database { return database }
        let fm = FileManager.default
        let dir = databaseURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let created: Database
        do {
            created = try Database(.uri(databaseURL.path))
        } catch {
            throw VectorStoreError.bootstrapFailed("open failed: \(error)")
        }
        try await Self.bootstrapSchema(created)
        self.database = created
        return created
    }

    /// Create the tables + virtual table if missing. Intentionally a
    /// static method on `Database` rather than on the actor — the
    /// Database actor-isolates its own methods, so we just send it a
    /// sequence of `execute` calls.
    private static func bootstrapSchema(_ db: Database) async throws {
        // Regular tables — plain SQL, nothing sqlite-vec-specific.
        try await db.execute("""
            CREATE TABLE IF NOT EXISTS workspace_meta (
                workspace_id INTEGER PRIMARY KEY,
                embedding_model TEXT NOT NULL,
                dimension INTEGER NOT NULL,
                metric TEXT NOT NULL DEFAULT 'cosine',
                chunk_size INTEGER NOT NULL,
                chunk_overlap INTEGER NOT NULL,
                created_at INTEGER NOT NULL
            )
        """)
        try await db.execute("""
            CREATE TABLE IF NOT EXISTS sources (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                workspace_id INTEGER NOT NULL,
                uri TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                kind TEXT NOT NULL,
                ingested_at INTEGER NOT NULL,
                meta TEXT
            )
        """)
        try await db.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_sources_dedup
                ON sources(workspace_id, content_hash)
        """)
        try await db.execute("""
            CREATE INDEX IF NOT EXISTS idx_sources_workspace
                ON sources(workspace_id)
        """)
        try await db.execute("""
            CREATE TABLE IF NOT EXISTS chunks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_id INTEGER NOT NULL,
                ord INTEGER NOT NULL,
                content TEXT NOT NULL,
                offset_start INTEGER NOT NULL,
                offset_end INTEGER NOT NULL
            )
        """)
        try await db.execute("""
            CREATE INDEX IF NOT EXISTS idx_chunks_source
                ON chunks(source_id, ord)
        """)
        // vec0 virtual table — the dimension is baked in at create
        // time; changing it requires dropping and rebuilding the
        // table. We catch that in `ensureInitialized` via the
        // workspace_meta check.
        //
        // `distance_metric=cosine` is the correct vec0 DDL clause
        // (not `distance=`); we caught a bug here in early testing
        // when the table creation silently failed with a CONSTRAINT
        // error, leaving the DB half-bootstrapped.
        try await db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS vec_items USING vec0(
                embedding float[\(VectorStore.dimension)] distance_metric=cosine
            )
        """)

        // FTS5 over chunks for hybrid retrieval. Uses the same
        // external-content pattern as the vault's `messages_fts`:
        // content lives in `chunks.content`, fts index is kept in
        // sync by triggers below. `unicode61 remove_diacritics 2`
        // matches the vault's tokenizer choice for consistency.
        try await db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
                content,
                content='chunks',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            )
        """)
        try await db.execute("""
            CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
                INSERT INTO chunks_fts(rowid, content)
                    VALUES (new.id, new.content);
            END
        """)
        try await db.execute("""
            CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, content)
                    VALUES ('delete', old.id, old.content);
            END
        """)
        try await db.execute("""
            CREATE TRIGGER IF NOT EXISTS chunks_au AFTER UPDATE ON chunks BEGIN
                INSERT INTO chunks_fts(chunks_fts, rowid, content)
                    VALUES ('delete', old.id, old.content);
                INSERT INTO chunks_fts(rowid, content)
                    VALUES (new.id, new.content);
            END
        """)
        // One-shot backfill for corpora that were ingested before the
        // FTS table existed. The WHERE clause makes this a no-op on
        // subsequent launches. Cheap enough to run unconditionally at
        // bootstrap; doesn't require a schema migration.
        try await db.execute("""
            INSERT INTO chunks_fts(rowid, content)
                SELECT id, content FROM chunks
                    WHERE id NOT IN (SELECT rowid FROM chunks_fts)
        """)
    }

    /// Diagnostic helper: returns (chunks, chunks_fts) row counts for
    /// the whole DB. Called from the app's bootstrap path to log the
    /// FTS index state — a mismatch would indicate the backfill
    /// didn't cover existing chunks (e.g., schema drift, user
    /// migrated from a pre-hybrid build).
    public func rowCounts() async throws -> (chunks: Int, fts: Int) {
        let db = try await db()
        let chunkRows = try await db.query("SELECT COUNT(*) AS n FROM chunks")
        let ftsRows = try await db.query("SELECT COUNT(*) AS n FROM chunks_fts")
        let c = (chunkRows.first?["n"] as? Int)
            ?? Int(chunkRows.first?["n"] as? Int64 ?? 0)
        let f = (ftsRows.first?["n"] as? Int)
            ?? Int(ftsRows.first?["n"] as? Int64 ?? 0)
        return (c, f)
    }

    /// Close the underlying Database and release its handle. Called
    /// from `AppDelegate.applicationWillTerminate` so the SQLite WAL
    /// checkpoints cleanly before exit.
    public func shutdown() async {
        self.database = nil  // actor-held; SQLiteVec's finalizer closes the handle
    }

    /// Upsert the metadata row for a workspace on first ingest, or
    /// verify compatibility on subsequent ingests. If the existing
    /// row's dimension/model/metric don't match, throws
    /// `.metadataMismatch` — the caller should surface a "re-ingest
    /// required" error rather than producing silently broken vectors.
    ///
    /// Chunk size and overlap are stored for audit but not enforced
    /// on mismatch — changing them between ingests is harmless (the
    /// vectors just come from differently-shaped chunks).
    @discardableResult
    public func ensureInitialized(
        workspaceId: Int64,
        embeddingModel: String,
        dimension: Int,
        metric: String = "cosine",
        chunkSize: Int,
        chunkOverlap: Int
    ) async throws -> VectorWorkspaceMeta {
        let db = try await db()
        if let existing = try await workspaceMeta(workspaceId: workspaceId) {
            if existing.dimension != dimension {
                throw VectorStoreError.metadataMismatch(
                    "existing dim=\(existing.dimension), requested dim=\(dimension) (workspace \(workspaceId))"
                )
            }
            if existing.embeddingModel != embeddingModel {
                throw VectorStoreError.metadataMismatch(
                    "existing model=\(existing.embeddingModel), requested=\(embeddingModel) (workspace \(workspaceId))"
                )
            }
            if existing.metric != metric {
                throw VectorStoreError.metadataMismatch(
                    "existing metric=\(existing.metric), requested=\(metric) (workspace \(workspaceId))"
                )
            }
            return existing
        }
        // Also hard-fail if the requested dimension doesn't match the
        // compiled-in `vec_items` dimension — the virtual table can't
        // store the inserted vectors otherwise.
        if dimension != VectorStore.dimension {
            throw VectorStoreError.metadataMismatch(
                "vec_items is compiled for dim=\(VectorStore.dimension), caller requested dim=\(dimension)"
            )
        }
        let now = Int64(Date().timeIntervalSince1970)
        try await db.execute(
            """
                INSERT INTO workspace_meta
                    (workspace_id, embedding_model, dimension, metric, chunk_size, chunk_overlap, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            params: [workspaceId, embeddingModel, dimension, metric, chunkSize, chunkOverlap, now]
        )
        return VectorWorkspaceMeta(
            workspaceId: workspaceId,
            embeddingModel: embeddingModel,
            dimension: dimension,
            metric: metric,
            chunkSize: chunkSize,
            chunkOverlap: chunkOverlap,
            createdAt: Date(timeIntervalSince1970: TimeInterval(now))
        )
    }

    /// Insert a new source with its chunks + embeddings in one
    /// transaction. Idempotent on `(workspace_id, content_hash)` — a
    /// re-ingest of the same file returns the existing source id and
    /// skips chunk/embedding writes. Embeddings must be length
    /// `VectorStore.dimension`; shorter or longer throws
    /// `.metadataMismatch`.
    @discardableResult
    public func ingest(
        workspaceId: Int64,
        uri: String,
        contentHash: String,
        kind: String,
        meta: String? = nil,
        chunks: [VectorChunk]
    ) async throws -> Int64 {
        for c in chunks {
            if c.embedding.count != VectorStore.dimension {
                throw VectorStoreError.metadataMismatch(
                    "chunk embedding has \(c.embedding.count) dims, expected \(VectorStore.dimension)"
                )
            }
        }
        let db = try await db()

        // Dedup: return existing id if this file is already ingested.
        let existing = try await db.query(
            "SELECT id FROM sources WHERE workspace_id = ? AND content_hash = ? LIMIT 1",
            params: [workspaceId, contentHash]
        )
        if let row = existing.first,
           let existingId = (row["id"] as? Int64) ?? (row["id"] as? Int).map(Int64.init) {
            return existingId
        }

        var sourceId: Int64 = 0
        try await db.transaction {
            let now = Int64(Date().timeIntervalSince1970)
            try await db.execute(
                """
                    INSERT INTO sources
                        (workspace_id, uri, content_hash, kind, ingested_at, meta)
                        VALUES (?, ?, ?, ?, ?, ?)
                """,
                params: [
                    workspaceId,
                    uri,
                    contentHash,
                    kind,
                    now,
                    // SQLiteVec's params array is [any Sendable]; use
                    // NSNull() when the user hasn't supplied metadata.
                    (meta as (any Sendable)?) ?? (NSNull() as any Sendable),
                ]
            )
            sourceId = Int64(await db.lastInsertRowId)

            for (ord, chunk) in chunks.enumerated() {
                try await db.execute(
                    """
                        INSERT INTO chunks
                            (source_id, ord, content, offset_start, offset_end)
                            VALUES (?, ?, ?, ?, ?)
                    """,
                    params: [sourceId, ord, chunk.content, chunk.offsetStart, chunk.offsetEnd]
                )
                let chunkId = await db.lastInsertRowId
                // vec_items.rowid mirrors chunks.id so the JOIN in
                // search() is a simple rowid lookup.
                try await db.execute(
                    "INSERT INTO vec_items(rowid, embedding) VALUES (?, ?)",
                    params: [chunkId, chunk.embedding]
                )
            }
        }
        return sourceId
    }

    /// Delete a source and all its chunks + vec_items. Manual cascade
    /// since sqlite-vec virtual tables don't participate in FK chains.
    public func deleteSource(id sourceId: Int64) async throws {
        let db = try await db()
        try await db.transaction {
            // Gather chunk ids so we can delete the corresponding
            // vec_items rows in one statement.
            let chunkRows = try await db.query(
                "SELECT id FROM chunks WHERE source_id = ?",
                params: [sourceId]
            )
            for row in chunkRows {
                guard let cid = (row["id"] as? Int64) ?? (row["id"] as? Int).map(Int64.init)
                else { continue }
                try await db.execute(
                    "DELETE FROM vec_items WHERE rowid = ?",
                    params: [cid]
                )
            }
            try await db.execute(
                "DELETE FROM chunks WHERE source_id = ?",
                params: [sourceId]
            )
            try await db.execute(
                "DELETE FROM sources WHERE id = ?",
                params: [sourceId]
            )
        }
    }

    /// Delete all data for a workspace — sources, chunks, vec_items,
    /// and the workspace_meta row. Called when a workspace is being
    /// deleted so its RAG corpus doesn't linger in `vectors.sqlite`.
    public func deleteWorkspaceData(workspaceId: Int64) async throws {
        let db = try await db()
        try await db.transaction {
            // Find all chunk ids belonging to this workspace.
            let chunkRows = try await db.query(
                """
                    SELECT chunks.id AS id
                        FROM chunks
                        JOIN sources ON sources.id = chunks.source_id
                        WHERE sources.workspace_id = ?
                """,
                params: [workspaceId]
            )
            for row in chunkRows {
                guard let cid = (row["id"] as? Int64) ?? (row["id"] as? Int).map(Int64.init)
                else { continue }
                try await db.execute(
                    "DELETE FROM vec_items WHERE rowid = ?",
                    params: [cid]
                )
            }
            try await db.execute(
                """
                    DELETE FROM chunks
                        WHERE source_id IN (SELECT id FROM sources WHERE workspace_id = ?)
                """,
                params: [workspaceId]
            )
            try await db.execute(
                "DELETE FROM sources WHERE workspace_id = ?",
                params: [workspaceId]
            )
            try await db.execute(
                "DELETE FROM workspace_meta WHERE workspace_id = ?",
                params: [workspaceId]
            )
        }
    }

    /// Hybrid search scoped to a workspace. Combines dense vector
    /// retrieval over `vec_items` with keyword retrieval over
    /// `chunks_fts`, fused via Reciprocal Rank Fusion. Pure vector
    /// search misses chunks that use proper nouns or rare terms
    /// absent from the query ("SQLiteVec" when the query says
    /// "vector database"); pure keyword search misses paraphrased
    /// chunks. Their union covers both.
    ///
    /// Returns up to `k` hits ordered by fused rank (best first).
    /// Each hit carries a real cosine distance — for FTS-only hits
    /// we compute `vec_distance_cosine` against the stored embedding
    /// via a subquery so the UI's similarity display stays
    /// meaningful.
    ///
    /// Pass `queryText: nil` or an empty string to run vector-only
    /// (useful if the caller doesn't have the text, e.g. semantic-
    /// similarity against a pre-computed embedding).
    public func search(
        workspaceId: Int64,
        queryEmbedding: [Float],
        queryText: String? = nil,
        k: Int = 5,
        sourceFilter: [Int64]? = nil
    ) async throws -> [VectorSearchHit] {
        guard queryEmbedding.count == VectorStore.dimension else {
            throw VectorStoreError.metadataMismatch(
                "query embedding has \(queryEmbedding.count) dims, expected \(VectorStore.dimension)"
            )
        }
        let db = try await db()

        // Over-fetch from each retriever so the fused ranking has
        // room to reorder. RRF with k=60 rewards agreement across
        // retrievers; a chunk in both lists' top-30 ranks higher
        // than a chunk at rank 3 of either alone.
        let fetchLimit = max(k * 6, 30)

        // Both paths run against the same SQLiteVec `Database` actor,
        // so `async let` wouldn't buy real parallelism — SQLite
        // queries serialize through one connection anyway. Run
        // sequentially; keeps the code straightforward.
        let vec = try await searchVector(
            db: db,
            workspaceId: workspaceId,
            queryEmbedding: queryEmbedding,
            sourceFilter: sourceFilter,
            limit: fetchLimit
        )

        // Keyword path: skip cleanly when we don't have text or when
        // the text sanitizes to nothing usable (pure punctuation /
        // stopwords). FTS errors are captured and attached to the
        // last-search diagnostics so the caller can log them; we
        // fall back to vector-only in that case rather than throwing.
        let ftsQuery = Self.buildFTSQuery(queryText ?? "")
        var fts: [VectorSearchHit] = []
        var ftsError: Error? = nil
        if !ftsQuery.isEmpty {
            do {
                fts = try await searchFTS(
                    db: db,
                    workspaceId: workspaceId,
                    queryEmbedding: queryEmbedding,
                    ftsQuery: ftsQuery,
                    sourceFilter: sourceFilter,
                    limit: fetchLimit
                )
            } catch {
                ftsError = error
            }
        }
        self.lastSearchDiagnostics = SearchDiagnostics(
            vectorHits: vec.count,
            ftsHits: fts.count,
            ftsQuery: ftsQuery,
            ftsError: ftsError.map { String(describing: $0) },
            usedFusion: !fts.isEmpty
        )

        // If FTS produced nothing (no text, no keyword matches, or
        // the query errored), fall through to vector-only.
        if fts.isEmpty {
            return Array(vec.prefix(k))
        }

        return Self.rrfFuse(vectorHits: vec, ftsHits: fts, k: k)
    }

    /// Post-query diagnostics capture. Read by the RAG pipeline and
    /// logged to the Console so the user can tell whether hybrid
    /// actually contributed on a given turn — or whether FTS errored
    /// / returned empty and we fell through to vector-only. Reset on
    /// each `search` call; captures only the most recent search's
    /// state.
    public struct SearchDiagnostics: Sendable, Equatable {
        public let vectorHits: Int
        public let ftsHits: Int
        public let ftsQuery: String
        public let ftsError: String?
        public let usedFusion: Bool

        public init(
            vectorHits: Int,
            ftsHits: Int,
            ftsQuery: String,
            ftsError: String?,
            usedFusion: Bool
        ) {
            self.vectorHits = vectorHits
            self.ftsHits = ftsHits
            self.ftsQuery = ftsQuery
            self.ftsError = ftsError
            self.usedFusion = usedFusion
        }
    }

    public private(set) var lastSearchDiagnostics: SearchDiagnostics? = nil

    /// Dense-only search. Was the whole implementation of `search`
    /// before hybrid; factored out so the hybrid path can invoke it
    /// as one of two retrievers without duplicating SQL.
    private func searchVector(
        db: Database,
        workspaceId: Int64,
        queryEmbedding: [Float],
        sourceFilter: [Int64]?,
        limit: Int
    ) async throws -> [VectorSearchHit] {
        let sourceFilterClause: String
        let params: [any Sendable]
        if let sourceFilter, !sourceFilter.isEmpty {
            let placeholders = sourceFilter.map { _ in "?" }.joined(separator: ",")
            sourceFilterClause = " AND sources.id IN (\(placeholders))"
            params = [queryEmbedding, limit, workspaceId]
                + sourceFilter.map { $0 as any Sendable }
                + [limit]
        } else {
            sourceFilterClause = ""
            params = [queryEmbedding, limit, workspaceId, limit]
        }
        let sql = """
            SELECT chunks.id AS chunk_id,
                   chunks.source_id AS source_id,
                   chunks.ord AS ord,
                   chunks.content AS content,
                   sources.uri AS uri,
                   v.distance AS distance
                FROM vec_items v
                JOIN chunks ON chunks.id = v.rowid
                JOIN sources ON sources.id = chunks.source_id
                WHERE v.embedding MATCH ?
                  AND k = ?
                  AND sources.workspace_id = ?\(sourceFilterClause)
                ORDER BY v.distance
                LIMIT ?
        """
        let rows = try await db.query(sql, params: params)
        return rows.compactMap(Self.decodeHit)
    }

    /// FTS5-only search. Every chunk returned gets a real cosine
    /// distance via `vec_distance_cosine` against its stored
    /// embedding, so the fused result set uses one consistent
    /// distance metric regardless of which retriever surfaced a
    /// given chunk.
    private func searchFTS(
        db: Database,
        workspaceId: Int64,
        queryEmbedding: [Float],
        ftsQuery: String,
        sourceFilter: [Int64]?,
        limit: Int
    ) async throws -> [VectorSearchHit] {
        let sourceFilterClause: String
        let params: [any Sendable]
        if let sourceFilter, !sourceFilter.isEmpty {
            let placeholders = sourceFilter.map { _ in "?" }.joined(separator: ",")
            sourceFilterClause = " AND sources.id IN (\(placeholders))"
            params = [queryEmbedding, ftsQuery, workspaceId]
                + sourceFilter.map { $0 as any Sendable }
                + [limit]
        } else {
            sourceFilterClause = ""
            params = [queryEmbedding, ftsQuery, workspaceId, limit]
        }
        let sql = """
            SELECT chunks.id AS chunk_id,
                   chunks.source_id AS source_id,
                   chunks.ord AS ord,
                   chunks.content AS content,
                   sources.uri AS uri,
                   vec_distance_cosine(
                       (SELECT embedding FROM vec_items WHERE rowid = chunks.id),
                       ?
                   ) AS distance
                FROM chunks_fts f
                JOIN chunks ON chunks.id = f.rowid
                JOIN sources ON sources.id = chunks.source_id
                WHERE chunks_fts MATCH ?
                  AND sources.workspace_id = ?\(sourceFilterClause)
                ORDER BY rank
                LIMIT ?
        """
        let rows = try await db.query(sql, params: params)
        return rows.compactMap(Self.decodeHit)
    }

    /// Row → `VectorSearchHit` with the same double-typed-fallback
    /// dance as elsewhere in this file (SQLiteVec returns INTEGER
    /// columns as `Int`, but some paths surface them as `Int64`).
    private static func decodeHit(_ row: [String: any Sendable]) -> VectorSearchHit? {
        guard
            let chunkId = (row["chunk_id"] as? Int64) ?? (row["chunk_id"] as? Int).map(Int64.init),
            let sourceId = (row["source_id"] as? Int64) ?? (row["source_id"] as? Int).map(Int64.init),
            let ord = (row["ord"] as? Int) ?? (row["ord"] as? Int64).map(Int.init),
            let content = row["content"] as? String,
            let uri = row["uri"] as? String,
            let distance = row["distance"] as? Double
        else { return nil }
        return VectorSearchHit(
            chunkId: chunkId,
            sourceId: sourceId,
            sourceURI: uri,
            ord: ord,
            content: content,
            distance: distance
        )
    }

    /// Reciprocal Rank Fusion with k=60 (Cormack et al., 2009 — the
    /// standard default). Each retriever contributes `1 / (60 +
    /// rank)` to every chunk it returns; we sum contributions across
    /// retrievers and sort descending. Chunks appearing in both
    /// retrievers' top lists rise above chunks appearing in only one,
    /// even if their individual ranks were modest. Simple, parameter-
    /// light, and robust across mismatched score scales (dense
    /// distance vs. BM25).
    ///
    /// Ties are broken by vector distance ascending (so on a pure
    /// tie the stricter retriever wins).
    static func rrfFuse(
        vectorHits: [VectorSearchHit],
        ftsHits: [VectorSearchHit],
        k: Int,
        rrfK: Double = 60
    ) -> [VectorSearchHit] {
        var scores: [Int64: Double] = [:]
        var hitByChunk: [Int64: VectorSearchHit] = [:]

        for (idx, hit) in vectorHits.enumerated() {
            let rank = Double(idx + 1)
            scores[hit.chunkId, default: 0] += 1.0 / (rrfK + rank)
            hitByChunk[hit.chunkId] = hit
        }
        for (idx, hit) in ftsHits.enumerated() {
            let rank = Double(idx + 1)
            scores[hit.chunkId, default: 0] += 1.0 / (rrfK + rank)
            // Prefer the vector-path hit's distance (it's the direct
            // search distance, not one computed via subquery) if we
            // already have one; otherwise take the FTS hit.
            if hitByChunk[hit.chunkId] == nil {
                hitByChunk[hit.chunkId] = hit
            }
        }

        let ranked = scores.keys.sorted { a, b in
            let sa = scores[a] ?? 0
            let sb = scores[b] ?? 0
            if sa != sb { return sa > sb }
            // Tiebreaker: whichever hit has a smaller distance.
            let da = hitByChunk[a]?.distance ?? .infinity
            let db = hitByChunk[b]?.distance ?? .infinity
            return da < db
        }
        return ranked.prefix(k).compactMap { hitByChunk[$0] }
    }

    /// Sanitize user input for FTS5 MATCH in a RAG-retrieval context.
    ///
    /// Key difference from a keyword-search sanitizer (what the vault
    /// uses for message search): we OR-join tokens instead of AND-
    /// joining. RAG retrieval wants chunks that contain *some* of the
    /// user's terms ranked by BM25, not chunks that contain *all* of
    /// them. A 512-char chunk rarely contains every word of a natural-
    /// language question; AND matching would return zero hits (which
    /// is exactly the failure mode the earlier version produced).
    ///
    /// Tokenization mirrors what sqlite's `unicode61` tokenizer does
    /// to the stored content — split on anything that isn't a letter
    /// or digit. That way "pawnbroker's" in the query produces the
    /// same `pawnbroker` and `s` tokens the stored text produced;
    /// earlier, stripping the apostrophe produced `pawnbrokers`,
    /// which never matched anything.
    ///
    /// Each token is phrase-quoted so FTS reserved words (`AND`,
    /// `OR`, `NOT`, `NEAR`) in user input don't hijack the query.
    /// Tokens of 1 character are dropped — they're high-frequency
    /// noise that inflates FTS scans without contributing ranking
    /// signal.
    ///
    /// Returns empty string for input that tokenizes to nothing —
    /// caller treats that as "skip FTS".
    static func buildFTSQuery(_ raw: String) -> String {
        let tokens = raw.unicodeScalars
            .split { !CharacterSet.alphanumerics.contains($0) }
            .map { String(String.UnicodeScalarView($0)) }
            .filter { $0.count > 1 }
        guard !tokens.isEmpty else { return "" }
        return tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    /// Summary rows for the sources panel in the workspace sheet.
    /// Ordered by ingest time (newest first).
    public func listSources(workspaceId: Int64) async throws -> [VectorSourceSummary] {
        let db = try await db()
        let rows = try await db.query(
            """
                SELECT s.id AS id, s.uri AS uri, s.kind AS kind,
                       s.ingested_at AS ingested_at,
                       (SELECT COUNT(*) FROM chunks c WHERE c.source_id = s.id) AS n_chunks
                    FROM sources s
                    WHERE s.workspace_id = ?
                    ORDER BY s.ingested_at DESC
            """,
            params: [workspaceId]
        )
        return rows.compactMap { row in
            guard
                let id = (row["id"] as? Int64) ?? (row["id"] as? Int).map(Int64.init),
                let uri = row["uri"] as? String,
                let kind = row["kind"] as? String,
                let ingestedAt = (row["ingested_at"] as? Int64) ?? (row["ingested_at"] as? Int).map(Int64.init),
                let n = (row["n_chunks"] as? Int) ?? (row["n_chunks"] as? Int64).map(Int.init)
            else { return nil }
            return VectorSourceSummary(
                id: id,
                workspaceId: workspaceId,
                uri: uri,
                kind: kind,
                ingestedAt: Date(timeIntervalSince1970: TimeInterval(ingestedAt)),
                chunkCount: n
            )
        }
    }

    /// Aggregate stats for the workspace sheet's "corpus" badge.
    /// Returns (source count, total chunk count).
    public func sourceStatistics(workspaceId: Int64) async throws -> (sources: Int, chunks: Int) {
        let db = try await db()
        let rows = try await db.query(
            """
                SELECT (SELECT COUNT(*) FROM sources WHERE workspace_id = ?) AS nsources,
                       (SELECT COUNT(*) FROM chunks c
                           JOIN sources s ON s.id = c.source_id
                           WHERE s.workspace_id = ?) AS nchunks
            """,
            params: [workspaceId, workspaceId]
        )
        guard let row = rows.first else { return (0, 0) }
        let s = (row["nsources"] as? Int) ?? (row["nsources"] as? Int64).map(Int.init) ?? 0
        let c = (row["nchunks"] as? Int) ?? (row["nchunks"] as? Int64).map(Int.init) ?? 0
        return (s, c)
    }

    /// Return the stored metadata row for a workspace, or nil if the
    /// workspace hasn't been initialized yet (first ingest creates it).
    public func workspaceMeta(workspaceId: Int64) async throws -> VectorWorkspaceMeta? {
        let db = try await db()
        let rows = try await db.query(
            """
                SELECT embedding_model, dimension, metric, chunk_size, chunk_overlap, created_at
                    FROM workspace_meta
                    WHERE workspace_id = ?
                    LIMIT 1
            """,
            params: [workspaceId]
        )
        guard let row = rows.first else { return nil }
        guard let model = row["embedding_model"] as? String,
              let dim = (row["dimension"] as? Int) ?? (row["dimension"] as? Int64).map(Int.init),
              let metric = row["metric"] as? String,
              let chunkSize = (row["chunk_size"] as? Int) ?? (row["chunk_size"] as? Int64).map(Int.init),
              let chunkOverlap = (row["chunk_overlap"] as? Int) ?? (row["chunk_overlap"] as? Int64).map(Int.init),
              let createdAtRaw = (row["created_at"] as? Int64) ?? (row["created_at"] as? Int).map(Int64.init)
        else { return nil }
        return VectorWorkspaceMeta(
            workspaceId: workspaceId,
            embeddingModel: model,
            dimension: dim,
            metric: metric,
            chunkSize: chunkSize,
            chunkOverlap: chunkOverlap,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtRaw))
        )
    }
}
