import Foundation
import GRDB

struct VaultConversationSummary: Identifiable, Sendable, Equatable {
    let id: Int64
    let title: String
    let backend: String
    let modelId: String
    let createdAt: Date
    let updatedAt: Date
    let messageCount: Int
    /// Tags attached to this conversation, sorted alphabetically. Empty
    /// when the conversation has no tags. Fetched via a subquery in
    /// `recentConversations` so history rows can render chips without a
    /// second round-trip.
    let tags: [String]
}

struct VaultModelEntry: Sendable, Equatable, Hashable {
    let backend: String
    let modelId: String
    let sourceURL: String?
    let lastUsedAt: Date
}

struct VaultSearchHit: Identifiable, Sendable, Equatable {
    let id: Int64              // messages.id
    let conversationId: Int64
    let conversationTitle: String
    let role: String
    let snippet: String        // contains <mark>...</mark> runs
    let modelId: String
    let backend: String
    let createdAt: Date
}

/// SQLite-backed vault of all conversations. One file at
/// ~/Library/Application Support/Infer/vault.sqlite (WAL mode). Search uses
/// FTS5 over message content. Vault errors never block generation: callers
/// should treat writes as best-effort.
actor VaultStore {
    static let shared = VaultStore()

    private var cachedPool: DatabasePool?

    private func pool() throws -> DatabasePool {
        if let p = cachedPool { return p }
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("Infer", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir.appendingPathComponent("vault.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        let p = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(p)
        cachedPool = p
        return p
    }

    private static let migrator: DatabaseMigrator = {
        var m = DatabaseMigrator()
        m.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE conversations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    backend TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    system_prompt TEXT NOT NULL DEFAULT '',
                    title TEXT
                )
            """)
            try db.execute(sql: """
                CREATE TABLE messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id INTEGER NOT NULL
                        REFERENCES conversations(id) ON DELETE CASCADE,
                    turn_idx INTEGER NOT NULL,
                    role TEXT NOT NULL,
                    content TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    tokens INTEGER,
                    tok_per_sec REAL
                )
            """)
            try db.execute(sql: """
                CREATE INDEX idx_messages_conv
                    ON messages(conversation_id, turn_idx)
            """)
            try db.execute(sql: """
                CREATE INDEX idx_conversations_updated
                    ON conversations(updated_at DESC)
            """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE messages_fts USING fts5(
                    content,
                    content='messages',
                    content_rowid='id',
                    tokenize='unicode61 remove_diacritics 2'
                )
            """)
            try db.execute(sql: """
                CREATE TRIGGER messages_ai AFTER INSERT ON messages BEGIN
                    INSERT INTO messages_fts(rowid, content)
                        VALUES (new.id, new.content);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER messages_ad AFTER DELETE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, content)
                        VALUES ('delete', old.id, old.content);
                END
            """)
            try db.execute(sql: """
                CREATE TRIGGER messages_au AFTER UPDATE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, content)
                        VALUES ('delete', old.id, old.content);
                    INSERT INTO messages_fts(rowid, content)
                        VALUES (new.id, new.content);
                END
            """)
        }
        m.registerMigration("v2_models") { db in
            try db.execute(sql: """
                CREATE TABLE models (
                    backend TEXT NOT NULL,
                    model_id TEXT NOT NULL,
                    source_url TEXT,
                    last_used_at INTEGER NOT NULL,
                    PRIMARY KEY (backend, model_id)
                )
            """)
            try db.execute(sql: """
                CREATE INDEX idx_models_last_used
                    ON models(last_used_at DESC)
            """)
        }
        // v3: free-form tags on conversations. `tags` is a normalized
        // dimension (so renames are a single row update) joined via
        // `conversation_tags`. Both halves are created together so the
        // migration is atomic from the caller's perspective.
        m.registerMigration("v3_tags") { db in
            try db.execute(sql: """
                CREATE TABLE tags (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL UNIQUE COLLATE NOCASE
                )
            """)
            try db.execute(sql: """
                CREATE TABLE conversation_tags (
                    conversation_id INTEGER NOT NULL
                        REFERENCES conversations(id) ON DELETE CASCADE,
                    tag_id INTEGER NOT NULL
                        REFERENCES tags(id) ON DELETE CASCADE,
                    PRIMARY KEY (conversation_id, tag_id)
                )
            """)
            try db.execute(sql: """
                CREATE INDEX idx_conversation_tags_tag
                    ON conversation_tags(tag_id, conversation_id)
            """)
        }
        return m
    }()

    // MARK: - Writes

    func startConversation(
        backend: String,
        modelId: String,
        systemPrompt: String
    ) async throws -> Int64 {
        let db = try pool()
        let now = Int64(Date().timeIntervalSince1970)
        return try await db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations
                        (created_at, updated_at, backend, model_id, system_prompt, title)
                        VALUES (?, ?, ?, ?, ?, NULL)
                """,
                arguments: [now, now, backend, modelId, systemPrompt]
            )
            return db.lastInsertedRowID
        }
    }

    func appendMessage(
        conversationId: Int64,
        role: String,
        content: String,
        tokens: Int? = nil,
        tokPerSec: Double? = nil
    ) async throws {
        let db = try pool()
        let now = Int64(Date().timeIntervalSince1970)
        try await db.write { db in
            let nextIdx = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(turn_idx), -1) + 1 FROM messages WHERE conversation_id = ?",
                arguments: [conversationId]
            ) ?? 0
            try db.execute(
                sql: """
                    INSERT INTO messages
                        (conversation_id, turn_idx, role, content, created_at, tokens, tok_per_sec)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [conversationId, nextIdx, role, content, now, tokens, tokPerSec]
            )
            try db.execute(
                sql: "UPDATE conversations SET updated_at = ? WHERE id = ?",
                arguments: [now, conversationId]
            )
            // Auto-title from the first user message if still null.
            if role == "user" {
                try db.execute(
                    sql: """
                        UPDATE conversations
                            SET title = ?
                            WHERE id = ? AND title IS NULL
                    """,
                    arguments: [Self.truncateTitle(content), conversationId]
                )
            }
        }
    }

    func deleteConversation(id: Int64) async throws {
        let db = try pool()
        try await db.write { db in
            try db.execute(
                sql: "DELETE FROM conversations WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func clearAll() async throws {
        let db = try pool()
        // Cascade handles messages; messages_fts triggers fire on delete.
        try await db.write { db in
            try db.execute(sql: "DELETE FROM conversations")
        }
        // VACUUM cannot run inside a transaction. GRDB's `writeWithoutTransaction`
        // issues the statement at the connection level.
        try await db.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    // MARK: - Models

    func recordModel(backend: String, modelId: String, sourceURL: String? = nil) async throws {
        let db = try pool()
        let now = Int64(Date().timeIntervalSince1970)
        try await db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO models (backend, model_id, source_url, last_used_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(backend, model_id) DO UPDATE SET
                            last_used_at = excluded.last_used_at,
                            source_url = COALESCE(excluded.source_url, models.source_url)
                """,
                arguments: [backend, modelId, sourceURL, now]
            )
        }
    }

    func listModels() async throws -> [VaultModelEntry] {
        let db = try pool()
        return try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT backend, model_id, source_url, last_used_at
                    FROM models
                    ORDER BY last_used_at DESC
            """)
            return rows.map { row in
                VaultModelEntry(
                    backend: row["backend"],
                    modelId: row["model_id"],
                    sourceURL: row["source_url"],
                    lastUsedAt: Date(timeIntervalSince1970: TimeInterval(row["last_used_at"] as Int64))
                )
            }
        }
    }

    // MARK: - Reads

    /// List recent conversations, optionally filtered by an AND-set of
    /// tag names (case-insensitive, normalized to lowercase). Empty
    /// `tags` returns unfiltered. Each row carries its current tag set
    /// so the UI can render chips in one round-trip.
    func recentConversations(
        limit: Int = 50,
        tags: [String] = []
    ) async throws -> [VaultConversationSummary] {
        let db = try pool()
        let normalized = tags.map(Self.normalizeTag).filter { !$0.isEmpty }
        return try await db.read { db in
            let rows: [Row]
            if normalized.isEmpty {
                rows = try Row.fetchAll(db, sql: """
                    SELECT c.id, c.title, c.backend, c.model_id, c.created_at, c.updated_at,
                           (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id) AS cnt
                        FROM conversations c
                        ORDER BY c.updated_at DESC
                        LIMIT ?
                """, arguments: [limit])
            } else {
                // AND-match: conversation must carry every requested tag.
                // Use HAVING COUNT(DISTINCT t.id) = ? after joining.
                let placeholders = normalized.map { _ in "?" }.joined(separator: ",")
                let sql = """
                    SELECT c.id, c.title, c.backend, c.model_id, c.created_at, c.updated_at,
                           (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id) AS cnt
                        FROM conversations c
                        JOIN conversation_tags ct ON ct.conversation_id = c.id
                        JOIN tags t ON t.id = ct.tag_id
                        WHERE LOWER(t.name) IN (\(placeholders))
                        GROUP BY c.id
                        HAVING COUNT(DISTINCT t.id) = ?
                        ORDER BY c.updated_at DESC
                        LIMIT ?
                """
                var args: [DatabaseValueConvertible] = normalized
                args.append(normalized.count)
                args.append(limit)
                rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }

            // Batch-fetch tags for all returned conversation ids.
            let ids = rows.map { $0["id"] as Int64 }
            let tagMap = try Self.tagsByConversation(db: db, conversationIds: ids)

            return rows.map { row in
                let cid = row["id"] as Int64
                return VaultConversationSummary(
                    id: cid,
                    title: row["title"] ?? "(untitled)",
                    backend: row["backend"],
                    modelId: row["model_id"],
                    createdAt: Date(timeIntervalSince1970: TimeInterval(row["created_at"] as Int64)),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(row["updated_at"] as Int64)),
                    messageCount: row["cnt"],
                    tags: tagMap[cid] ?? []
                )
            }
        }
    }

    // MARK: - Tags

    /// Attach `tag` to `conversationId`. Tag is created on demand (via
    /// an upsert on the `tags` table); existing link is a no-op because
    /// of the composite primary key + `INSERT OR IGNORE`.
    func addTag(_ tag: String, to conversationId: Int64) async throws {
        let normalized = Self.normalizeTag(tag)
        guard !normalized.isEmpty else { return }
        let db = try pool()
        try await db.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO tags (name) VALUES (?)",
                arguments: [normalized]
            )
            let tagId = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM tags WHERE LOWER(name) = ?",
                arguments: [normalized]
            )
            guard let tid = tagId else { return }
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO conversation_tags (conversation_id, tag_id)
                        VALUES (?, ?)
                """,
                arguments: [conversationId, tid]
            )
        }
    }

    /// Remove `tag` from `conversationId`. Leaves the tag definition in
    /// place (so the user can re-tag without re-typing). Orphan tags
    /// are acceptable — they cost a row and make re-use free.
    func removeTag(_ tag: String, from conversationId: Int64) async throws {
        let normalized = Self.normalizeTag(tag)
        guard !normalized.isEmpty else { return }
        let db = try pool()
        try await db.write { db in
            try db.execute(sql: """
                DELETE FROM conversation_tags
                    WHERE conversation_id = ?
                        AND tag_id IN (SELECT id FROM tags WHERE LOWER(name) = ?)
            """, arguments: [conversationId, normalized])
        }
    }

    /// All distinct tag names currently attached to at least one
    /// conversation. Used to populate the tag facet filter.
    func allTags() async throws -> [String] {
        let db = try pool()
        return try await db.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT t.name
                    FROM tags t
                    JOIN conversation_tags ct ON ct.tag_id = t.id
                    ORDER BY LOWER(t.name) ASC
            """)
        }
    }

    /// Tags attached to a single conversation. Helper for views that
    /// already have a `conversationId` but not a full summary.
    func tagsForConversation(id: Int64) async throws -> [String] {
        let db = try pool()
        return try await db.read { db in
            let map = try Self.tagsByConversation(db: db, conversationIds: [id])
            return map[id] ?? []
        }
    }

    /// Internal helper: batch-fetch tags for many conversations in one
    /// round-trip. Returns a map keyed by conversation id.
    private static func tagsByConversation(
        db: Database,
        conversationIds: [Int64]
    ) throws -> [Int64: [String]] {
        guard !conversationIds.isEmpty else { return [:] }
        let placeholders = conversationIds.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT ct.conversation_id AS cid, t.name AS name
                FROM conversation_tags ct
                JOIN tags t ON t.id = ct.tag_id
                WHERE ct.conversation_id IN (\(placeholders))
                ORDER BY LOWER(t.name) ASC
        """, arguments: StatementArguments(conversationIds))
        var out: [Int64: [String]] = [:]
        for row in rows {
            let cid = row["cid"] as Int64
            let name: String = row["name"]
            out[cid, default: []].append(name)
        }
        return out
    }

    /// Normalize tag input: trim, collapse internal whitespace, lowercase.
    /// Returns empty for invalid input (pure whitespace).
    static func normalizeTag(_ raw: String) -> String {
        let parts = raw.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    func search(query: String, limit: Int = 50) async throws -> [VaultSearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let ftsQuery = Self.buildFTSQuery(trimmed)
        let db = try pool()
        return try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.id AS mid,
                       m.conversation_id AS cid,
                       m.role AS role,
                       m.created_at AS created_at,
                       c.title AS title,
                       c.backend AS backend,
                       c.model_id AS model_id,
                       snippet(messages_fts, 0, '<mark>', '</mark>', '…', 12) AS snip
                    FROM messages_fts
                    JOIN messages m ON m.id = messages_fts.rowid
                    JOIN conversations c ON c.id = m.conversation_id
                    WHERE messages_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
            """, arguments: [ftsQuery, limit])
            return rows.map { row in
                VaultSearchHit(
                    id: row["mid"],
                    conversationId: row["cid"],
                    conversationTitle: row["title"] ?? "(untitled)",
                    role: row["role"],
                    snippet: row["snip"] ?? "",
                    modelId: row["model_id"],
                    backend: row["backend"],
                    createdAt: Date(timeIntervalSince1970: TimeInterval(row["created_at"] as Int64))
                )
            }
        }
    }

    /// Returns ordered (role, content) pairs for a conversation.
    func loadConversation(id: Int64) async throws -> [(role: String, content: String)] {
        let db = try pool()
        return try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT role, content FROM messages
                    WHERE conversation_id = ?
                    ORDER BY turn_idx ASC
            """, arguments: [id])
            return rows.map { (role: $0["role"], content: $0["content"]) }
        }
    }

    /// Explicit teardown. Call from `AppDelegate.applicationWillTerminate`
    /// so WAL checkpointing runs before the process exits, matching the
    /// llama / MLX cleanup pattern. Idempotent.
    func shutdown() {
        cachedPool = nil
    }

    // MARK: - Helpers

    private static func truncateTitle(_ s: String) -> String {
        let collapsed = s
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 80 { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: 80)
        return String(collapsed[..<idx]) + "…"
    }

    /// Sanitize user input for FTS5 MATCH: split on whitespace, drop FTS
    /// metacharacters, wrap each term in quotes, and append * for prefix
    /// matching on the final term. Empty terms are skipped. This trades
    /// advanced FTS syntax (NEAR, OR, column filters) for input that never
    /// throws on raw typing.
    static func buildFTSQuery(_ raw: String) -> String {
        let banned = CharacterSet(charactersIn: "\"*:()^-")
        let parts = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.unicodeScalars.filter { !banned.contains($0) }.map(String.init).joined() }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "\"\"" }
        var quoted = parts.map { "\"\($0)\"" }
        quoted[quoted.count - 1] += "*"
        return quoted.joined(separator: " ")
    }
}
