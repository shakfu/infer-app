import XCTest
@testable import Infer

/// Coverage for `VaultStore` — the GRDB-backed store holding every
/// conversation, message, tag, and the FTS5 index over message content.
///
/// Until now its only coverage was `VaultTagNormalizeTests`, seven pure
/// string assertions against `normalizeTag`. The store itself — schema
/// migrations, turn ordering, auto-titling, cascade deletes, tag
/// AND-filtering, full-text search — had none, because `VaultStore`
/// hardcoded its path to Application Support and a test could only have
/// run against the user's real history.
///
/// Each test gets its own temp-file database via `VaultStore(url:)`.
final class VaultStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "VaultStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    private func makeStore(named name: String = "vault.sqlite") -> VaultStore {
        VaultStore(url: directory.appending(path: name))
    }

    @discardableResult
    private func seedConversation(
        _ store: VaultStore,
        backend: String = "llama",
        model: String = "test-model",
        prompt: String = "you are a test"
    ) async throws -> Int64 {
        try await store.startConversation(backend: backend, modelId: model, systemPrompt: prompt)
    }

    // MARK: - Schema and lifecycle

    func testMigrationsRunOnFirstUseAndCreateTheFile() async throws {
        let url = directory.appending(path: "fresh.sqlite")
        let store = VaultStore(url: url)
        _ = try await store.recentConversations()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "first read must bootstrap the database rather than fail"
        )
    }

    func testBootstrapCreatesMissingParentDirectory() async throws {
        let nested = directory.appending(path: "a/b/c/vault.sqlite")
        let store = VaultStore(url: nested)
        _ = try await store.recentConversations()
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }

    func testDataSurvivesShutdownAndReopen() async throws {
        let url = directory.appending(path: "persist.sqlite")
        let first = VaultStore(url: url)
        let cid = try await seedConversation(first)
        try await first.appendMessage(conversationId: cid, role: "user", content: "remember me")
        await first.shutdown()

        let second = VaultStore(url: url)
        let turns = try await second.loadConversation(id: cid)
        XCTAssertEqual(turns.map(\.content), ["remember me"])
    }

    func testStoresAtDifferentPathsAreIndependent() async throws {
        let a = makeStore(named: "a.sqlite")
        let b = makeStore(named: "b.sqlite")
        _ = try await seedConversation(a)
        let inB = try await b.recentConversations()
        XCTAssertTrue(inB.isEmpty, "injected paths must not share state")
    }

    // MARK: - Conversations and messages

    func testConversationRoundTripPreservesTurnOrder() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        try await store.appendMessage(conversationId: cid, role: "user", content: "first")
        try await store.appendMessage(conversationId: cid, role: "assistant", content: "second")
        try await store.appendMessage(conversationId: cid, role: "user", content: "third")

        let turns = try await store.loadConversation(id: cid)
        XCTAssertEqual(turns.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(turns.map(\.content), ["first", "second", "third"])
    }

    /// `turn_idx` is computed as `MAX(turn_idx) + 1` per conversation,
    /// so indices must not bleed across conversations.
    func testTurnIndicesAreScopedPerConversation() async throws {
        let store = makeStore()
        let one = try await seedConversation(store)
        let two = try await seedConversation(store)
        try await store.appendMessage(conversationId: one, role: "user", content: "one-a")
        try await store.appendMessage(conversationId: one, role: "user", content: "one-b")
        try await store.appendMessage(conversationId: two, role: "user", content: "two-a")

        let oneTurns = try await store.loadConversation(id: one).map(\.content)
        let twoTurns = try await store.loadConversation(id: two).map(\.content)
        XCTAssertEqual(oneTurns, ["one-a", "one-b"])
        XCTAssertEqual(twoTurns, ["two-a"])
    }

    func testFirstUserMessageAutoTitlesTheConversation() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        try await store.appendMessage(conversationId: cid, role: "user", content: "how do actors work")
        try await store.appendMessage(conversationId: cid, role: "user", content: "a later question")

        let rows = try await store.recentConversations()
        let row = try XCTUnwrap(rows.first { $0.id == cid })
        XCTAssertTrue(
            row.title.contains("how do actors work"),
            "title should come from the FIRST user message, got \(row.title)"
        )
    }

    func testAssistantMessageDoesNotSetTitle() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        try await store.appendMessage(conversationId: cid, role: "assistant", content: "unprompted")
        let rows = try await store.recentConversations()
        let row = try XCTUnwrap(rows.first { $0.id == cid })
        XCTAssertFalse(
            row.title.contains("unprompted"),
            "only user turns should title a conversation"
        )
    }

    func testMessageCountAndRecencyOrdering() async throws {
        let store = makeStore()
        let older = try await seedConversation(store, model: "older")
        let newer = try await seedConversation(store, model: "newer")
        try await store.appendMessage(conversationId: older, role: "user", content: "x")
        try await store.appendMessage(conversationId: newer, role: "user", content: "y")
        try await store.appendMessage(conversationId: newer, role: "assistant", content: "z")

        let rows = try await store.recentConversations()
        let newerRow = try XCTUnwrap(rows.first { $0.id == newer })
        let olderRow = try XCTUnwrap(rows.first { $0.id == older })
        XCTAssertEqual(newerRow.messageCount, 2)
        XCTAssertEqual(olderRow.messageCount, 1)
    }

    func testRecentConversationsRespectsLimit() async throws {
        let store = makeStore()
        for i in 0..<5 {
            let cid = try await seedConversation(store, model: "m\(i)")
            try await store.appendMessage(conversationId: cid, role: "user", content: "msg \(i)")
        }
        let rows = try await store.recentConversations(limit: 2)
        XCTAssertEqual(rows.count, 2)
    }

    // MARK: - Deletion

    /// `messages.conversation_id` declares `ON DELETE CASCADE`, which
    /// only fires when `foreignKeysEnabled` is actually set on the
    /// connection. If that configuration regressed, deleting a
    /// conversation would silently orphan its messages.
    func testDeleteConversationCascadesToMessages() async throws {
        let store = makeStore()
        let doomed = try await seedConversation(store, model: "doomed")
        let kept = try await seedConversation(store, model: "kept")
        try await store.appendMessage(conversationId: doomed, role: "user", content: "orphan candidate")
        try await store.appendMessage(conversationId: kept, role: "user", content: "survivor")

        try await store.deleteConversation(id: doomed)

        let doomedTurns = try await store.loadConversation(id: doomed)
        let keptTurns = try await store.loadConversation(id: kept).map(\.content)
        XCTAssertTrue(doomedTurns.isEmpty)
        XCTAssertEqual(keptTurns, ["survivor"])

        // The FTS index must forget it too, or search would return hits
        // pointing at rows that no longer exist.
        let hits = try await store.search(query: "orphan")
        XCTAssertTrue(hits.isEmpty, "deleted message still reachable via FTS: \(hits.map(\.snippet))")
    }

    func testClearAllEmptiesEverything() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        try await store.appendMessage(conversationId: cid, role: "user", content: "wiped")
        try await store.addTag("keepme", to: cid)

        try await store.clearAll()

        let remaining = try await store.recentConversations()
        let hits = try await store.search(query: "wiped")
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(hits.isEmpty)
    }

    // MARK: - Tags

    func testAddAndRemoveTags() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        try await store.addTag("Swift", to: cid)
        try await store.addTag("concurrency", to: cid)

        var tags = try await store.tagsForConversation(id: cid)
        XCTAssertEqual(tags, ["concurrency", "swift"], "tags are normalized and sorted")

        try await store.removeTag("SWIFT", from: cid)
        tags = try await store.tagsForConversation(id: cid)
        XCTAssertEqual(tags, ["concurrency"], "removal must match on the normalized form")
    }

    func testAddingSameTagTwiceIsIdempotent() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        try await store.addTag("dup", to: cid)
        try await store.addTag("  DUP  ", to: cid)
        let tags = try await store.tagsForConversation(id: cid)
        XCTAssertEqual(tags, ["dup"])
    }

    func testConversationSummaryCarriesItsTags() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        try await store.appendMessage(conversationId: cid, role: "user", content: "tagged")
        try await store.addTag("alpha", to: cid)
        try await store.addTag("beta", to: cid)

        let rows = try await store.recentConversations()
        let row = try XCTUnwrap(rows.first { $0.id == cid })
        XCTAssertEqual(row.tags, ["alpha", "beta"])
    }

    /// Tag filtering is documented as AND-matching: a conversation must
    /// carry every requested tag, not any of them.
    func testTagFilterRequiresEveryRequestedTag() async throws {
        let store = makeStore()
        let both = try await seedConversation(store, model: "both")
        let onlyOne = try await seedConversation(store, model: "one")
        try await store.addTag("swift", to: both)
        try await store.addTag("rag", to: both)
        try await store.addTag("swift", to: onlyOne)

        let matched = try await store.recentConversations(tags: ["swift", "rag"])
        XCTAssertEqual(matched.map(\.id), [both])

        let broader = try await store.recentConversations(tags: ["swift"])
        XCTAssertEqual(Set(broader.map(\.id)), Set([both, onlyOne]))
    }

    func testAllTagsIsDeduplicatedAcrossConversations() async throws {
        let store = makeStore()
        let a = try await seedConversation(store, model: "a")
        let b = try await seedConversation(store, model: "b")
        try await store.addTag("shared", to: a)
        try await store.addTag("shared", to: b)
        try await store.addTag("solo", to: b)

        let tags = try await store.allTags()
        XCTAssertEqual(tags, ["shared", "solo"])
    }

    func testRemovingAbsentTagIsHarmless() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        try await store.removeTag("never-added", from: cid)
        let tags = try await store.tagsForConversation(id: cid)
        XCTAssertTrue(tags.isEmpty)
    }

    // MARK: - Full-text search

    func testSearchFindsMessageAndMarksTheHit() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        try await store.appendMessage(
            conversationId: cid, role: "user", content: "the reciprocal rank fusion algorithm"
        )
        try await store.appendMessage(
            conversationId: cid, role: "assistant", content: "completely unrelated text"
        )

        let hits = try await store.search(query: "reciprocal")
        XCTAssertEqual(hits.count, 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.conversationId, cid)
        XCTAssertEqual(hit.role, "user")
        XCTAssertTrue(hit.snippet.contains("<mark>"), "snippet should mark the match: \(hit.snippet)")
    }

    func testSearchIsCaseInsensitive() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        try await store.appendMessage(conversationId: cid, role: "user", content: "Actors And Isolation")
        let hits = try await store.search(query: "actors")
        XCTAssertEqual(hits.count, 1)
    }

    func testEmptyOrWhitespaceQueryReturnsNothing() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        try await store.appendMessage(conversationId: cid, role: "user", content: "content")
        let emptyQuery = try await store.search(query: "")
        let whitespaceQuery = try await store.search(query: "   \n ")
        XCTAssertTrue(emptyQuery.isEmpty)
        XCTAssertTrue(whitespaceQuery.isEmpty)
    }

    /// FTS5 treats bare punctuation and reserved words as syntax; an
    /// unsanitized query would throw rather than return nothing.
    func testPunctuationOnlyQueryDoesNotThrow() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        try await store.appendMessage(conversationId: cid, role: "user", content: "hello world")
        let hits = try await store.search(query: "\"*^ ( ) -")
        XCTAssertTrue(hits.isEmpty)
    }

    func testSearchRespectsLimit() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        for i in 0..<6 {
            try await store.appendMessage(
                conversationId: cid, role: "user", content: "repeated needle \(i)"
            )
        }
        let hits = try await store.search(query: "needle", limit: 3)
        XCTAssertEqual(hits.count, 3)
    }

    // MARK: - Model registry

    func testRecordModelUpsertsRatherThanDuplicating() async throws {
        let store = makeStore()
        try await store.recordModel(backend: "llama", modelId: "model-a", sourceURL: "/tmp/a.gguf")
        try await store.recordModel(backend: "llama", modelId: "model-a", sourceURL: "/tmp/a.gguf")
        try await store.recordModel(backend: "mlx", modelId: "model-b")

        let models = try await store.listModels()
        XCTAssertEqual(models.count, 2, "same backend+id must update in place, got \(models)")
        XCTAssertTrue(models.contains { $0.modelId == "model-a" && $0.backend == "llama" })
        XCTAssertTrue(models.contains { $0.modelId == "model-b" && $0.backend == "mlx" })
    }

    func testSameModelIdUnderDifferentBackendsAreDistinctEntries() async throws {
        let store = makeStore()
        try await store.recordModel(backend: "llama", modelId: "shared-name")
        try await store.recordModel(backend: "mlx", modelId: "shared-name")
        let models = try await store.listModels()
        XCTAssertEqual(models.count, 2)
    }

    // MARK: - Concurrency

    /// `VectorStore` had a transaction-reentrancy defect that only
    /// concurrent writers exposed (REVIEW.md F-2a). `VaultStore` uses
    /// GRDB's `DatabasePool`, which serializes writes itself rather than
    /// wrapping an async block around an open transaction — this pins
    /// that difference instead of assuming it.
    func testConcurrentAppendsAllLand() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try await store.appendMessage(
                        conversationId: cid, role: "user", content: "concurrent \(i)"
                    )
                }
            }
            try await group.waitForAll()
        }

        let turns = try await store.loadConversation(id: cid)
        XCTAssertEqual(turns.count, 20, "concurrent appends must not lose or collide on turn_idx")
        XCTAssertEqual(
            Set(turns.map(\.content)).count, 20,
            "every distinct message should be present exactly once"
        )
    }

    func testConcurrentReadsDuringWritesDoNotFail() async throws {
        let store = makeStore()
        let cid = try await seedConversation(store)
        try await store.appendMessage(conversationId: cid, role: "user", content: "seed needle")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    try await store.appendMessage(
                        conversationId: cid, role: "assistant", content: "written \(i)"
                    )
                }
                group.addTask {
                    _ = try await store.recentConversations()
                    _ = try await store.search(query: "needle")
                    _ = try await store.allTags()
                }
            }
            try await group.waitForAll()
        }

        let turns = try await store.loadConversation(id: cid)
        XCTAssertEqual(turns.count, 9)
    }
}
