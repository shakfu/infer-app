import Foundation
import InferRAG

/// One retrieved chunk attached to an assistant reply. Rendered in the
/// transcript as a collapsed "Sources" disclosure so the user can see
/// which passages the model was given. Ephemeral — lives only in the
/// in-memory `ChatMessage` for the current session; not persisted to
/// the vault in MVP (history UI shows messages only, not their
/// provenance).
struct RetrievedChunkRef: Equatable, Sendable {
    let sourceURI: String
    let ord: Int
    /// Trimmed preview of the chunk body — the full content was in the
    /// prompt, but we store only a short preview here to keep message
    /// rows small in memory.
    let preview: String
    /// Raw cosine distance reported by sqlite-vec. Smaller = closer.
    let distance: Double
}

/// Result of `RAGPipeline.augment`. `augmentedText` is what we send to
/// the runner; when no chunks survive the threshold, it's identical to
/// the caller's original text (the pipeline is a no-op rather than an
/// error). `chunks` is attached to the assistant message for the UI.
struct RAGAugmentation {
    let augmentedText: String
    let chunks: [RetrievedChunkRef]

    /// Whether retrieval actually contributed context. Used by the
    /// transcript to decide whether to render a Sources disclosure.
    var didAugment: Bool { !chunks.isEmpty }

    static let empty = RAGAugmentation(augmentedText: "", chunks: [])
}

extension ChatViewModel {
    /// RAG configuration — kept here for a single source of truth so
    /// the query path and the ingest path can't drift. If these become
    /// user-configurable, they move to `InferSettings` or a workspace
    /// column.
    fileprivate static let ragTopK: Int = 5
    /// Candidate-pool size when reranking is enabled. The hybrid
    /// retrieval returns this many, the cross-encoder re-scores
    /// them, then we keep the top `ragTopK`. 30 is the standard
    /// reranker-paper default — a big enough pool for the cross-
    /// encoder to surface chunks that would otherwise sit at rank
    /// 6–10, without blowing up the per-turn latency (~1–2s extra
    /// at 30 pairs on M-series hardware).
    fileprivate static let rerankCandidates: Int = 30
    /// Cosine distance threshold for retrieved chunks. sqlite-vec
    /// emits distance in [0, 2] for cosine; lower is better. An
    /// irrelevant match typically sits >1.0, a plausible match
    /// <0.5. The threshold errs on the side of inclusion — a weak
    /// match rarely hurts (the model ignores irrelevant context) but
    /// a missed match can turn a correct answer into a hallucination.
    fileprivate static let ragDistanceThreshold: Double = 1.2

    /// True if the active (or passed) workspace has retrieval set up:
    /// a data folder is configured and the vector store has at least
    /// one indexed source. Used to decide whether to augment a user
    /// turn. We don't expose an explicit per-workspace on/off toggle
    /// in MVP — the user's action of scanning the folder is the
    /// enable signal.
    func workspaceHasCorpus(_ workspaceId: Int64) async -> Bool {
        guard let ws = workspaces.first(where: { $0.id == workspaceId }),
              let folder = ws.dataFolder,
              !folder.isEmpty
        else { return false }
        do {
            let (nSources, _) = try await vectorStore.sourceStatistics(
                workspaceId: workspaceId
            )
            return nSources > 0
        } catch {
            return false
        }
    }

    /// Augment `userText` with retrieved context from the active
    /// workspace's RAG corpus. Returns the (possibly unchanged) text
    /// plus the chunks that were injected. No-ops when no workspace
    /// is active, no corpus exists, the embedder fails to load, or
    /// no chunks survive the threshold.
    ///
    /// Failures short-circuit to "no augmentation" rather than
    /// throwing — RAG is a quality-of-life feature, not a correctness
    /// requirement. A retrieval failure should never block the user
    /// from getting a plain-prompt reply.
    func runRAGIfAvailable(userText: String) async -> RAGAugmentation {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RAGAugmentation(augmentedText: userText, chunks: [])
        }
        guard let workspaceId = activeWorkspaceId else {
            return RAGAugmentation(augmentedText: userText, chunks: [])
        }
        let hasCorpus = await workspaceHasCorpus(workspaceId)
        guard hasCorpus else {
            return RAGAugmentation(augmentedText: userText, chunks: [])
        }

        // Ensure the embedder is loaded. Lazy — first query per
        // session pays the ~500ms load, subsequent queries don't.
        do {
            try await ensureEmbeddingModelLoaded()
        } catch {
            logs.log(
                .warning,
                source: "rag",
                message: "query skipped: embedder not available",
                payload: String(describing: error)
            )
            return RAGAugmentation(augmentedText: userText, chunks: [])
        }

