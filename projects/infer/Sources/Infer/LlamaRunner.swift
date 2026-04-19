import Foundation
import llama

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

/// Thread-safe cancellation flag usable from any isolation context.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
    func reset() { lock.lock(); flag = false; lock.unlock() }
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
    private var messages: [(role: String, content: String)] = []
    /// Length (in bytes) of the last template render with `add_ass=false`.
    /// Used to compute the prompt delta for each new turn.
    private var prevFormattedLen: Int = 0
    private var isGenerating: Bool = false

    private let cancelFlag = CancelFlag()

    private static var backendInitialized = false

    init() {}

    static func ensureBackend() {
        guard !backendInitialized else { return }
        llama_backend_init()
        backendInitialized = true
    }

    /// Explicit teardown. Call from AppDelegate.applicationWillTerminate so
    /// resources are released even though Swift does not guarantee deinit
    /// runs on process exit.
    func shutdown() {
        cancelFlag.set()
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

    deinit {
        if let sampler { llama_sampler_free(sampler) }
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
    }

    var loadedModelPath: String? { modelPath }

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
        topK: Int32 = 40
    ) throws {
        self.systemPrompt = systemPrompt?.isEmpty == true ? nil : systemPrompt
        self.samplerTemperature = temperature
        self.samplerTopP = topP
        self.samplerTopK = topK
        Self.ensureBackend()

        // Tear down any prior state.
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
        cparams.n_batch = 512

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
        llama_sampler_chain_add(chain, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
        self.sampler = chain

        // Grab the model's chat template (may be NULL for base models).
        if let cstr = llama_model_chat_template(m, nil) {
            self.chatTemplate = String(cString: cstr)
        } else {
            self.chatTemplate = nil
        }

        self.modelPath = path

        if let sp = self.systemPrompt {
            messages.append((role: "system", content: sp))
        }
    }

    /// Rebuild the sampler chain with new parameters. Preserves conversation state.
    func updateSampling(temperature: Float, topP: Float, topK: Int32) {
        self.samplerTemperature = temperature
        self.samplerTopP = topP
        self.samplerTopK = topK
        guard model != nil, ctx != nil else { return }
        if let old = sampler { llama_sampler_free(old); self.sampler = nil }
        let sparams = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(sparams) else { return }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(topP, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
        self.sampler = chain
    }

    /// Update the system prompt. Triggers a conversation reset.
    func setSystemPrompt(_ sp: String?) {
        let normalized = (sp?.isEmpty == true) ? nil : sp
        self.systemPrompt = normalized
        resetConversation()
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
            let promptDelta: String
            if prevFormattedLen == 0 {
                promptDelta = fullWithAss
            } else {
                let utf8 = Array(fullWithAss.utf8)
                let start = min(prevFormattedLen, utf8.count)
                promptDelta = String(decoding: utf8[start...], as: UTF8.self)
            }

            cancelFlag.reset()
            isGenerating = true
            let flag = cancelFlag

            Task.detached {
                var assistant = ""
                var thrown: Error? = nil
                do {
                    try Self.runDecodeLoop(
                        ctx: ctx, sampler: sampler, vocab: vocab,
                        prompt: promptDelta, maxTokens: maxTokens,
                        cancel: flag
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
                prevFormattedLen = rendered.utf8.count
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
        let msgCount = messages.count
        let totalChars = messages.reduce(0) { $0 + $1.content.count + $1.role.count }
        let tmpl = chatTemplate

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

        let tmplCString: [CChar]? = tmpl.map { Array($0.utf8CString) }
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
        buf[Int(n)] = 0
        return String(cString: buf)
    }

    // MARK: - Decode loop (runs off-actor)

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

    private static func piece(vocab: OpaquePointer, token: llama_token) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n) + 1)
            let n2 = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            if n2 <= 0 { return "" }
            buf[Int(n2)] = 0
            return String(cString: buf)
        }
        if n == 0 { return "" }
        buf[Int(n)] = 0
        return String(cString: buf)
    }

    private static func runDecodeLoop(
        ctx: OpaquePointer,
        sampler: UnsafeMutablePointer<llama_sampler>,
        vocab: OpaquePointer,
        prompt: String,
        maxTokens: Int,
        cancel: CancelFlag,
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

        var produced = 0
        while produced < maxTokens {
            if cancel.isSet { throw LlamaError.cancelled }

            let next = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, next) { break }
            llama_sampler_accept(sampler, next)

            let text = piece(vocab: vocab, token: next)
            if !text.isEmpty { onPiece(text) }

            var one = [next]
            let rc = one.withUnsafeMutableBufferPointer { buf -> Int32 in
                let batch = llama_batch_get_one(buf.baseAddress, 1)
                return llama_decode(ctx, batch)
            }
            if rc != 0 { throw LlamaError.decodeFailed(rc) }
            produced += 1
        }
    }
}
