import Foundation
import LlamaCpp
import InferAgents
import InferCore

enum LlamaError: Error {
    case backendNotReady
    case modelLoadFailed(String)
    case contextCreationFailed
    case tokenizationFailed
    case decodeFailed(Int32)
    case templateFailed
    case busy
    case cancelled
}

/// Context-window usage snapshot. `total` may be nil when the backend doesn't
/// expose a configured context size (e.g. MLX estimates from character count).
struct TokenUsage: Equatable, Sendable {
    let used: Int
    let total: Int?
}

/// Thread-safe cancellation flag usable from any isolation context.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
    func reset() { lock.lock(); flag = false; lock.unlock() }
}

/// Transportable bundle of llama C pointers for handoff to a detached
/// decode task. OpaquePointer / UnsafeMutablePointer aren't Sendable by
/// default; we assert it here because (a) they're trivially-copyable
/// primitive values and (b) the actor serializes their lifetime — the
/// pointers outlive any in-flight decode because `shutdown` / `load`
/// only run when `isGenerating == false`.
private struct LlamaHandles: @unchecked Sendable {
    let ctx: OpaquePointer
    let sampler: UnsafeMutablePointer<llama_sampler>
    let vocab: OpaquePointer
}

/// Owns all llama.cpp state. The actor serializes mutation of model/context/
/// conversation state; the hot decode loop runs on a detached task so that
/// other actor messages (e.g. `requestStop`) can be processed while a
/// generation is in flight.
actor LlamaRunner {
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var vocab: OpaquePointer?

    private var modelPath: String?
    private var chatTemplate: String?
    private var systemPrompt: String?
    private var samplerTemperature: Float = 0.8
    private var samplerTopP: Float = 0.95
    private var samplerTopK: Int32 = 40
    /// Optional fixed seed. `nil` uses `LLAMA_DEFAULT_SEED` (random). Stored
    /// as UInt32 since that's what `llama_sampler_init_dist` takes — the
    /// UInt64 upstream is truncated.
    private var samplerSeed: UInt32 = UInt32(LLAMA_DEFAULT_SEED)
    /// Special token IDs for `<think>` and `</think>`, populated at load
    /// time by tokenising those literal strings against the model's vocab
    /// with `parse_special=true`. nil when the loaded model doesn't have
    /// them as single special tokens (base models, non-reasoning models).
    /// When non-nil, `runDecodeLoop` emits sentinel chars on these IDs so
    /// `ThinkBlockStreamFilter` can switch from string-match to authoritative
    /// token-based detection — robust against models that emit the literal
    /// string `</think>` inside their reasoning.
    private var thinkOpenTokenId: llama_token?
    private var thinkCloseTokenId: llama_token?
    private var messages: [(role: String, content: String)] = []
    /// Length (in bytes) of the last template render with `add_ass=false`.
    /// Used to compute the prompt delta for each new turn.
    private var prevFormattedLen: Int = 0
    private var isGenerating: Bool = false

    private let cancelFlag = CancelFlag()

    /// One-shot `llama_backend_init`. Swift's `static let` is thread-safe
    /// and runs its initializer exactly once; `_ = backendOnce` is a cheap
    /// re-read after the first call. Avoids the previous `static var` flag
    /// that tripped Swift 6 strict concurrency.
    private static let backendOnce: Void = {
        llama_backend_init()
    }()

    init() {}

    static func ensureBackend() {
        _ = backendOnce
    }

    /// Explicit teardown. Call from AppDelegate.applicationWillTerminate so
    /// resources are released even though Swift does not guarantee deinit
    /// runs on process exit.
    func shutdown() {
        cancelFlag.set()
        if let oneShotSampler { llama_sampler_free(oneShotSampler); self.oneShotSampler = nil }
        if let oneShotCtx { llama_free(oneShotCtx); self.oneShotCtx = nil }
        if let sampler { llama_sampler_free(sampler); self.sampler = nil }
        if let ctx { llama_free(ctx); self.ctx = nil }
        if let model { llama_model_free(model); self.model = nil }
        vocab = nil
        messages.removeAll()
        prevFormattedLen = 0
        modelPath = nil
        chatTemplate = nil
        isGenerating = false
    }

    // No deinit: Swift 6 strict concurrency can't access actor-isolated
    // non-Sendable C pointers from a nonisolated deinit, and the app
    // already frees these via `shutdown()` in `AppDelegate.applicationWillTerminate`.
    // The runner is held by `ChatViewModel` for the app's lifetime, so the
    // actor is never deallocated at runtime; explicit shutdown is the only
    // cleanup path that matters.

    var loadedModelPath: String? { modelPath }

    /// Report current prompt token count vs configured context size.
    ///
    /// Two paths:
    ///
    /// 1. **Live (KV-cache) path** — fast, O(1) read of
    ///    `llama_memory_seq_pos_max(mem, 0) + 1`. Reflects every token
    ///    currently in the context window, including ones being
    ///    streamed mid-generation. Used during streaming so the
    ///    header's context-percentage indicator updates in real time.
    ///
    /// 2. **Tokenize-template path** — re-renders the chat template
    ///    and tokenizes it. Slower, used when the KV cache is empty
    ///    (just-loaded model, freshly cleared) so the count reflects
    ///    what the next decode will actually feed.
    ///
    /// Both paths return the same `total` from `llama_n_ctx`.
    func tokenUsage() -> TokenUsage? {
        guard let ctx, let vocab else { return nil }
        let total = Int(llama_n_ctx(ctx))

        // Live path. `seq_pos_max` returns the highest position
        // index present in the KV cache for sequence 0, or -1 when
        // empty. Adding 1 turns it into a count.
        if let mem = llama_get_memory(ctx) {
            let last = llama_memory_seq_pos_max(mem, 0)
            if last >= 0 {
                return TokenUsage(used: Int(last) + 1, total: total)
            }
        }

        // Fallback for the empty-KV case: tokenize the rendered
        // template so we report what *would* be in context after the
        // next decode (instead of bare 0 when there's e.g. a system
        // prompt waiting to be sent).
        guard !messages.isEmpty else { return TokenUsage(used: 0, total: total) }
        guard let rendered = try? renderTemplate(addAssistant: false) else {
            return TokenUsage(used: 0, total: total)
        }
        guard let tokens = try? Self.tokenize(vocab: vocab, text: rendered, addSpecial: false) else {
            return TokenUsage(used: 0, total: total)
        }
        return TokenUsage(used: tokens.count, total: total)
    }

    func requestStop() {
        cancelFlag.set()
    }

    func load(
        path: String,
        nCtx: UInt32 = 4096,
        nGpuLayers: Int32 = 999,
        systemPrompt: String? = nil,
        temperature: Float = 0.8,
        topP: Float = 0.95,
        topK: Int32 = 40,
        seed: UInt64? = nil
    ) throws {
        self.systemPrompt = systemPrompt?.isEmpty == true ? nil : systemPrompt
        self.samplerTemperature = temperature
        self.samplerTopP = topP
        self.samplerTopK = topK
        self.samplerSeed = seed.map { UInt32(truncatingIfNeeded: $0) } ?? UInt32(LLAMA_DEFAULT_SEED)
        Self.ensureBackend()

        // Tear down any prior state.
        if let oneShotSampler { llama_sampler_free(oneShotSampler); self.oneShotSampler = nil }
        if let oneShotCtx { llama_free(oneShotCtx); self.oneShotCtx = nil }
        if let sampler { llama_sampler_free(sampler); self.sampler = nil }
        if let ctx { llama_free(ctx); self.ctx = nil }
        if let model { llama_model_free(model); self.model = nil }
        vocab = nil
        messages.removeAll()
        prevFormattedLen = 0
        chatTemplate = nil

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = nGpuLayers

        guard let m = llama_model_load_from_file(path, mparams) else {
            throw LlamaError.modelLoadFailed(path)
        }
        self.model = m
        self.vocab = llama_model_get_vocab(m)

        var cparams = llama_context_default_params()
        cparams.n_ctx = nCtx
        // Raised from 512 so prefill batches for longer histories (esp.
        // after KV compaction, which re-submits the whole visible
        // transcript) fit without needing many chunks. `setHistory`
        // still chunks defensively in case a single turn exceeds this.
        cparams.n_batch = 2048

        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m); self.model = nil; self.vocab = nil
            throw LlamaError.contextCreationFailed
        }
        self.ctx = c

        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else {
            llama_free(c); self.ctx = nil
            llama_model_free(m); self.model = nil; self.vocab = nil
            throw LlamaError.contextCreationFailed
        }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(samplerTopK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(samplerTopP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(samplerTemperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(samplerSeed))
        self.sampler = chain

        // Grab the model's chat template (may be NULL for base models).
        if let cstr = llama_model_chat_template(m, nil) {
            self.chatTemplate = String(cString: cstr)
        } else {
            self.chatTemplate = nil
        }

        // Probe for `<think>` / `</think>` as single special tokens.
        // Reasoning models (Qwen-3, DeepSeek-R1, …) have these in their
        // vocab; non-reasoning models tokenize them as multiple regular
        // tokens, in which case the lookups return nil and the filter
        // falls back to its string-match path.
        self.thinkOpenTokenId = Self.detectSpecialToken(
            vocab: self.vocab, text: "<think>"
        )
        self.thinkCloseTokenId = Self.detectSpecialToken(
            vocab: self.vocab, text: "</think>"
        )

        self.modelPath = path

        if let sp = self.systemPrompt {
            messages.append((role: "system", content: sp))
        }
    }

    /// Best-effort classification of the currently-loaded model's chat
    /// template into a `TemplateFamily`. Returns nil before a model is
    /// loaded, when the GGUF didn't ship a template, or when no
    /// heuristic in `TemplateFamily.fingerprint` matched. Used by the
    /// agent layer to gate tool-using agents on a compatible template.
    func detectedTemplateFamily() -> TemplateFamily? {
        TemplateFamily.fingerprint(template: chatTemplate)
    }

    /// Rebuild the sampler chain with new parameters. Preserves conversation state.
    func updateSampling(temperature: Float, topP: Float, topK: Int32, seed: UInt64? = nil) {
        self.samplerTemperature = temperature
        self.samplerTopP = topP
        self.samplerTopK = topK
        self.samplerSeed = seed.map { UInt32(truncatingIfNeeded: $0) } ?? UInt32(LLAMA_DEFAULT_SEED)
        guard model != nil, ctx != nil else { return }
        if let old = sampler { llama_sampler_free(old); self.sampler = nil }
        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else { return }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(samplerSeed))
        self.sampler = chain
    }

    /// Update the system prompt. Triggers a conversation reset.
    func setSystemPrompt(_ sp: String?) {
        let normalized = (sp?.isEmpty == true) ? nil : sp
        self.systemPrompt = normalized
        resetConversation()
    }

    /// Replace the conversation with `history` and pre-fill the KV cache so
    /// the next `sendUserMessage` sees the restored context. The system
    /// prompt (if configured) is prepended automatically — pass only
    /// user/assistant turns. Throws on tokenize/decode failure; partial
    /// state is rolled back to an empty conversation.
    ///
    /// Cost: one prompt-sized decode (equivalent to the first turn of a
    /// long chat).
    func setHistory(_ history: [(role: String, content: String)]) throws {
        guard let ctx, let vocab else { throw LlamaError.backendNotReady }

        llama_memory_clear(llama_get_memory(ctx), true)
        messages.removeAll()
        if let sp = systemPrompt {
            messages.append((role: "system", content: sp))
        }
        messages.append(contentsOf: history)
        prevFormattedLen = 0

        // Nothing to pre-fill when there are no user/assistant turns.
        guard !history.isEmpty else { return }

        let rendered: String
        do {
            rendered = try renderTemplate(addAssistant: false)
        } catch {
            resetConversation()
            throw error
        }
        var tokens: [llama_token]
        do {
            tokens = try Self.tokenize(vocab: vocab, text: rendered, addSpecial: false)
        } catch {
            resetConversation()
            throw error
        }
        guard !tokens.isEmpty else { return }

        // Chunk the prefill into `n_batch`-sized pieces. llama.cpp aborts
        // (ggml_abort) inside `llama_decode` if a single `llama_batch_get_one`
        // exceeds the context's configured batch size. Long histories —
        // especially after KV compaction re-submits the whole visible
        // transcript — blow past that cap in one shot, so we feed the
        // tokens in sequentially and let llama advance its own position.
        let nBatch = Swift.max(1, Int(llama_n_batch(ctx)))
        let total = tokens.count
        let rc: Int32 = tokens.withUnsafeMutableBufferPointer { buf -> Int32 in
            guard let base = buf.baseAddress else { return 0 }
            var offset = 0
            while offset < total {
                let chunk = Swift.min(nBatch, total - offset)
                let batch = llama_batch_get_one(base.advanced(by: offset), Int32(chunk))
                let r = llama_decode(ctx, batch)
                if r != 0 { return r }
                offset += chunk
            }
            return 0
        }
        if rc != 0 {
            resetConversation()
            throw LlamaError.decodeFailed(rc)
        }
        prevFormattedLen = ChatPromptDelta.byteLength(of: rendered)
    }

    /// Drop the most recent user+assistant turn pair and clear the KV cache.
    /// The next `sendUserMessage` re-renders the full template from scratch
    /// and pre-fills in one batch. Intended for regenerate / edit-and-resend.
    /// No-op if the last two messages aren't a user→assistant pair.
    func rewindLastTurn() {
        guard messages.count >= 2,
              messages[messages.count - 1].role == "assistant",
              messages[messages.count - 2].role == "user"
        else { return }
        messages.removeLast(2)
        if let ctx {
            llama_memory_clear(llama_get_memory(ctx), true)
        }
        prevFormattedLen = 0
    }

    func resetConversation() {
        if let ctx {
            let mem = llama_get_memory(ctx)
            llama_memory_clear(mem, true)
        }
        messages.removeAll()
        prevFormattedLen = 0
        if let sp = systemPrompt {
            messages.append((role: "system", content: sp))
        }
    }

    /// Send a user message and stream the assistant response as decoded text.
    func sendUserMessage(_ text: String, maxTokens: Int = 512) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard !isGenerating else {
                continuation.finish(throwing: LlamaError.busy)
                return
            }
            guard let ctx = self.ctx,
                  let sampler = self.sampler,
                  let vocab = self.vocab
            else {
                continuation.finish(throwing: LlamaError.backendNotReady)
                return
            }

            // Append the new user turn and render the full chat.
            messages.append((role: "user", content: text))
            let fullWithAss: String
            do {
                fullWithAss = try renderTemplate(addAssistant: true)
            } catch {
                messages.removeLast()
                continuation.finish(throwing: error)
                return
            }

            // Delta is the portion of the formatted prompt the model has not
            // yet seen. First turn: whole render. Later turns: substring after
            // the previously-committed formatted length.
            let promptDelta = ChatPromptDelta.delta(
                fullRendered: fullWithAss,
                previousByteLength: prevFormattedLen
            )

            cancelFlag.reset()
            isGenerating = true
            let flag = cancelFlag
            let handles = LlamaHandles(ctx: ctx, sampler: sampler, vocab: vocab)
            let openId = self.thinkOpenTokenId
            let closeId = self.thinkCloseTokenId

            Task.detached {
                var assistant = ""
                var thrown: Error? = nil
                do {
                    try Self.runDecodeLoop(
                        ctx: handles.ctx, sampler: handles.sampler, vocab: handles.vocab,
                        prompt: promptDelta, maxTokens: maxTokens,
                        cancel: flag,
                        thinkOpenTokenId: openId,
                        thinkCloseTokenId: closeId
                    ) { piece in
                        continuation.yield(piece)
                        assistant += piece
                    }
                } catch {
                    thrown = error
                }
                await self.finishGeneration(assistantText: assistant, error: thrown)
                if let e = thrown {
                    continuation.finish(throwing: e)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    /// Append a tool-result message to the transcript and decode the
    /// follow-up assistant turn. Intended for one-step tool loops: the
    /// caller feeds a tool output back to the model and receives the
    /// final-answer stream.
    ///
    /// `family` selects the role name written into the message — Jinja
    /// template rendering then wraps it correctly. llama.cpp's
    /// `llama_chat_apply_template` honours whatever role the template
    /// recognises; different model families use different conventions:
    /// - `.llama3` / `.openai`: `ipython` (Llama 3.1's tool-result role).
    /// - `.qwen` / `.hermes`: `tool` (the role both ChatML-derived
    ///   tool-calling templates expect).
    /// Passing the wrong role lets the template fall through to a
    /// literal role-name marker the model doesn't recognise, and the
    /// follow-up answer hallucinates from there.
    ///
    /// Expects the previous `sendUserMessage` to have completed (the
    /// assistant turn containing the model's tool call must already be
    /// committed in `messages`). Cancellation during the previous
    /// decode still counts — `finishGeneration` commits partial output.
    func appendToolResultAndContinue(
        toolResult: String,
        family: TemplateFamily = .llama3,
        maxTokens: Int = 512
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard !isGenerating else {
                continuation.finish(throwing: LlamaError.busy)
                return
            }
            guard let ctx = self.ctx,
                  let sampler = self.sampler,
                  let vocab = self.vocab
            else {
                continuation.finish(throwing: LlamaError.backendNotReady)
                return
            }

            let role: String
            switch family {
            case .llama3, .openai: role = "ipython"
            case .qwen, .hermes:   role = "tool"
            }
            messages.append((role: role, content: toolResult))
            let fullWithAss: String
            do {
                fullWithAss = try renderTemplate(addAssistant: true)
            } catch {
                messages.removeLast()
                continuation.finish(throwing: error)
                return
            }

            let promptDelta = ChatPromptDelta.delta(
                fullRendered: fullWithAss,
                previousByteLength: prevFormattedLen
            )

            cancelFlag.reset()
            isGenerating = true
            let flag = cancelFlag
            let handles = LlamaHandles(ctx: ctx, sampler: sampler, vocab: vocab)
            let openId = self.thinkOpenTokenId
            let closeId = self.thinkCloseTokenId

            Task.detached {
                var assistant = ""
                var thrown: Error? = nil
                do {
                    try Self.runDecodeLoop(
                        ctx: handles.ctx, sampler: handles.sampler, vocab: handles.vocab,
                        prompt: promptDelta, maxTokens: maxTokens,
                        cancel: flag,
                        thinkOpenTokenId: openId,
                        thinkCloseTokenId: closeId
                    ) { piece in
                        continuation.yield(piece)
                        assistant += piece
                    }
                } catch {
                    thrown = error
                }
                await self.finishGeneration(assistantText: assistant, error: thrown)
                if let e = thrown {
                    continuation.finish(throwing: e)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    /// Actor-isolated finalization: commit assistant turn and refresh
    /// prev-formatted-length using a render without the assistant tag.
    private func finishGeneration(assistantText: String, error: Error?) {
        isGenerating = false
        // Only commit if we produced something. On cancel/error we still keep
        // what was produced so the user can see partial output.
        if !assistantText.isEmpty {
            messages.append((role: "assistant", content: assistantText))
            if let rendered = try? renderTemplate(addAssistant: false) {
                prevFormattedLen = ChatPromptDelta.byteLength(of: rendered)
            }
        } else if error != nil {
            // Roll back the user message if we failed without producing anything.
            if let last = messages.last, last.role == "user" {
                messages.removeLast()
            }
        }
    }

    // MARK: - Template rendering

    private func renderTemplate(addAssistant: Bool) throws -> String {
        try Self.renderTemplate(
            template: chatTemplate,
            messages: messages,
            addAssistant: addAssistant
        )
    }

    /// Render a list of messages through the model's chat template.
    /// Static so it can be called from one-shot paths (which don't
    /// have access to the actor's `messages` / `chatTemplate` state)
    /// or from tests. A nil `template` falls back to llama.cpp's
    /// built-in default template.
    static func renderTemplate(
        template: String?,
        messages: [(role: String, content: String)],
        addAssistant: Bool
    ) throws -> String {
        let msgCount = messages.count
        let totalChars = messages.reduce(0) { $0 + $1.content.count + $1.role.count }

        // Keep the C string backing storage alive for the duration of the call.
        let roleBufs: [ContiguousArray<CChar>] = messages.map { ContiguousArray($0.role.utf8CString) }
        let contentBufs: [ContiguousArray<CChar>] = messages.map { ContiguousArray($0.content.utf8CString) }

        var cMessages: [llama_chat_message] = []
        cMessages.reserveCapacity(msgCount)
        for i in 0..<msgCount {
            let rolePtr = roleBufs[i].withUnsafeBufferPointer { $0.baseAddress }
            let contentPtr = contentBufs[i].withUnsafeBufferPointer { $0.baseAddress }
            cMessages.append(llama_chat_message(role: rolePtr, content: contentPtr))
        }

        let tmplCString: [CChar]? = template.map { Array($0.utf8CString) }
        var bufSize = max(1024, totalChars * 4)
        var buf = [CChar](repeating: 0, count: bufSize)

        func callTemplate(_ tmplPtr: UnsafePointer<CChar>?) -> Int32 {
            cMessages.withUnsafeBufferPointer { msgBuf in
                llama_chat_apply_template(
                    tmplPtr,
                    msgBuf.baseAddress,
                    msgCount,
                    addAssistant,
                    &buf,
                    Int32(bufSize)
                )
            }
        }

        var n: Int32
        if let t = tmplCString {
            n = t.withUnsafeBufferPointer { callTemplate($0.baseAddress) }
        } else {
            n = callTemplate(nil)
        }

        if n > Int32(bufSize) {
            bufSize = Int(n) + 1
            buf = [CChar](repeating: 0, count: bufSize)
            if let t = tmplCString {
                n = t.withUnsafeBufferPointer { callTemplate($0.baseAddress) }
            } else {
                n = callTemplate(nil)
            }
        }
        if n < 0 { throw LlamaError.templateFailed }
        return Self.decodeCChars(buf, length: Int(n))
    }

    // MARK: - One-shot generation (isolated from main conversation)

    /// Secondary context for side-channel generation (HyDE, future
    /// title generation, summarization, etc.). Shares the model
    /// handle with the main context but has its own KV cache, so
    /// one-shot calls don't corrupt conversation state. Lazy-init on
    /// first use to avoid the allocation cost when the feature isn't
    /// in use. Low-temperature sampler — we want deterministic,
    /// focused output for these auxiliary queries, not creativity.
    private var oneShotCtx: OpaquePointer? = nil
    private var oneShotSampler: UnsafeMutablePointer<llama_sampler>? = nil

    /// Run a single isolated generation that doesn't append to the
    /// main conversation. Renders `prompt` as a standalone user turn
    /// via the model's chat template, decodes via a secondary
    /// context, returns the full generated text. Caller-controlled
    /// `maxTokens` ceiling (default 256 — enough for a HyDE
    /// hypothetical, short of a typical chat reply).
    ///
    /// Concurrency: serialized on the actor like everything else;
    /// safe to call while another `sendUserMessage` is streaming on
    /// the main context, because the two contexts are independent.
    /// Throws `busy` if another generation (main or one-shot) is
    /// already active on this actor.
    func generateOneShot(
        prompt: String,
        maxTokens: Int = 256
    ) async throws -> String {
        guard !isGenerating else { throw LlamaError.busy }
        guard let model = self.model, let vocab = self.vocab else {
            throw LlamaError.backendNotReady
        }
        try ensureOneShotContext(model: model)
        guard let ctx = oneShotCtx, let sampler = oneShotSampler else {
            throw LlamaError.backendNotReady
        }

        // Clear the secondary KV cache between calls so successive
        // one-shots don't accumulate state. Each call is independent.
        if let mem = llama_get_memory(ctx) {
            llama_memory_clear(mem, true)
        }

        // Render just this single user turn through the chat template.
        // System prompt is intentionally omitted — HyDE doesn't benefit
        // from the main conversation's persona, and callers can bake
        // any context they want into `prompt`.
        let rendered = try Self.renderTemplate(
            template: chatTemplate,
            messages: [(role: "user", content: prompt)],
            addAssistant: true
        )

        isGenerating = true
        defer { isGenerating = false }

        var collected = ""
        // Flag stays unused here — one-shot isn't cancellable by the
        // user (it's a background pipeline step, not a visible
        // generation). Pass a fresh flag so `runDecodeLoop`'s cancel
        // check never fires.
        let flag = CancelFlag()
        try Self.runDecodeLoop(
            ctx: ctx, sampler: sampler, vocab: vocab,
            prompt: rendered, maxTokens: maxTokens,
            cancel: flag,
            thinkOpenTokenId: thinkOpenTokenId,
            thinkCloseTokenId: thinkCloseTokenId
        ) { piece in
            collected += piece
        }
        return collected
    }

    private func ensureOneShotContext(model: OpaquePointer) throws {
        if oneShotCtx != nil, oneShotSampler != nil { return }

        // 2048-token context is enough for a HyDE query (<100 tokens)
        // plus a short hypothetical (<500). Smaller than the main
        // context's default 4096 so memory cost stays modest.
        var cparams = llama_context_default_params()
        cparams.n_ctx = 2048
        cparams.n_batch = 512
        cparams.n_ubatch = 512

        guard let c = llama_init_from_model(model, cparams) else {
            throw LlamaError.contextCreationFailed
        }

        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else {
            llama_free(c)
            throw LlamaError.contextCreationFailed
        }
        // Low-temperature sampler — HyDE hypothetical should be
        // specific and grounded, not creative. No need for top-k /
        // top-p theatrics.
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.3))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32(LLAMA_DEFAULT_SEED)))

        self.oneShotCtx = c
        self.oneShotSampler = chain
    }

    // MARK: - Decode loop (runs off-actor)

    /// Decode a known-length `[CChar]` buffer (not necessarily null-terminated
    /// within the length) to a Swift `String`. Replaces the now-deprecated
    /// `String(cString:)` which required the caller to zero-terminate the
    /// buffer and walked to find the terminator. CChar → UInt8 via
    /// `bitPattern:` since on Apple platforms they share bit layout; MaxASCII
    /// safety is handled by `String(decoding:as:)`'s UTF-8 replacement of
    /// invalid sequences.
    private static func decodeCChars(_ buf: [CChar], length: Int) -> String {
        String(decoding: buf.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func tokenize(vocab: OpaquePointer, text: String, addSpecial: Bool) throws -> [llama_token] {
        let cstr = Array(text.utf8CString)
        let textLen = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: max(32, Int(textLen) + 8))
        var n = llama_tokenize(vocab, cstr, textLen, &tokens, Int32(tokens.count), addSpecial, true)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, cstr, textLen, &tokens, Int32(tokens.count), addSpecial, true)
            if n < 0 { throw LlamaError.tokenizationFailed }
        }
        return Array(tokens.prefix(Int(n)))
    }

    /// Raw bytes for a single token. Replaces the older `piece` helper that
    /// eagerly converted to `String` per token — that broke multi-byte UTF-8
    /// sequences (notably emojis) when a 4-byte sequence straddled a token
    /// boundary, surfacing as `��` replacement-char pairs in the rendered
    /// reply. The streaming layer now buffers these bytes across tokens
    /// (`runDecodeLoop`) and only emits a `String` at a valid UTF-8 boundary.
    private static func pieceBytes(vocab: OpaquePointer, token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n) + 1)
            let n2 = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            if n2 <= 0 { return [] }
            return buf.prefix(Int(n2)).map { UInt8(bitPattern: $0) }
        }
        if n == 0 { return [] }
        return buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
    }

    /// Return the longest prefix length of `bytes` that ends on a complete
    /// UTF-8 sequence. Walks back at most 4 bytes (the longest valid
    /// sequence) looking for the most recent lead byte; if its expected
    /// continuation count exceeds what's actually present, the lead and
    /// everything after it are held back for the next token. Pathological
    /// input (4 continuation bytes with no preceding lead — would never
    /// come from a well-formed tokenizer) flushes as-is rather than
    /// accumulating forever.
    private static func safeUTF8Boundary(_ bytes: [UInt8]) -> Int {
        let n = bytes.count
        guard n > 0 else { return 0 }
        let earliest = max(0, n - 4)
        var i = n - 1
        while i >= earliest {
            let b = bytes[i]
            if b < 0x80 {
                // ASCII byte. Anything between i+1 and n-1 would be a
                // dangling continuation (no lead) — invalid; emit as-is so
                // the buffer doesn't accumulate. Normal tokenizer output
                // never produces this shape.
                return n
            }
            if b >= 0xC0 {
                let expected: Int
                if b >= 0xF0 { expected = 4 }
                else if b >= 0xE0 { expected = 3 }
                else { expected = 2 }
                let trailing = n - i  // bytes from this lead through end
                return trailing >= expected ? n : i
            }
            i -= 1  // continuation byte; keep walking back
        }
        // Walked back 4 bytes without finding a lead — flush rather than
        // hold (would only happen on malformed input).
        return n
    }

    private static func runDecodeLoop(
        ctx: OpaquePointer,
        sampler: UnsafeMutablePointer<llama_sampler>,
        vocab: OpaquePointer,
        prompt: String,
        maxTokens: Int,
        cancel: CancelFlag,
        thinkOpenTokenId: llama_token? = nil,
        thinkCloseTokenId: llama_token? = nil,
        onPiece: (String) -> Void
    ) throws {
        // Tokenize and submit the prompt delta.
        // `addSpecial` is false: llama_chat_apply_template already inserts BOS/
        // control tokens when appropriate.
        var tokens = try tokenize(vocab: vocab, text: prompt, addSpecial: false)
        guard !tokens.isEmpty else { return }

        try tokens.withUnsafeMutableBufferPointer { buf in
            let batch = llama_batch_get_one(buf.baseAddress, Int32(buf.count))
            let rc = llama_decode(ctx, batch)
            if rc != 0 { throw LlamaError.decodeFailed(rc) }
        }

        // UTF-8 byte buffer: holds the tail of a multi-byte sequence
        // straddling a token boundary so we never emit a partial sequence
        // (which would surface as `��` replacement chars in the reply).
        // Flushed at end-of-loop and on EOG.
        var pending: [UInt8] = []

        var produced = 0
        while produced < maxTokens {
            if cancel.isSet { throw LlamaError.cancelled }

            let next = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, next) { break }
            llama_sampler_accept(sampler, next)

            // Think-tag detection by token ID. When the model samples the
            // special `<think>` / `</think>` token (different IDs from the
            // BPE-decomposed string forms), emit a Private-Use Area
            // sentinel into the stream — `ThinkBlockStreamFilter` switches
            // to authoritative-mode on first sentinel and stops trusting
            // surface-form `</think>` strings inside the model's prose.
            let isThinkOpen = thinkOpenTokenId.map { $0 == next } ?? false
            let isThinkClose = thinkCloseTokenId.map { $0 == next } ?? false
            if isThinkOpen || isThinkClose {
                // Drain whatever UTF-8 bytes are buffered before the
                // sentinel — special tokens are atomic at the BPE level
                // so `pending` should normally be empty here, but a model
                // emitting a multi-byte sequence right before sampling the
                // special token would otherwise leave its bytes stranded.
                if !pending.isEmpty {
                    let str = String(decoding: pending, as: UTF8.self)
                    pending.removeAll()
                    if !str.isEmpty { onPiece(str) }
                }
                onPiece(isThinkOpen
                    ? ThinkBlockStreamFilter.openSentinel
                    : ThinkBlockStreamFilter.closeSentinel)
            } else {
                let bytes = pieceBytes(vocab: vocab, token: next)
                if !bytes.isEmpty {
                    pending.append(contentsOf: bytes)
                    let safe = safeUTF8Boundary(pending)
                    if safe > 0 {
                        let chunk = pending.prefix(safe)
                        let str = String(decoding: chunk, as: UTF8.self)
                        pending.removeFirst(safe)
                        if !str.isEmpty { onPiece(str) }
                    }
                }
            }

            var one = [next]
            let rc = one.withUnsafeMutableBufferPointer { buf -> Int32 in
                let batch = llama_batch_get_one(buf.baseAddress, 1)
                return llama_decode(ctx, batch)
            }
            if rc != 0 { throw LlamaError.decodeFailed(rc) }
            produced += 1
        }

        // Flush any trailing bytes. If we exited cleanly (EOG / max-tokens),
        // a non-empty `pending` means the model genuinely stopped mid-
        // sequence — exceptionally rare; render with replacement chars
        // rather than swallow.
        if !pending.isEmpty {
            let str = String(decoding: pending, as: UTF8.self)
            if !str.isEmpty { onPiece(str) }
        }
    }

    /// Tokenize `text` against the vocab with `parse_special=true`. If the
    /// model has it as a single special token (Qwen-3 / DeepSeek-R1's
    /// `<think>` / `</think>`, for example), returns that token ID.
    /// Returns nil for base / non-reasoning models where the string
    /// decomposes into multiple regular tokens.
    private static func detectSpecialToken(
        vocab: OpaquePointer?,
        text: String
    ) -> llama_token? {
        guard let vocab else { return nil }
        guard let tokens = try? tokenize(vocab: vocab, text: text, addSpecial: false) else {
            return nil
        }
        return tokens.count == 1 ? tokens[0] : nil
    }
}