        // HyDE: if this workspace opted in, ask the chat model to
        // write a hypothetical passage answering the user's question,
        // and embed *that* for dense retrieval. Improves recall on
        // queries whose vocabulary doesn't overlap with the source
        // corpus (e.g., "where did he hide X" vs. a scene that uses
        // "bury" / "conceal"). The hypothetical acts as a lexical
        // bridge between query-space and document-space.
        //
        // Keyword retrieval still uses the ORIGINAL user text — FTS
        // wants the user's actual terms, not a fictional expansion.
        // Failures downgrade to plain retrieval silently; HyDE is
        // additive, never required.
        let hydeEnabled = workspaceSetting(
            .hydeEnabled,
            workspaceId: workspaceId
        )
        var textForEmbedding = trimmed
        var hydeHypothetical: String? = nil
        if hydeEnabled {
            hydeHypothetical = await runHyDE(userQuery: trimmed)
            if let h = hydeHypothetical, !h.isEmpty {
                textForEmbedding = h
            }
        }

        // Embed the query (either original or HyDE hypothetical). If
        // this fails, skip augmentation rather than propagate — user
        // gets a plain reply instead of an error.
        let queryVec: [Float]
        do {
            queryVec = try await embedder.embed(textForEmbedding)
        } catch {
            logs.log(
                .warning,
                source: "rag",
                message: "query embedding failed",
                payload: String(describing: error)
            )
            return RAGAugmentation(augmentedText: userText, chunks: [])
        }

        // Retrieve via hybrid search (dense + FTS5, fused by RRF
        // inside VectorStore). When reranking is enabled we over-
        // fetch to `rerankCandidates` (typically 30) so the cross-
        // encoder has a pool to pick from; otherwise take the
        // hybrid-fused top-K directly.
        let rerankEnabled = workspaceSetting(
            .rerankEnabled,
            workspaceId: workspaceId
        )
        let fetchK = rerankEnabled ? Self.rerankCandidates : Self.ragTopK
        let rawHits: [VectorSearchHit]
        do {
            rawHits = try await vectorStore.search(
                workspaceId: workspaceId,
                queryEmbedding: queryVec,
                queryText: trimmed,
                k: fetchK
            )
        } catch {
            logs.log(
                .warning,
                source: "rag",
                message: "vector search failed",
                payload: String(describing: error)
            )
            return RAGAugmentation(augmentedText: userText, chunks: [])
        }

        // Rerank step: if the workspace opted in AND the reranker
        // model is available, score every candidate with the
        // cross-encoder, sort by score descending, keep top-K.
        // Failures downgrade to the hybrid-fused order — rerank is
        // quality polish, not correctness-critical.
        var hits: [VectorSearchHit] = rawHits
        var rerankTag = ""
        if rerankEnabled, !rawHits.isEmpty {
            do {
                try await ensureRerankerLoaded()
                let rerankStart = Date()
                let docs = rawHits.map { $0.content }
                let scores = try await reranker.scoreMany(
                    query: trimmed,
                    documents: docs
                )
                // Pair hits with scores, stable-sort by score
                // descending, truncate to topK. A hit's vector
                // distance is preserved — the reranker score is
                // separate signal that determines ordering only.
                let paired = zip(rawHits, scores).sorted { $0.1 > $1.1 }
                hits = paired.prefix(Self.ragTopK).map { $0.0 }
                let elapsed = Date().timeIntervalSince(rerankStart)
                let bestScore = paired.first?.1 ?? Float.nan
                rerankTag = " [rerank: top5 of \(rawHits.count) in \(String(format: "%.1f", elapsed))s, best=\(String(format: "%.2f", bestScore))]"
            } catch {
                logs.log(
                    .warning,
                    source: "rerank",
                    message: "rerank failed; falling back to hybrid order",
                    payload: String(describing: error)
                )
                hits = Array(rawHits.prefix(Self.ragTopK))
                rerankTag = " [rerank error]"
            }
        } else if rawHits.count > Self.ragTopK {
            // Non-rerank path that over-fetched anyway (shouldn't
            // happen unless caller tweaks rerankEnabled after the
            // search returned — defensive prefix).
            hits = Array(rawHits.prefix(Self.ragTopK))
        }

        let relevant = hits.filter { $0.distance <= Self.ragDistanceThreshold }
        guard !relevant.isEmpty else {
            logs.log(
                .info,
                source: "rag",
                message: "no chunks passed threshold (best=\(String(format: "%.3f", hits.first?.distance ?? .infinity)))"
            )
            return RAGAugmentation(augmentedText: userText, chunks: [])
        }

        let augmented = Self.formatPrompt(userText: userText, chunks: relevant)
        let refs = relevant.map { hit in
            RetrievedChunkRef(
                sourceURI: hit.sourceURI,
                ord: hit.ord,
                preview: Self.previewFor(hit.content),
                distance: hit.distance
            )
        }

