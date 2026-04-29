import Foundation
import StableDiffusion
import ImageIO
import UniformTypeIdentifiers

public enum StableDiffusionError: Error, LocalizedError {
    case backendNotReady
    case modelMissing(path: String)
    case loadFailed
    case busy
    case generateFailed
    case encodeFailed

    public var errorDescription: String? {
        switch self {
        case .backendNotReady: return "Stable Diffusion not loaded"
        case .modelMissing(let p): return "Model not found at \(p)"
        case .loadFailed: return "Stable Diffusion failed to initialise"
        case .busy: return "Generation already in flight"
        case .generateFailed: return "Stable Diffusion generation failed"
        case .encodeFailed: return "Failed to encode generated image"
        }
    }
}

/// Single Progress event surfaced to the VM. Streamed from `generate(...)`
/// so the UI can render a step counter, an ETA, and finally the saved image.
public enum SDProgress: Sendable {
    /// Mid-flight step count from the sd-cpp callback. `secsPerStep` is the
    /// callback's reported wall time for this step (sd-cpp computes it
    /// internally). The UI can derive ETA = (total - current) * secsPerStep.
    case step(current: Int, total: Int, secsPerStep: Double)
    /// Generation completed; the PNG and sidecar JSON were written to
    /// `imageURL`'s directory. The image is loadable via `NSImage(contentsOf:)`.
    case done(imageURL: URL)
}

/// Bind an optional Swift `String?` to a `const char *` for the duration
/// of `body`. Passes `nil` when the input is nil or empty so sd-cpp's
/// param-init defaults (NULL) take over for unset fields. Used to nest
/// per-field bindings around `new_sd_ctx` without temporarily allocating
/// a sentinel buffer for the empty case.
private func withOptionalCString<R>(
    _ s: String?,
    _ body: (UnsafePointer<CChar>?) -> R
) -> R {
    guard let s, !s.isEmpty else { return body(nil) }
    return s.withCString { body($0) }
}

/// `OpaquePointer` (`sd_ctx_t*`) doesn't conform to `Sendable` under
/// Swift 6 strict concurrency, but we know it's safe to hand to a
/// detached generation task because the actor serialises access via
/// `isGenerating`. Wrap in a `@unchecked Sendable` box for capture.
private struct SDCtxBox: @unchecked Sendable {
    let ctx: OpaquePointer
}

/// Progress + cancellation bridge. sd-cpp's progress callback is C —
/// `(int step, int steps, float time, void* data)` with `data` a void
/// pointer set at callback registration. We pass a pointer to one of these
/// boxes via `Unmanaged` and unwrap it on the C side. Reference-typed
/// because the box outlives the synchronous generate_image call but its
/// fields are owned exclusively by the actor task that registered it.
private final class SDCallbackBridge: @unchecked Sendable {
    let onStep: @Sendable (Int, Int, Double) -> Void
    init(onStep: @escaping @Sendable (Int, Int, Double) -> Void) {
        self.onStep = onStep
    }
}

