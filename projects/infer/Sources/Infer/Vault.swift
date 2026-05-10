import Foundation
import GRDB

enum VaultError: Error, Equatable {
    /// Caller-provided input failed validation. Message is
    /// user-facing; use for things like empty workspace names or
    /// malformed paths.
    case invalidInput(String)
}

struct WorkspaceSummary: Identifiable, Sendable, Equatable {
    let id: Int64
    let name: String
    /// Absolute path to the folder whose files will be ingested into
    /// this workspace's RAG corpus. Nil means "no corpus yet."
    let dataFolder: String?
    let createdAt: Date
    let updatedAt: Date
    /// Number of conversations assigned to this workspace. Computed
    /// via subquery in `listWorkspaces` so the UI can show a count
    /// without a second round-trip.
    let conversationCount: Int
    // MARK: Per-workspace inference parameters (v5)
    //
    // Each is `nil` when the workspace inherits from the Default
    // workspace's row. The Default workspace's columns hold the
    // global floor (the v5 migration seeds them from the legacy
    // `UserDefaults` slots). See `docs/dev/per-workspace-params.md`
    // for the override semantics.
    let systemPrompt: String?
    let temperature: Double?
    let topP: Double?
    let maxTokens: Int?
    /// Per-workspace output directory for generated artifacts (Stable
    /// Diffusion images today; transcript exports later). `nil` = fall
    /// back to Default's row, then to the legacy hardcoded path
    /// (`Application Support/Infer/Generated Images/`). Phase 2 of the
    /// per-workspace-params feature; see
    /// `docs/dev/per-workspace-params.md`.
    let outputDirectory: String?
    /// Per-workspace active agent / persona id (raw `AgentID` value).
    /// `nil` = inherit from Default's row, then to the synthetic
    /// `DefaultAgent.id`. Phase 3 of per-workspace-params; see
    /// `docs/dev/per-workspace-params.md` §12.5 for the
    /// graceful-degradation flow on workspace switch.
    let activeAgentId: String?
    /// Per-workspace allow-list of agent ids visible to the user.
    /// `nil` = inherit from Default's column. `nil` on Default = the
    /// implicit "everything" — every agent in the global registry is
    /// available. An explicit `[]` is the user-silenced state — only
    /// `DefaultAgent.id` is available (the safety net is enforced at
    /// read time in `ChatViewModel.effectiveEnabledAgents`, not in
    /// the cascade resolver). An explicit `["coder", "researcher"]`
    /// is a curated subset; `DefaultAgent.id` is always added by the
    /// resolver so the user can never lock themselves out. Phase 4a
    /// of the per-workspace-params feature; see
    /// `docs/dev/per-workspace-params.md` §12.3.
    let enabledAgents: [String]?
    /// Per-workspace allow-list of tool names visible to the active
    /// agent. Same JSON-encoded `[String]?` shape as `enabledAgents`.
    /// `nil` = inherit from Default; `nil` on Default = all tools
    /// available; `[]` = no tools (workspace-silenced); `["a","b"]` =
    /// curated subset. Phase 4b of per-workspace-params; see
    /// `docs/dev/per-workspace-params.md` §12.3. **No safety net**
    /// (unlike `enabledAgents` which always allows `DefaultAgent`):
    /// an empty list really does mean "no tools," because there's no
    /// equivalent of "the user must always be able to escape" for
    /// tools — running zero tools is a legitimate workspace shape
    /// (e.g. a "private" workspace where you don't want web fetches
    /// happening).
    let enabledTools: [String]?
    /// Per-workspace allow-list of MCP server ids whose tools are
    /// exposed to the active agent. Same JSON-encoded `[String]?`
    /// shape. Distinct from `enabledTools` in scope (whole servers,
    /// not individual tools): when a server id is allow-listed out,
    /// every `mcp.<serverID>.*` tool the registry knows about is
    /// subtracted from the effective tool surface. Servers themselves
    /// run app-globally — this is a per-workspace VISIBILITY filter,
    /// not a subprocess gate. Phase 4c of per-workspace-params; see
    /// `docs/dev/per-workspace-params.md` §12.3.
    let enabledMCPServers: [String]?
}

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
        // v4: workspaces as an organizational container with an
        // optional data folder for RAG ingestion. Every existing
        // conversation is backfilled to a "Default" workspace so no
        // data is orphaned. Nullable FK on conversations — deletion
        // of a workspace sets its conversations' workspace_id to
        // NULL rather than cascading (conversations survive).
        m.registerMigration("v4_workspaces") { db in
            try db.execute(sql: """
                CREATE TABLE workspaces (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    data_folder TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
            """)
            try db.execute(sql: """
                ALTER TABLE conversations
                    ADD COLUMN workspace_id INTEGER
                        REFERENCES workspaces(id) ON DELETE SET NULL
            """)
            try db.execute(sql: """
                CREATE INDEX idx_conversations_workspace
                    ON conversations(workspace_id, updated_at DESC)
            """)
            // Backfill: create the Default workspace and assign every
            // existing conversation to it.
            let now = Int64(Date().timeIntervalSince1970)
            try db.execute(
                sql: """
                    INSERT INTO workspaces (name, data_folder, created_at, updated_at)
                        VALUES ('Default', NULL, ?, ?)
                """,
                arguments: [now, now]
            )
            let defaultId = db.lastInsertedRowID
            try db.execute(
                sql: "UPDATE conversations SET workspace_id = ? WHERE workspace_id IS NULL",
                arguments: [defaultId]
            )
        }
        // v5: per-workspace inference parameters. Four nullable columns
        // on `workspaces`. `NULL` means "inherit from the Default
        // workspace's row." Default's row carries the global floor —
        // populated from the legacy `UserDefaults` slots by a one-time
        // migration in `ChatViewModel` on first v5 launch (see
        // `docs/dev/per-workspace-params.md`). Migration is purely
        // additive so existing data round-trips unchanged.
        m.registerMigration("v5_workspace_params") { db in
            try db.execute(sql: "ALTER TABLE workspaces ADD COLUMN system_prompt TEXT")
            try db.execute(sql: "ALTER TABLE workspaces ADD COLUMN temperature REAL")
            try db.execute(sql: "ALTER TABLE workspaces ADD COLUMN top_p REAL")
            try db.execute(sql: "ALTER TABLE workspaces ADD COLUMN max_tokens INTEGER")
        }
        // v6: per-workspace output directory for generated artifacts
        // (Stable Diffusion images today; transcript exports later).
        // `NULL` = inherit from the Default workspace's row; if both
        // are `NULL`, the chat-VM substitutes the legacy hardcoded
        // path. Default's row is left `NULL` on first launch so
        // existing users see no change without a data write.
        m.registerMigration("v6_workspace_output_dir") { db in
            try db.execute(sql: "ALTER TABLE workspaces ADD COLUMN output_directory TEXT")
        }
        // v7: per-workspace active agent / persona id. `NULL` =
        // inherit from Default; if both are NULL the chat-VM falls
        // back to the synthetic `DefaultAgent.id`. Phase 3 of the
        // per-workspace-params feature. There is no legacy
        // `UserDefaults` source to seed Default with — `activeAgentId`
        // was never persisted before this migration; it defaulted to
        // `DefaultAgent.id` on every launch. So Default's column
        // stays NULL on first v7 launch and the existing default
        // behaviour is preserved without a data write.
        m.registerMigration("v7_workspace_active_agent") { db in
            try db.execute(sql: "ALTER TABLE workspaces ADD COLUMN active_agent_id TEXT")
        }
        // v8: per-workspace agent allow-list, JSON-encoded `[String]`.
        // `NULL` = inherit from Default; `NULL` on Default = "all
        // agents from the registry are available." Explicit `"[]"` =
        // workspace-silenced (`DefaultAgent` still allowed via the
        // chat-VM's safety net). Explicit `'["a","b"]'` = curated
        // subset. Phase 4a of per-workspace-params; the same JSON-
        // text-column pattern will be replicated in v9 / v10 for the
        // tools and MCP server allow-lists.
        m.registerMigration("v8_workspace_enabled_agents") { db in
            try db.execute(sql: "ALTER TABLE workspaces ADD COLUMN enabled_agents TEXT")
        }
        // v9: per-workspace tool allow-list. Same JSON-encoded
        // `[String]` pattern as `enabled_agents`. No safety net — an
        // empty list legitimately means "no tools available in this
        // workspace" (private / security-sensitive contexts).
        m.registerMigration("v9_workspace_enabled_tools") { db in
            try db.execute(sql: "ALTER TABLE workspaces ADD COLUMN enabled_tools TEXT")
        }
        // v10: per-workspace MCP server allow-list. Last set-axis in
        // Phase 4. The gate is a visibility filter, not a subprocess
        // gate — MCP servers run app-globally; this column controls
        // which of their tools surface to the active workspace's
        // agent.
        m.registerMigration("v10_workspace_enabled_mcp_servers") { db in
            try db.execute(sql: "ALTER TABLE workspaces ADD COLUMN enabled_mcp_servers TEXT")
        }
        return m
    }()

    // MARK: - Writes

    func startConversation(
        backend: String,
        modelId: String,
        systemPrompt: String,
        workspaceId: Int64? = nil
    ) async throws -> Int64 {
        let db = try pool()
        let now = Int64(Date().timeIntervalSince1970)
        return try await db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations
                        (created_at, updated_at, backend, model_id, system_prompt, title, workspace_id)
                        VALUES (?, ?, ?, ?, ?, NULL, ?)
                """,
                arguments: [now, now, backend, modelId, systemPrompt, workspaceId]
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

    // MARK: - Workspaces

    /// List all workspaces, with conversation counts. Sorted with the
    /// Default workspace pinned first (it's always present post-v4
    /// migration) and the rest alphabetically. Returns at least one
    /// row on a healthy vault.
    func listWorkspaces() async throws -> [WorkspaceSummary] {
        let db = try pool()
        return try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT w.id, w.name, w.data_folder, w.created_at, w.updated_at,
                       w.system_prompt, w.temperature, w.top_p, w.max_tokens,
                       w.output_directory, w.active_agent_id, w.enabled_agents,
                       w.enabled_tools, w.enabled_mcp_servers,
                       (SELECT COUNT(*) FROM conversations c WHERE c.workspace_id = w.id) AS cnt
                    FROM workspaces w
                    ORDER BY (w.name = 'Default') DESC,
                             LOWER(w.name) ASC
            """)
            return rows.map(Self.makeWorkspaceSummary)
        }
    }

    /// Create a new workspace. Names are free-form and do not need to
    /// be unique (the id is the stable handle). `dataFolder` is
    /// expected to be an absolute path if provided; validation lives
    /// at the UI layer.
    func createWorkspace(
        name: String,
        dataFolder: String? = nil
    ) async throws -> Int64 {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VaultError.invalidInput("workspace name cannot be empty")
        }
        let db = try pool()
        let now = Int64(Date().timeIntervalSince1970)
        return try await db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO workspaces (name, data_folder, created_at, updated_at)
                        VALUES (?, ?, ?, ?)
                """,
                arguments: [trimmed, dataFolder, now, now]
            )
            return db.lastInsertedRowID
        }
    }

    /// Rename a workspace in place. No-op if the name is unchanged.
    func renameWorkspace(id: Int64, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw VaultError.invalidInput("workspace name cannot be empty")
        }
        let db = try pool()
        let now = Int64(Date().timeIntervalSince1970)
        try await db.write { db in
            try db.execute(
                sql: "UPDATE workspaces SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [trimmed, now, id]
            )
        }
    }

    /// Update a workspace's data folder. Pass nil to clear. The RAG
    /// ingestion pipeline reads this path; validation is the caller's
    /// responsibility.
    func setWorkspaceDataFolder(id: Int64, dataFolder: String?) async throws {
        let db = try pool()
        let now = Int64(Date().timeIntervalSince1970)
        try await db.write { db in
            try db.execute(
                sql: "UPDATE workspaces SET data_folder = ?, updated_at = ? WHERE id = ?",
                arguments: [dataFolder, now, id]
            )
        }
    }

    /// Delete a workspace. Conversations assigned to it have their
    /// workspace_id set to NULL (they survive, orphaned, visible in the
    /// History tab regardless of workspace filter). The caller is
    /// responsible for warning the user — this is destructive.
    ///
    /// The RAG store for this workspace is *not* touched by this call;
    /// it's a separate DB (vectors.sqlite). The caller should invoke
    /// `VectorStore.deleteWorkspaceData(workspaceId:)` alongside.
    func deleteWorkspace(id: Int64) async throws {
        let db = try pool()
        try await db.write { db in
            try db.execute(
                sql: "DELETE FROM workspaces WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Assign or reassign a conversation to a workspace. Pass nil for
    /// `workspaceId` to orphan the conversation.
    func setConversationWorkspace(
        conversationId: Int64,
        workspaceId: Int64?
    ) async throws {
        let db = try pool()
        try await db.write { db in
            try db.execute(
                sql: "UPDATE conversations SET workspace_id = ? WHERE id = ?",
                arguments: [workspaceId, conversationId]
            )
        }
    }

    /// Look up a single workspace by id. Nil if not found.
    func workspace(id: Int64) async throws -> WorkspaceSummary? {
        let db = try pool()
        return try await db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT w.id, w.name, w.data_folder, w.created_at, w.updated_at,
                       w.system_prompt, w.temperature, w.top_p, w.max_tokens,
                       w.output_directory, w.active_agent_id, w.enabled_agents,
                       w.enabled_tools, w.enabled_mcp_servers,
                       (SELECT COUNT(*) FROM conversations c WHERE c.workspace_id = w.id) AS cnt
                    FROM workspaces w
                    WHERE w.id = ?
                    LIMIT 1
            """, arguments: [id])
            return rows.first.map(Self.makeWorkspaceSummary)
        }
    }

    /// Update one or more per-workspace inference-parameter columns
    /// (`system_prompt`, `temperature`, `top_p`, `max_tokens`). Pass
    /// `.unchanged` for fields the caller doesn't want to touch;
    /// `.value(nil)` clears (= falls back to Default's row);
    /// `.value(x)` sets the override. Three-state mapping is
    /// necessary because `nil` already has meaning here (it's the
    /// "use default" signal stored in the database), distinct from
    /// "the caller didn't pass this field." Updates `updated_at` if
    /// at least one field changes.
    func setWorkspaceParams(
        id: Int64,
        systemPrompt: ParamWrite<String?> = .unchanged,
        temperature: ParamWrite<Double?> = .unchanged,
        topP: ParamWrite<Double?> = .unchanged,
        maxTokens: ParamWrite<Int?> = .unchanged,
        outputDirectory: ParamWrite<String?> = .unchanged,
        activeAgentId: ParamWrite<String?> = .unchanged,
        enabledAgents: ParamWrite<[String]?> = .unchanged,
        enabledTools: ParamWrite<[String]?> = .unchanged,
        enabledMCPServers: ParamWrite<[String]?> = .unchanged
    ) async throws {
        var fragments: [String] = []
        var args: [DatabaseValueConvertible?] = []
        if case .value(let v) = systemPrompt {
            fragments.append("system_prompt = ?")
            args.append(v)
        }
        if case .value(let v) = temperature {
            fragments.append("temperature = ?")
            args.append(v)
        }
        if case .value(let v) = topP {
            fragments.append("top_p = ?")
            args.append(v)
        }
        if case .value(let v) = maxTokens {
            fragments.append("max_tokens = ?")
            args.append(v.map { Int64($0) })
        }
        if case .value(let v) = outputDirectory {
            fragments.append("output_directory = ?")
            args.append(v)
        }
        if case .value(let v) = activeAgentId {
            fragments.append("active_agent_id = ?")
            args.append(v)
        }
        if case .value(let v) = enabledAgents {
            fragments.append("enabled_agents = ?")
            // JSON-encode the array so the column stays human-
            // readable (sqlite browser, sql dumps). `nil` writes a
            // NULL; an empty array writes `"[]"`. Failure to encode
            // is impossible for `[String]` but the throwing call
            // shape forces the do/catch — we propagate the error so
            // the caller sees it instead of silently writing NULL.
            if let v {
                let data = try JSONEncoder().encode(v)
                args.append(String(data: data, encoding: .utf8) ?? "[]")
            } else {
                args.append(nil)
            }
        }
        if case .value(let v) = enabledTools {
            fragments.append("enabled_tools = ?")
            if let v {
                let data = try JSONEncoder().encode(v)
                args.append(String(data: data, encoding: .utf8) ?? "[]")
            } else {
                args.append(nil)
            }
        }
        if case .value(let v) = enabledMCPServers {
            fragments.append("enabled_mcp_servers = ?")
            if let v {
                let data = try JSONEncoder().encode(v)
                args.append(String(data: data, encoding: .utf8) ?? "[]")
            } else {
                args.append(nil)
            }
        }
        guard !fragments.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        fragments.append("updated_at = ?")
        args.append(now)
        args.append(id)
        let sql = "UPDATE workspaces SET \(fragments.joined(separator: ", ")) WHERE id = ?"
        let stmtArgs = StatementArguments(args)
        let db = try pool()
        try await db.write { db in
            try db.execute(sql: sql, arguments: stmtArgs)
        }
    }

    /// Three-state write: leave a column alone, or write a (possibly
    /// nil) value. Used by `setWorkspaceParams` so callers can update
    /// any subset of the four columns in a single query without
    /// confusing "skip this field" with "set this field to NULL."
    enum ParamWrite<T>: Sendable where T: Sendable {
        case unchanged
        case value(T)
    }

    private static func makeWorkspaceSummary(_ row: Row) -> WorkspaceSummary {
        WorkspaceSummary(
            id: row["id"],
            name: row["name"],
            dataFolder: row["data_folder"],
            createdAt: Date(timeIntervalSince1970: TimeInterval(row["created_at"] as Int64)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(row["updated_at"] as Int64)),
            conversationCount: row["cnt"],
            systemPrompt: row["system_prompt"],
            temperature: row["temperature"],
            topP: row["top_p"],
            maxTokens: (row["max_tokens"] as Int64?).map { Int($0) },
            outputDirectory: row["output_directory"],
            activeAgentId: row["active_agent_id"],
            enabledAgents: Self.decodeStringArray(row["enabled_agents"]),
            enabledTools: Self.decodeStringArray(row["enabled_tools"]),
            enabledMCPServers: Self.decodeStringArray(row["enabled_mcp_servers"])
        )
    }

    /// Decode a JSON-encoded `[String]` from a TEXT column into
    /// `[String]?`. Returns `nil` for NULL columns, `[]` for the
    /// literal `"[]"`. Malformed JSON returns `nil` rather than
    /// throwing — the column is user-data-shaped (could be
    /// hand-edited via a sqlite browser), and crashing the whole
    /// row read on a parse failure would block startup. The chat-VM
    /// surfaces this as "no allow-list" which is the safe direction
    /// (every agent visible).
    private static func decodeStringArray(_ raw: String?) -> [String]? {
        guard let raw else { return nil }
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
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