        // Hybrid-retrieval diagnostics: tell the user in the Console
        // whether dense + FTS both contributed, whether FTS errored,
        // and how many raw hits each retriever produced. Makes it
        // possible to diagnose "why does hybrid give the same result
        // as vector alone" without attaching a debugger.
        let diag = await vectorStore.lastSearchDiagnostics
        let fusionTag: String
        if let diag {
            if let ftsErr = diag.ftsError {
                fusionTag = " [fts error: \(ftsErr)]"
            } else if diag.usedFusion {
                fusionTag = " [hybrid: \(diag.vectorHits)v+\(diag.ftsHits)f]"
            } else if diag.ftsQuery.isEmpty {
                fusionTag = " [vector-only: no fts query]"
            } else {
                fusionTag = " [vector-only: fts returned 0 for '\(diag.ftsQuery)']"
            }
        } else {
            fusionTag = ""
        }
        let hydeTag = (hydeHypothetical?.isEmpty == false) ? " [hyde]" : ""
        logs.log(
            .info,
            source: "rag",
            message: "augmented with \(relevant.count) chunk\(relevant.count == 1 ? "" : "s") (best=\(String(format: "%.3f", relevant.first!.distance)))\(fusionTag)\(hydeTag)\(rerankTag)"
        )
        return RAGAugmentation(augmentedText: augmented, chunks: refs)
    }

    /// Ask the chat model to generate a hypothetical passage
    /// answering the user's query. That passage is used for dense
    /// retrieval (not shown to the user). Fires only when the
    /// active workspace has HyDE enabled. Returns nil on failure —
    /// callers fall back to direct retrieval.
    ///
    /// The prompt is pragmatic, adapted from the HyDE paper
    /// (Precise Zero-Shot Dense Retrieval without Relevance
    /// Labels, Gao et al. 2022): ask for a specific, grounded
    /// passage matching the query. Low-temperature sampling inside
    /// the runner keeps outputs focused.
    private func runHyDE(userQuery: String) async -> String? {
        let prompt = """
        Write a short factual passage from a document that would directly answer this question. Include specific details, names, and concrete language that would likely appear in a genuine answer. Keep it to 2–4 sentences. Do not add disclaimers or meta-commentary.

        Question: \(userQuery)

        Passage:
        """

        let started = Date()
        let hypothetical: String
        do {
            switch backend {
            case .llama:
                hypothetical = try await llama.generateOneShot(
                    prompt: prompt,
                    maxTokens: 180
                )
            case .mlx:
                hypothetical = try await mlx.generateOneShot(
                    prompt: prompt,
                    maxTokens: 180
                )
            case .cloud:
                // Cloud has no side-effect-free generation primitive yet
                // — calling `sendUserMessage` would pollute the user's
                // chat transcript with the HyDE prompt. Skip HyDE on
                // cloud and fall back to direct query at the call site.
                logs.log(
                    .debug,
                    source: "rag",
                    message: "HyDE skipped (cloud backend); falling back to direct query"
                )
                return nil
            }
        } catch {
            logs.log(
                .warning,
                source: "rag",
                message: "HyDE generation failed; falling back to direct query",
                payload: String(describing: error)
            )
            return nil
        }

        let trimmed = hypothetical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            logs.log(
                .warning,
                source: "rag",
                message: "HyDE produced empty text; falling back to direct query"
            )
            return nil
        }

        let elapsed = Date().timeIntervalSince(started)
        logs.log(
            .debug,
            source: "rag",
            message: "HyDE hypothetical (\(trimmed.count) chars, \(String(format: "%.1f", elapsed))s)",
            payload: trimmed
        )
        return trimmed
    }

    /// Build the augmented user prompt. We prepend a context block
    /// rather than modifying the system prompt so agent personas keep
    /// full control of their system prompt — RAG sits on top.
    ///
    /// Template is pragmatic, adapted from cyllama's default. The
    /// "answer directly" line discourages the model from echoing the
    /// context back at the user, which is a common failure mode when
    /// the context contains the answer verbatim.
    private static func formatPrompt(
        userText: String,
        chunks: [VectorSearchHit]
    ) -> String {
        var body = "Use the following context to answer the question. If the context doesn't contain the information needed, say so.\n\nContext:\n"
        for (i, hit) in chunks.enumerated() {
            let label = (hit.sourceURI as NSString).lastPathComponent
            body += "\n[\(i + 1)] (\(label), chunk \(hit.ord))\n"
            body += hit.content
            body += "\n"
        }
        body += "\nQuestion: \(userText)\n\nAnswer:"
        return body
    }

    /// Collapse whitespace and clip to ~160 characters for the
    /// transcript's Sources disclosure. The full text is in the
    /// prompt the model saw; this is just for humans skimming.
    private static func previewFor(_ content: String) -> String {
        let collapsed = content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 160 { return collapsed }
        let idx = collapsed.index(collapsed.startIndex, offsetBy: 160)
        return String(collapsed[..<idx]) + "…"
    }
}
