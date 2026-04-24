import Foundation
import llama

enum RerankerError: Error, CustomStringConvertible {
    case notLoaded
    case modelLoadFailed(String)
    case contextCreationFailed
    case tokenizationFailed(Int32)
    case encodeFailed(Int32)
    case scoreBufferMissing
    case concurrentCall
    case emptyPair

    var description: String {
        switch self {
        case .notLoaded: return "reranker model not loaded"
        case .modelLoadFailed(let path): return "failed to load reranker at \(path)"
        case .contextCreationFailed: return "failed to create reranker context"
        case .tokenizationFailed(let code): return "reranker tokenization failed (code \(code))"
        case .encodeFailed(let code): return "reranker llama_encode failed (code \(code))"
        case .scoreBufferMissing: return "reranker returned no score buffer"
        case .concurrentCall: return "concurrent reranker call — serialize at the caller"
        case .emptyPair: return "cannot rerank an empty query or document"
        }
    }
}

/// Actor wrapping a llama.cpp context configured for cross-encoder
/// reranking. Parallel to `EmbeddingRunner` but uses
/// `LLAMA_POOLING_TYPE_RANK`: the model reads (query, document)
/// pairs together and emits a single relevance score per pair,
/// rather than producing per-token embeddings.
///
/// Why a separate runner:
///   - Different pooling config than embeddings (RANK vs NONE).
///   - Different model (bge-reranker vs bge-embed), so separate
///     context anyway.
///   - Scoring uses a different llama.cpp code path
///     (`llama_get_embeddings_seq` with `n_cls_out = 1`).
///
/// Lifecycle mirrors `EmbeddingRunner`: lazy-init, stay-resident,
/// `shutdown()` called from `AppDelegate.applicationWillTerminate`.
actor RerankerRunner {
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private(set) var modelPath: String? = nil

    /// Cached BOS / SEP token ids from the loaded vocab. Cross-
    /// encoder input format is `[BOS/CLS] query [SEP] doc [SEP]` —
    /// we build the token stream manually rather than relying on
    /// any chat template (reranker models don't have one).
    private var bosToken: llama_token = 0
    private var sepToken: llama_token = 0

    /// Cooperative busy flag — llama_encode on a single context is
    /// not safe to re-enter. The actor boundary serializes calls
    /// naturally; this flag catches programmer error from nested
    /// Task chains.
    private var busy: Bool = false

    var isLoaded: Bool { ctx != nil }

    init() {}

    /// Load a reranker GGUF. Idempotent — re-loading the same path
    /// is a no-op; loading a different path tears down prior state.
    func load(modelPath path: String) throws {
        LlamaRunner.ensureBackend()

        if modelPath == path, ctx != nil {
            return
        }
        tearDown()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 999

        guard let m = llama_model_load_from_file(path, mparams) else {
            throw RerankerError.modelLoadFailed(path)
        }
        self.model = m
        self.vocab = llama_model_get_vocab(m)

        var cparams = llama_context_default_params()
        // BGE rerankers are trained on 512-token sequences. We need
        // headroom for query + SEP + doc; 1024 gives comfortable
        // space for typical chat queries + a full 512-char chunk.
        cparams.n_ctx = 1024
        cparams.n_batch = 1024
        cparams.n_ubatch = 1024
        cparams.embeddings = true
        cparams.pooling_type = LLAMA_POOLING_TYPE_RANK

        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            self.model = nil
            self.vocab = nil
            throw RerankerError.contextCreationFailed
        }
        self.ctx = c

        if let v = self.vocab {
            self.bosToken = llama_vocab_bos(v)
            self.sepToken = llama_vocab_sep(v)
        }
        self.modelPath = path
    }

    /// Score a single (query, document) pair. Higher score = more
    /// relevant. BGE reranker output is a raw logit (typically in
    /// `[-10, 10]`); callers compare scores within a single call's
    /// results, not against an absolute threshold.
    ///
    /// Sequential — batching multiple pairs through `llama_encode`
    /// in one go is an optimization for later. Typical latency:
    /// ~30–80 ms per pair on M-series for bge-reranker-v2-m3,
    /// so 30 candidates ≈ 1–2 seconds added to a RAG turn.
    func score(query: String, document: String) throws -> Float {
        guard let ctx, let vocab else { throw RerankerError.notLoaded }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let d = document.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !d.isEmpty else { throw RerankerError.emptyPair }
        guard !busy else { throw RerankerError.concurrentCall }
        busy = true
        defer { busy = false }

        // Tokenize query with BOS/CLS, document without. Then
        // concatenate: [BOS] q-tokens [SEP] d-tokens [SEP].
        let maxTokens = Int32(1024)
        var qBuf = [llama_token](repeating: 0, count: Int(maxTokens))
        let nQ = q.withCString { cstr -> Int32 in
            llama_tokenize(
                vocab, cstr, Int32(strlen(cstr)),
                &qBuf, maxTokens,
                /* add_special */ true,
                /* parse_special */ false
            )
        }
        if nQ <= 0 { throw RerankerError.tokenizationFailed(nQ) }

        // Leave room for SEP markers (2) + doc tokens.
        let docBudget = Int32(maxTokens - nQ - 2)
        guard docBudget > 16 else {
            // Query filled nearly the whole context. Cross-encoders
            // still work (sort of) on query-only input — the score
            // just won't reflect the doc. Rare; bail out to avoid
            // garbage ranking.
            throw RerankerError.tokenizationFailed(-1)
        }
        var dBuf = [llama_token](repeating: 0, count: Int(docBudget))
        let nD = d.withCString { cstr -> Int32 in
            llama_tokenize(
                vocab, cstr, Int32(strlen(cstr)),
                &dBuf, docBudget,
                /* add_special */ false,
                /* parse_special */ false
            )
        }
        if nD <= 0 { throw RerankerError.tokenizationFailed(nD) }

        var tokens: [llama_token] = []
        tokens.reserveCapacity(Int(nQ + nD + 2))
        tokens.append(contentsOf: qBuf.prefix(Int(nQ)))
        tokens.append(sepToken)
        tokens.append(contentsOf: dBuf.prefix(Int(nD)))
        tokens.append(sepToken)

        // Clear any residual state from prior encodes so this pair's
        // logits aren't contaminated.
        if let mem = llama_get_memory(ctx) {
            llama_memory_clear(mem, true)
        }

        let encodeStatus: Int32 = tokens.withUnsafeMutableBufferPointer { ptr in
            let batch = llama_batch_get_one(ptr.baseAddress, Int32(ptr.count))
            return llama_encode(ctx, batch)
        }
        if encodeStatus != 0 {
            throw RerankerError.encodeFailed(encodeStatus)
        }

        // With POOLING_TYPE_RANK, llama_get_embeddings_seq returns a
        // float[n_cls_out]. For bge-reranker-v2-m3, n_cls_out is 1
        // — a single relevance logit. We read the first (and only)
        // entry.
        guard let raw = llama_get_embeddings_seq(ctx, 0) else {
            throw RerankerError.scoreBufferMissing
        }
        return raw[0]
    }

    /// Batch-score multiple documents against one query. Sequential
    /// under the hood; exposed as a batch API so callers don't have
    /// to loop + collect errors themselves. Skips pairs that throw
    /// and logs nothing — the caller is expected to fall back to
    /// unranked results if too many fail.
    func scoreMany(
        query: String,
        documents: [String]
    ) async throws -> [Float] {
        var scores: [Float] = []
        scores.reserveCapacity(documents.count)
        for doc in documents {
            let s = try score(query: query, document: doc)
            scores.append(s)
        }
        return scores
    }

    func shutdown() {
        tearDown()
    }

    private func tearDown() {
        if let ctx {
            llama_free(ctx)
            self.ctx = nil
        }
        if let model {
            llama_model_free(model)
            self.model = nil
        }
        self.vocab = nil
        self.bosToken = 0
        self.sepToken = 0
        self.modelPath = nil
    }
}
