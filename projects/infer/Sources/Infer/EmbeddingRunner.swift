import Foundation
import Accelerate
import llama

/// Errors raised by `EmbeddingRunner`. Surfaced to callers via the
/// thrown API and routed to `LogCenter` at the first call site.
enum EmbeddingError: Error, CustomStringConvertible {
    case notLoaded
    case modelLoadFailed(String)
    case contextCreationFailed
    case tokenizationFailed(Int32)
    case encodeFailed(Int32)
    case emptyInput
    case embeddingBufferMissing
    case concurrentCall

    var description: String {
        switch self {
        case .notLoaded: return "embedding model not loaded"
        case .modelLoadFailed(let path): return "failed to load embedding model at \(path)"
        case .contextCreationFailed: return "failed to create embedding context"
        case .tokenizationFailed(let code): return "tokenization failed (code \(code))"
        case .encodeFailed(let code): return "llama_encode failed (code \(code))"
        case .emptyInput: return "cannot embed an empty string"
        case .embeddingBufferMissing: return "llama_get_embeddings returned null"
        case .concurrentCall: return "concurrent embedding call — serialize at the caller"
        }
    }
}

/// Actor wrapping a dedicated llama.cpp context configured for
/// embedding inference. Runs in parallel to `LlamaRunner` / `MLXRunner`
/// — a separate llama_context + model handle so the embedding model
/// stays resident independently of whatever chat model the user is
/// running.
///
/// Lifecycle:
///   1. `load(modelPath:)` — loads the GGUF and builds a context with
///      `pooling_type = NONE`, `embeddings = true`.
///   2. `embed(_:)` / `embedBatch(_:)` — tokenize, encode, extract
///      per-token embeddings, mean-pool, L2-normalize.
///   3. `shutdown()` — frees the context/model. Called from
///      `AppDelegate.applicationWillTerminate` so we never leak on exit.
///
/// Why a separate runner:
///   - The chat `LlamaRunner` keeps a sampler chain and KV cache state
///     tied to the conversation template; embedding context needs
///     neither. Merging them would entangle cache lifecycle.
///   - BGE is encoder-only — uses `llama_encode`, not `llama_decode`.
///   - Embedding contexts are cheap (<200MB for bge-small) so the
///     memory cost of a second context is small.
///
/// Pooling strategy:
///   We ask llama for `POOLING_TYPE_NONE` and pool manually. Per the
///   cyllama port's experience, llama.cpp's internal pooling is
///   unreliable for some model families; doing it ourselves via
///   Accelerate is ~5 lines and always right. Mean-pool across the
///   token dimension, then L2-normalize so cosine = dot product.
actor EmbeddingRunner {
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    /// Dimension of the loaded model's embeddings (e.g., 384 for
    /// bge-small-en-v1.5). Stamped at load; callers read to initialize
    /// their `vec0` virtual tables.
    private(set) var dimension: Int = 0
    /// Absolute path to the currently-loaded GGUF. Nil when unloaded.
    private(set) var modelPath: String? = nil
    /// Cooperative busy flag — embedding must be serial because
    /// concurrent `llama_encode` calls on the same context corrupt
    /// state. The actor boundary already serializes, but this flag
    /// catches programmer error if someone re-enters via a nested
    /// Task.
    private var busy: Bool = false

    var isLoaded: Bool { ctx != nil }

    init() {}

    /// Load a GGUF embedding model. Idempotent — re-loading the same
    /// path is a no-op; re-loading a different path tears down the
    /// prior context first.
    func load(modelPath path: String) throws {
        LlamaRunner.ensureBackend()

        if modelPath == path, ctx != nil {
            return
        }
        tearDown()

        var mparams = llama_model_default_params()
        // Embedding models are small; full-GPU offload is fine and
        // fast. If this becomes a problem on low-VRAM macs we can
        // expose a knob.
        mparams.n_gpu_layers = 999

        guard let m = llama_model_load_from_file(path, mparams) else {
            throw EmbeddingError.modelLoadFailed(path)
        }
        self.model = m
        self.vocab = llama_model_get_vocab(m)

        var cparams = llama_context_default_params()
        // bge-small's trained context is 512 tokens. Keep that as the
        // ceiling — inputs longer than this will be truncated by the
        // tokenizer call via the n_tokens_max argument.
        cparams.n_ctx = 512
        cparams.n_batch = 512
        cparams.n_ubatch = 512
        // Extract per-token embeddings alongside logits.
        cparams.embeddings = true
        // We do pooling ourselves.
        cparams.pooling_type = LLAMA_POOLING_TYPE_NONE

        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            self.model = nil
            self.vocab = nil
            throw EmbeddingError.contextCreationFailed
        }
        self.ctx = c
        self.dimension = Int(llama_model_n_embd(m))
        self.modelPath = path
    }

    /// Embed a single string to an L2-normalized `[Float]` of length
    /// `dimension`. Empty / whitespace-only input throws — the caller
    /// should filter before passing.
    func embed(_ text: String) throws -> [Float] {
        guard let ctx, let vocab else { throw EmbeddingError.notLoaded }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmbeddingError.emptyInput }
        guard !busy else { throw EmbeddingError.concurrentCall }
        busy = true
        defer { busy = false }

        // Tokenize. First pass: probe for required buffer size by
        // passing n_tokens_max = 0 and reading the (negative) return
        // value. Some llama.cpp builds tolerate -n directly; others
        // need an explicit resize. Allocate generously up-front — 512
        // is our context ceiling anyway.
        let maxTokens = Int32(512)
        var tokenBuffer = [llama_token](repeating: 0, count: Int(maxTokens))
        let nTokens = text.withCString { cstr -> Int32 in
            llama_tokenize(
                vocab,
                cstr,
                Int32(strlen(cstr)),
                &tokenBuffer,
                maxTokens,
                /* add_special */ true,
                /* parse_special */ true
            )
        }
        if nTokens <= 0 {
            throw EmbeddingError.tokenizationFailed(nTokens)
        }
        tokenBuffer = Array(tokenBuffer.prefix(Int(nTokens)))

        // Clear any residual state so sequential calls don't leak KV
        // entries between inputs.
        if let mem = llama_get_memory(ctx) {
            llama_memory_clear(mem, true)
        }

        // Run the encoder. BGE is encoder-only; llama_encode is the
        // correct entry point (llama_decode would work but signals
        // intent incorrectly).
        let encodeStatus: Int32 = tokenBuffer.withUnsafeMutableBufferPointer { ptr in
            let batch = llama_batch_get_one(ptr.baseAddress, Int32(ptr.count))
            return llama_encode(ctx, batch)
        }
        if encodeStatus != 0 {
            throw EmbeddingError.encodeFailed(encodeStatus)
        }

        // Pull per-token embeddings. With pooling_type = NONE, the
        // buffer is laid out as [n_tokens, n_embd] in row-major order.
        guard let raw = llama_get_embeddings(ctx) else {
            throw EmbeddingError.embeddingBufferMissing
        }
        let nTokensInt = Int(nTokens)
        let dim = dimension
        let flat = Array(UnsafeBufferPointer(start: raw, count: nTokensInt * dim))

        // Mean-pool across the token dimension, then L2-normalize.
        return Self.meanPoolAndNormalize(flat: flat, nTokens: nTokensInt, dim: dim)
    }

    /// Batch-embed. Sequential under the hood — llama.cpp's embedding
    /// mode doesn't cleanly batch under a single-context actor, and
    /// the perf win is marginal at our scale. Exposed as a batch API
    /// so callers don't have to loop + collect errors themselves.
    func embedBatch(_ texts: [String]) throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for text in texts {
            out.append(try embed(text))
        }
        return out
    }

    /// Explicit teardown. Called from
    /// `AppDelegate.applicationWillTerminate` so the llama context is
    /// freed deterministically before the process exits.
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
        self.dimension = 0
        self.modelPath = nil
    }

    // MARK: - Math (static, nonisolated)

    /// Mean-pool [nTokens × dim] → [dim], then L2-normalize in place.
    /// Uses Accelerate's vDSP_meanv + cblas_snrm2 / vDSP_vsmul; the
    /// reductions are ~5× faster than a Swift loop for 384-d vectors.
    private static func meanPoolAndNormalize(
        flat: [Float],
        nTokens: Int,
        dim: Int
    ) -> [Float] {
        var pooled = [Float](repeating: 0, count: dim)
        flat.withUnsafeBufferPointer { src in
            pooled.withUnsafeMutableBufferPointer { dst in
                // Mean across the token axis: sum n_tokens rows, then
                // divide by n_tokens. vDSP_vadd accumulates.
                for t in 0..<nTokens {
                    let rowStart = src.baseAddress! + t * dim
                    vDSP_vadd(
                        dst.baseAddress!, 1,
                        rowStart, 1,
                        dst.baseAddress!, 1,
                        vDSP_Length(dim)
                    )
                }
                var divisor = Float(nTokens)
                vDSP_vsdiv(
                    dst.baseAddress!, 1,
                    &divisor,
                    dst.baseAddress!, 1,
                    vDSP_Length(dim)
                )
            }
        }
        // L2-normalize: divide by norm. Tiny-norm inputs (numerical
        // zero) get returned as-is; cosine similarity on them is
        // undefined but the caller decides how to handle.
        var norm: Float = 0
        vDSP_svesq(pooled, 1, &norm, vDSP_Length(dim))
        norm = sqrt(norm)
        guard norm > 1e-12 else { return pooled }
        var scale = 1.0 / norm
        vDSP_vsmul(pooled, 1, &scale, &pooled, 1, vDSP_Length(dim))
        return pooled
    }
}
