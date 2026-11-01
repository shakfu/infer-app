import XCTest
@testable import InferRAG

final class DocumentIngestTests: XCTestCase {
    private var directory: URL!
    private var store: VectorStore!
    private let splitter = TextSplitter(chunkSize: 512, chunkOverlap: 64)

    override func setUp() async throws {
        if let failure = ragInitFailure { throw XCTSkip("vec0 unavailable: \(failure)") }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = VectorStore(url: directory.appendingPathComponent("vectors.sqlite"))
        _ = try await store.ensureInitialized(
            workspaceId: 1,
            embeddingModel: "test",
            dimension: VectorStore.dimension,
            chunkSize: 512,
            chunkOverlap: 64
        )
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
    }

    private struct EmbedFailure: Error {}

    private static func vector(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: VectorStore.dimension)
        v[0] = 1
        return v
    }

    private func ingest(
        uri: String,
        text: String,
        hash: String,
        replacing: Bool = false,
        embed: (@Sendable (String) async throws -> [Float])? = nil
    ) async throws -> DocumentIngestResult {
        try await DocumentIngest.ingest(
            into: store,
            workspaceId: 1,
            uri: uri,
            text: text,
            contentHash: hash,
            kind: "url",
            splitter: splitter,
            replacingURI: replacing,
            embed: embed ?? { Self.vector($0) }
        )
    }

    private func uris() async throws -> [String] {
        try await store.listSources(workspaceId: 1).map(\.uri).sorted()
    }

    func testAddsChunksWithKindAndURI() async throws {
        let result = try await ingest(uri: "https://x.test/a", text: "# Title\n\nBody text.", hash: "h1")
        XCTAssertEqual(result, .added(chunks: 1))
        let sources = try await store.listSources(workspaceId: 1)
        XCTAssertEqual(sources.first?.uri, "https://x.test/a")
        XCTAssertEqual(sources.first?.kind, "url")
    }

    func testDuplicateContentSkipsEmbedding() async throws {
        _ = try await ingest(uri: "a", text: "same", hash: "h")
        let result = try await ingest(uri: "b", text: "same", hash: "h", embed: { _ in throw EmbedFailure() })
        XCTAssertEqual(result, .duplicate)
        let stored = try await uris()
        XCTAssertEqual(stored, ["a"])
    }

    func testBlankTextIsEmpty() async throws {
        let result = try await ingest(uri: "a", text: "   \n", hash: "h")
        XCTAssertEqual(result, .empty)
        let stored = try await uris()
        XCTAssertTrue(stored.isEmpty)
    }

    func testChangedContentReplacesSameURI() async throws {
        _ = try await ingest(uri: "a", text: "old", hash: "h1", replacing: true)
        let result = try await ingest(uri: "a", text: "new", hash: "h2", replacing: true)
        XCTAssertEqual(result, .added(chunks: 1))
        let sources = try await store.listSources(workspaceId: 1)
        XCTAssertEqual(sources.count, 1)
    }

    func testWithoutReplacingChangedContentAddsSecondSource() async throws {
        _ = try await ingest(uri: "a", text: "old", hash: "h1")
        _ = try await ingest(uri: "a", text: "new", hash: "h2")
        let stored = try await uris()
        XCTAssertEqual(stored, ["a", "a"])
    }

    /// A failed embed must not cost the user the content already indexed.
    func testFailedEmbedKeepsOldContent() async throws {
        _ = try await ingest(uri: "a", text: "old", hash: "h1", replacing: true)
        do {
            _ = try await ingest(uri: "a", text: "new", hash: "h2", replacing: true, embed: { _ in throw EmbedFailure() })
            XCTFail("expected throw")
        } catch is EmbedFailure {}
        let holder = try await store.sourceURI(workspaceId: 1, contentHash: "h1")
        XCTAssertEqual(holder, "a")
    }

    func testReplacingKeepsSourceWhenContentIsUnchanged() async throws {
        _ = try await ingest(uri: "a", text: "same", hash: "h", replacing: true)
        let result = try await ingest(uri: "a", text: "same", hash: "h", replacing: true)
        XCTAssertEqual(result, .duplicate)
        let stored = try await uris()
        XCTAssertEqual(stored, ["a"])
    }

    /// A page edited to match another source must not keep its old chunks.
    func testReplacingDropsOldContentWhenAnotherURIHoldsTheNewContent() async throws {
        _ = try await ingest(uri: "a", text: "shared", hash: "shared", replacing: true)
        _ = try await ingest(uri: "b", text: "old b", hash: "b1", replacing: true)
        let result = try await ingest(uri: "b", text: "shared", hash: "shared", replacing: true)
        XCTAssertEqual(result, .duplicate)
        let stored = try await uris()
        XCTAssertEqual(stored, ["a"])
    }
}