/// Stable Diffusion runner. Wraps `sd_ctx_t*` from the StableDiffusion
/// xcframework. Mirrors the actor pattern of `LlamaRunner` / `MLXRunner` —
/// `load(...)` is one-shot per model, `generate(...)` returns a stream of
/// `SDProgress` events terminating in `.done(imageURL:)`.
///
/// Important sd-cpp specifics:
/// - Progress / log callbacks are **global**, not per-context. We set them
///   each time `generate` runs so the bridge box matches the active task.
/// - There is no in-flight cancel API. `requestStop()` is a soft signal that
///   takes effect only between user-initiated generations; an already-running
///   `generate_image` runs to completion. Documented limitation of sd-cpp.
/// - Decode quality / speed depends on `flash_attn`, `vae_tiling`, and the
///   weight type the model was quantised to. Defaults below mirror what
///   leejet's CLI uses.
public actor StableDiffusionRunner {
    private var ctx: OpaquePointer?
    private var loadedModelPath: String?
    private var isLoading = false
    private var isGenerating = false
    /// Soft cancel: the in-flight `generate_image` doesn't see this, but
    /// the actor checks it before launching a follow-on call.
    private var cancelRequested = false

    public init() {}

    public var loadedModel: String? { loadedModelPath }
    public var loaded: Bool { ctx != nil }
    public var generating: Bool { isGenerating }

    /// Initialise an `sd_ctx_t` from one or more local model files.
    ///
    /// SD ships in two layouts:
    /// - **Single-file**: a checkpoint that bundles diffusion model + VAE +
    ///   text encoder (SD 1.x/2.x, SDXL, Flux fp8 all-in-one). Pass
    ///   `modelPath` and leave the rest nil.
    /// - **Multi-file**: separate diffusion + VAE + text encoder(s)
    ///   (Z-Image, Flux multi-file). Pass `diffusionModelPath` and
    ///   whichever ancillary paths the model needs:
    ///     - Z-Image:  `vaePath`, `llmPath`
    ///     - Flux:     `vaePath`, `clipLPath`, `t5xxlPath`
    ///
    /// Long-running (mmaps + reads weights, may take seconds for multi-GB
    /// models). Runs inline on the actor — see comment below for why.
    public func load(
        modelPath: String? = nil,
        diffusionModelPath: String? = nil,
        vaePath: String? = nil,
        llmPath: String? = nil,
        t5xxlPath: String? = nil,
        clipLPath: String? = nil,
        offloadParamsToCPU: Bool = false
    ) async throws {
        guard !isLoading else { throw StableDiffusionError.busy }

        // At least one of modelPath / diffusionModelPath must be present.
        let primary = modelPath ?? diffusionModelPath
        guard let primary, !primary.isEmpty else {
            throw StableDiffusionError.modelMissing(path: "(none)")
        }

        // Validate every supplied path. Pre-flighting these means a typo
        // in any one field surfaces a clean error rather than crashing
        // inside new_sd_ctx.
        for path in [modelPath, diffusionModelPath, vaePath, llmPath, t5xxlPath, clipLPath].compactMap({ $0 }) where !path.isEmpty {
            guard FileManager.default.fileExists(atPath: path) else {
                throw StableDiffusionError.modelMissing(path: path)
            }
        }

        // Reload semantics: tear down the existing ctx before swapping. The
        // old ctx's mmap'd weights stay until free_sd_ctx returns.
        if let old = ctx {
            free_sd_ctx(old)
            ctx = nil
            loadedModelPath = nil
        }

        isLoading = true
        defer { isLoading = false }

        // `new_sd_ctx` mmaps weights and may take seconds on multi-GB
        // models. Run inline on the actor — it blocks the actor for the
        // duration, but `load` is invoked once per model on user click;
        // status queries (`loaded`, `loadedModel`) all return promptly
        // before/after. Pushing the pointer through `Task.detached` would
        // require a `@unchecked Sendable` shuttle and isn't worth it
        // when the call is interactive-on-click rather than per-token.
        var params = sd_ctx_params_t()
        sd_ctx_params_init(&params)
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        params.enable_mmap = true
        params.flash_attn = true
        params.diffusion_flash_attn = true
        params.offload_params_to_cpu = offloadParamsToCPU

        // C strings have to outlive the new_sd_ctx call. Nest
        // withCString blocks for each non-nil path; nil paths leave the
        // corresponding field as the zero default (`NULL`-equivalent).
        // Helper that recursively binds the next path.
        let result: OpaquePointer? = withOptionalCString(modelPath) { p1 in
            params.model_path = p1
            return withOptionalCString(diffusionModelPath) { p2 in
                params.diffusion_model_path = p2
                return withOptionalCString(vaePath) { p3 in
                    params.vae_path = p3
                    return withOptionalCString(llmPath) { p4 in
                        params.llm_path = p4
                        return withOptionalCString(t5xxlPath) { p5 in
                            params.t5xxl_path = p5
                            return withOptionalCString(clipLPath) { p6 in
                                params.clip_l_path = p6
                                return new_sd_ctx(&params)
                            }
                        }
                    }
                }
            }
        }

        guard let result else { throw StableDiffusionError.loadFailed }
        self.ctx = result
        // Surface the most specific path: prefer the diffusion model if
        // present (multi-file mode), else the all-in-one checkpoint.
        self.loadedModelPath = diffusionModelPath ?? modelPath
    }

    /// Stream image generation. Yields `.step` per sampler step (driven by
    /// sd-cpp's progress callback) and finally `.done(imageURL:)` when the
    /// PNG is written. Errors terminate the stream.
    ///
    /// Generation runs on a detached Task so the actor stays responsive
    /// (e.g. for `loaded` / `generating` queries from the UI). The actor's
    /// `isGenerating` flag prevents overlapping calls.
    public func generate(
        prompt: String,
        negativePrompt: String,
        width: Int,
        height: Int,
        steps: Int,
        cfgScale: Double,
        seed: Int64,
        sampler: SDSampler,
        outputDirectory: URL
    ) -> AsyncThrowingStream<SDProgress, Error> {
        AsyncThrowingStream { continuation in
            guard let ctx, !isGenerating else {
                continuation.finish(throwing:
                    ctx == nil ? StableDiffusionError.backendNotReady : StableDiffusionError.busy
                )
                return
            }
            isGenerating = true
            cancelRequested = false

            let promptCopy = prompt
            let negCopy = negativePrompt
            let ctxBox = SDCtxBox(ctx: ctx)
            let modelPathSnapshot = loadedModelPath ?? ""
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                let ctx = ctxBox.ctx

                // Bridge for the C progress callback. Captures the
                // continuation so each .step on the C side becomes a
                // `.step` event on the Swift stream.
                let bridge = SDCallbackBridge { step, total, secsPerStep in
                    continuation.yield(.step(
                        current: step,
                        total: total,
                        secsPerStep: secsPerStep
                    ))
                }
                let bridgePtr = Unmanaged.passRetained(bridge).toOpaque()

                // sd-cpp's progress callback is GLOBAL state. We set it
                // for the duration of this call and clear afterwards so a
                // dangling pointer can't fire after the bridge is freed.
                sd_set_progress_callback({ step, total, time, data in
                    guard let data else { return }
                    let bridge = Unmanaged<SDCallbackBridge>.fromOpaque(data).takeUnretainedValue()
                    bridge.onStep(Int(step), Int(total), Double(time))
                }, bridgePtr)

                // Build the gen params. `sd_img_gen_params_init` seeds
                // sane defaults; we override only what the UI exposes.
                var gen = sd_img_gen_params_t()
                sd_img_gen_params_init(&gen)
                var sampleParams = sd_sample_params_t()
                sd_sample_params_init(&sampleParams)
                sampleParams.sample_method = sampler.cValue
                sampleParams.sample_steps = Int32(steps)
                sampleParams.guidance.txt_cfg = Float(cfgScale)

                gen.width = Int32(width)
                gen.height = Int32(height)
                gen.sample_params = sampleParams
                gen.seed = seed
                gen.batch_count = 1

                let resultPtr: UnsafeMutablePointer<sd_image_t>? = promptCopy.withCString { p in
                    negCopy.withCString { np in
                        gen.prompt = p
                        gen.negative_prompt = np
                        return generate_image(ctx, &gen)
                    }
                }

                // Tear down progress callback + bridge before any exit.
                sd_set_progress_callback(nil, nil)
                Unmanaged<SDCallbackBridge>.fromOpaque(bridgePtr).release()

                guard let resultPtr else {
                    continuation.finish(throwing: StableDiffusionError.generateFailed)
                    await self?.finishGeneration()
                    return
                }
                let img = resultPtr.pointee
                // sd_image_t.data is heap-owned by sd-cpp; free it after
                // we've snapshotted the pixels into our own Data.
                let pixelCount = Int(img.width) * Int(img.height) * Int(img.channel)
                let pixelData = Data(bytes: img.data, count: pixelCount)
                free(img.data)
                free(resultPtr)

                // Encode + persist. PNG with sidecar JSON metadata so
                // gallery rebuilds + reproducing seeds is straightforward.
                do {
                    let savedURL = try Self.savePNG(
                        pixels: pixelData,
                        width: Int(img.width),
                        height: Int(img.height),
                        channels: Int(img.channel),
                        directory: outputDirectory,
                        sidecar: GeneratedImageMetadata(
                            prompt: promptCopy,
                            negativePrompt: negCopy,
                            width: Int(img.width),
                            height: Int(img.height),
                            steps: steps,
                            cfgScale: cfgScale,
                            seed: seed,
                            sampler: sampler.rawValue,
                            modelPath: modelPathSnapshot,
                            createdAt: Date()
                        )
                    )
                    continuation.yield(.done(imageURL: savedURL))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await self?.finishGeneration()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func finishGeneration() {
        isGenerating = false
    }

    /// Soft cancel — sd-cpp doesn't expose an in-flight cancel hook, so
    /// this only matters for back-to-back calls (next generation aborts
    /// before invoking generate_image). Documented limitation.
    public func requestStop() {
        cancelRequested = true
    }

    public func shutdown() {
        if let ctx {
            free_sd_ctx(ctx)
            self.ctx = nil
        }
        loadedModelPath = nil
        isGenerating = false
        isLoading = false
    }

    // MARK: - PNG encoding + metadata sidecar

    /// Encode raw RGB / RGBA pixel data as a PNG and write to disk along
    /// with a JSON sidecar. Returns the PNG URL on success.
    private static func savePNG(
        pixels: Data,
        width: Int,
        height: Int,
        channels: Int,
        directory: URL,
        sidecar: GeneratedImageMetadata
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // sd-cpp returns RGB(A) interleaved 8-bit. CGImage needs a
        // colour space + bitmap info matching the channel layout.
        let bitsPerComponent = 8
        let bitsPerPixel = channels * 8
        let bytesPerRow = width * channels
        guard let provider = CGDataProvider(data: pixels as CFData) else {
            throw StableDiffusionError.encodeFailed
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo
        switch channels {
        case 3: bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        case 4: bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        default: throw StableDiffusionError.encodeFailed
        }
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw StableDiffusionError.encodeFailed
        }

        let basename = Self.basenameFor(sidecar: sidecar)
        let pngURL = directory.appendingPathComponent("\(basename).png")
        let jsonURL = directory.appendingPathComponent("\(basename).json")

        guard let dest = CGImageDestinationCreateWithURL(
            pngURL as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw StableDiffusionError.encodeFailed }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw StableDiffusionError.encodeFailed
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(sidecar)
        try json.write(to: jsonURL)

        return pngURL
    }

    /// Filename: ISO-ish timestamp (filesystem-safe) plus the seed, to make
    /// the gallery sortable by time and recognisable when the user wants to
    /// re-run a specific seed.
    private static func basenameFor(sidecar: GeneratedImageMetadata) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let stamp = formatter.string(from: sidecar.createdAt)
        return "\(stamp)-seed\(sidecar.seed)"
    }
}

/// Sampler choice exposed in the UI. Maps onto sd-cpp's `sample_method_t`.
/// We surface a curated subset (the common, well-behaved ones); the full
/// enum exposes legacy / experimental methods that bloat the picker.
public enum SDSampler: String, CaseIterable, Identifiable, Sendable {
    case euler
    case eulerA
    case heun
    case dpmpp2m
    case dpmpp2sA
    case lcm
    case ddim

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .euler: return "Euler"
        case .eulerA: return "Euler A"
        case .heun: return "Heun"
        case .dpmpp2m: return "DPM++ 2M"
        case .dpmpp2sA: return "DPM++ 2S a"
        case .lcm: return "LCM"
        case .ddim: return "DDIM"
        }
    }

    var cValue: sample_method_t {
        switch self {
        case .euler: return EULER_SAMPLE_METHOD
        case .eulerA: return EULER_A_SAMPLE_METHOD
        case .heun: return HEUN_SAMPLE_METHOD
        case .dpmpp2m: return DPMPP2M_SAMPLE_METHOD
        case .dpmpp2sA: return DPMPP2S_A_SAMPLE_METHOD
        case .lcm: return LCM_SAMPLE_METHOD
        case .ddim: return DDIM_TRAILING_SAMPLE_METHOD
        }
    }
}

/// Sidecar JSON written next to each generated PNG. Captures everything
/// needed to (a) re-run the exact same generation and (b) render
/// gallery rows without reading the PNG bytes.
public struct GeneratedImageMetadata: Codable, Equatable, Sendable {
    public var prompt: String
    public var negativePrompt: String
    public var width: Int
    public var height: Int
    public var steps: Int
    public var cfgScale: Double
    public var seed: Int64
    public var sampler: String
    public var modelPath: String
    public var createdAt: Date

    public init(
        prompt: String,
        negativePrompt: String,
        width: Int,
        height: Int,
        steps: Int,
        cfgScale: Double,
        seed: Int64,
        sampler: String,
        modelPath: String,
        createdAt: Date
    ) {
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.width = width
        self.height = height
        self.steps = steps
        self.cfgScale = cfgScale
        self.seed = seed
        self.sampler = sampler
        self.modelPath = modelPath
        self.createdAt = createdAt
    }
}
