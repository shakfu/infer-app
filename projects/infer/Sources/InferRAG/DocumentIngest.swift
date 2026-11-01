import Foundation

public enum DocumentIngestResult: Equatable, Sendable {
    case added(chunks: Int)
    /// The workspace already holds this content under some URI.
    case duplicate
    /// The splitter produced no chunks.
    case empty
}

/// The split, embed and store sequence shared by every ingest entry point.
public enum DocumentIngest {
    /// - Parameter replacingURI: remove older content stored under `uri`, for
    ///   sources whose content changes (wiki pages, URLs). The removal runs
    ///   after embedding, so a failed embed leaves the old content in place.
    @discardableResult
    public static func ingest(
        into store: VectorStore,
        workspaceId: Int64,
        uri: String,
        text: String,
        contentHash: String,
        kind: String,
        splitter: TextSplitter,
        replacingURI: Bool = false,
        embed: @Sendable (String) async throws -> [Float]
    ) async throws -> DocumentIngestResult {
        if let holder = try await store.sourceURI(workspaceId: workspaceId, contentHash: contentHash) {
            if replacingURI, holder != uri {
                try await store.deleteSourcesByURI(workspaceId: workspaceId, uri: uri)
            }
            return .duplicate
        }
        let chunks = splitter.split(text)
        guard !chunks.isEmpty else { return .empty }

        let outline = SectionOutline(text)
        var vectorChunks: [VectorChunk] = []
        vectorChunks.reserveCapacity(chunks.count)
        for chunk in chunks {
            vectorChunks.append(VectorChunk(
                content: chunk.content,
                offsetStart: chunk.offsetStart,
                offsetEnd: chunk.offsetEnd,
                embedding: try await embed(chunk.content),
                section: outline.label(for: chunk, overlap: splitter.chunkOverlap)
            ))
        }
        if replacingURI {
            try await store.deleteSourcesByURI(workspaceId: workspaceId, uri: uri)
        }
        try await store.ingest(
            workspaceId: workspaceId,
            uri: uri,
            contentHash: contentHash,
            kind: kind,
            chunks: vectorChunks
        )
        return .added(chunks: vectorChunks.count)
    }
}
