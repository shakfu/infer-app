import Foundation
import InferCore
import InferRAG

/// Auto-ingest wiki pages into the workspace's vector store so the
/// non-pinned majority of a wiki is retrievable through RAG without
/// the user having to click "Scan folder." The unique URI scheme
/// `wiki://<pageId>` distinguishes wiki sources from `data_folder`
/// files (whose URIs are local filesystem paths) so the two channels
/// can coexist in the same `sources` table.
///
/// Failures here are **non-fatal**: a save that can't be indexed
/// (because the embedder isn't loaded yet, the dimensions don't
/// match, or any other reason) still writes the `.md` file to disk
/// and surfaces in the sidebar — only the RAG side is affected.
/// The user-visible signal is a debug-level log, not a toast or
/// error dialog. The next deliberate "Scan folder" picks up the gap
/// (the wiki dir can't currently be set as the data folder, but a
/// future Phase 5b can wire that path).
extension ChatViewModel {
    private static let wikiURIScheme = "wiki://"

    /// Synthesise the per-page URI used in the `sources` table.
    /// Workspace scoping is implicit via `workspace_id`; the URI
    /// only needs to disambiguate within a workspace.
    private static func wikiURI(forPageId id: String) -> String {
        Self.wikiURIScheme + id
    }

    /// Ingest a single wiki page. Idempotent: deletes any prior
    /// source row at the same URI before inserting fresh chunks, so
    /// re-saves don't accumulate duplicates.
    func ingestWikiPage(workspaceId: Int64, pageId: String, content: String) {
        // Skip silently when the embedder isn't ready — the wiki
        // file is already on disk; the user can re-trigger indexing
        // later via the workspace's Scan button (once we wire the
        // wiki dir into that flow).
        guard embeddingModelPresent else {
            logs.log(
                .debug,
                source: "wiki",
                message: "skip auto-index for \(pageId): embedder not ready"
            )
            return
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let store = self.vectorStore
        let embedder = self.embedder
        let uri = Self.wikiURI(forPageId: pageId)
        Task { [weak self] in
            do {
                try await self?.ensureEmbeddingModelLoaded()
                try await store.ensureInitialized(
                    workspaceId: workspaceId,
                    embeddingModel: EmbeddingModelRef.filename,
                    dimension: EmbeddingModelRef.expectedDimension,
                    chunkSize: 512,
                    chunkOverlap: 50
                )
                // Replace the prior source row for this URI before
                // ingesting the new content. Empty bodies just clear
                // the index entry.
                _ = try await store.deleteSourcesByURI(
                    workspaceId: workspaceId,
                    uri: uri
                )
                guard !trimmed.isEmpty else {
                    self?.logs.log(
                        .debug,
                        source: "wiki",
                        message: "cleared index for empty page \(pageId)"
                    )
                    return
                }

                let splitter = TextSplitter(chunkSize: 512, chunkOverlap: 50)
                let chunks = splitter.split(content)
                guard !chunks.isEmpty else { return }

                var vectorChunks: [VectorChunk] = []
                vectorChunks.reserveCapacity(chunks.count)
                for chunk in chunks {
                    let vec = try await embedder.embed(chunk.content)
                    vectorChunks.append(VectorChunk(
                        content: chunk.content,
                        offsetStart: chunk.offsetStart,
                        offsetEnd: chunk.offsetEnd,
                        embedding: vec
                    ))
                }
                let hash = SourceLoader.contentHash(of: Data(content.utf8))
                _ = try await store.ingest(
                    workspaceId: workspaceId,
                    uri: uri,
                    contentHash: hash,
                    kind: "wiki",
                    chunks: vectorChunks
                )
                self?.logs.log(
                    .debug,
                    source: "wiki",
                    message: "indexed \(pageId) (\(vectorChunks.count) chunk\(vectorChunks.count == 1 ? "" : "s"))"
                )
            } catch {
                self?.logs.log(
                    .warning,
                    source: "wiki",
                    message: "auto-index failed for \(pageId)",
                    payload: String(describing: error)
                )
            }
        }
    }

    /// Remove a wiki page from the vector store. Used on delete and
    /// as the first half of move/rename. Idempotent — no-op when no
    /// matching source rows exist.
    func removeWikiPageFromIndex(workspaceId: Int64, pageId: String) {
        let store = self.vectorStore
        let uri = Self.wikiURI(forPageId: pageId)
        Task { [weak self] in
            do {
                _ = try await store.deleteSourcesByURI(
                    workspaceId: workspaceId,
                    uri: uri
                )
            } catch {
                self?.logs.log(
                    .warning,
                    source: "wiki",
                    message: "auto-deindex failed for \(pageId)",
                    payload: String(describing: error)
                )
            }
        }
    }
}
