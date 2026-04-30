import Foundation
import AppKit
import HuggingFace
import InferCore
import UniformTypeIdentifiers

extension ChatViewModel {
    /// Default output directory for generated images. Lives under
    /// Application Support so the user can browse there in Finder if
    /// desired, but isn't user-facing in the panel — gallery rows have
    /// "Reveal in Finder" affordances instead.
    var sdOutputDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base
            .appendingPathComponent("Infer", isDirectory: true)
            .appendingPathComponent("Generated Images", isDirectory: true)
    }

    /// Directory where downloaded SD model files (HF / URL) land. Reuses
    /// the GGUF directory setting: SD models and llama models are large
    /// .safetensors / .gguf blobs the user typically wants in the same
    /// folder. If the existing setting is empty, fall back to the
    /// `ModelStore` default.
    var sdModelDirectory: URL {
        ModelStore.resolvedGGUFDirectory(setting: ggufDirectory)
    }

    // MARK: - Load

    /// Single component slot the load flow has to resolve before invoking
    /// the runner. Filled from one of the user's six text fields
    /// (all-in-one model, diffusion model, VAE, LLM, T5XXL, CLIP-L).
    private struct SDComponent {
        let label: String
        let kind: SDComponentKind
        let input: String  // raw user text — local path / URL / HF id
    }

    private enum SDComponentKind {
        case allInOne, diffusion, vae, llm, t5xxl, clipL
    }

    /// Resolved component paths ready to feed `runner.load(...)`.
    private struct SDPaths {
        var modelPath: String?
        var diffusionModelPath: String?
        var vaePath: String?
        var llmPath: String?
        var t5xxlPath: String?
        var clipLPath: String?
    }

    /// Resolve every non-empty model field, downloading as needed, then
    /// hand the bundle to the runner. Multi-file workflows (Z-Image,
    /// Flux) populate diffusion + VAE + text-encoder slots; single-file
    /// SD just fills `sdModelInput`. The two modes are mutually
    /// exclusive — providing both raises an error since sd-cpp would
    /// silently prefer `model_path` and the user's intent would be lost.
    func loadStableDiffusion() {
        sdErrorMessage = nil

        var components: [SDComponent] = []
        let pairs: [(String, SDComponentKind, String)] = [
            (sdModelInput, .allInOne, "All-in-one model"),
            (sdDiffusionModelInput, .diffusion, "Diffusion model"),
            (sdVAEInput, .vae, "VAE"),
            (sdLLMInput, .llm, "LLM (text encoder)"),
            (sdT5XXLInput, .t5xxl, "T5XXL"),
            (sdClipLInput, .clipL, "CLIP-L"),
        ]
        for (raw, kind, label) in pairs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                components.append(SDComponent(label: label, kind: kind, input: trimmed))
            }
        }

        guard !components.isEmpty else {
            sdErrorMessage = "Enter at least one model: all-in-one, or diffusion + VAE + text encoder."
            return
        }
        // The C API would silently take `model_path` and ignore the rest
        // — surface the conflict instead.
        let hasAllInOne = components.contains { $0.kind == .allInOne }
        let hasMulti = components.contains { $0.kind != .allInOne }
        if hasAllInOne && hasMulti {
            sdErrorMessage = "Pick *either* an all-in-one checkpoint *or* the multi-file components. Not both."
            return
        }

        sdIsLoadingModel = true
        sdModelLoaded = false
        sdDownloadProgress = nil
        sdModelStatus = "Resolving \(components.count) file\(components.count == 1 ? "" : "s")…"
        let runner = self.sd
        let modelDir = sdModelDirectory
        let downloader = self.ggufDownloader
        let offload = self.sdOffloadToCPU
        // 0 (the default for unset Int in UserDefaults) means "auto" —
        // the runner picks half cores. Anything else is the user's
        // explicit override.
        let threads: Int? = sdNThreads > 0 ? sdNThreads : nil
        sdLoadTask = Task { [weak self] in
            do {
                var paths = SDPaths()
                for (index, comp) in components.enumerated() {
                    try Task.checkCancellation()
                    await MainActor.run {
                        self?.sdModelStatus = "[\(index + 1)/\(components.count)] \(comp.label)"
                    }
                    let resolved = try await Self.resolveSDComponent(
                        comp,
                        modelDir: modelDir,
                        downloader: downloader,
                        progress: { frac in
                            Task { @MainActor in
                                self?.sdDownloadProgress = frac
                            }
                        }
                    )
                    await MainActor.run {
                        self?.sdDownloadProgress = nil
                    }
                    switch comp.kind {
                    case .allInOne: paths.modelPath = resolved
                    case .diffusion: paths.diffusionModelPath = resolved
                    case .vae: paths.vaePath = resolved
                    case .llm: paths.llmPath = resolved
                    case .t5xxl: paths.t5xxlPath = resolved
                    case .clipL: paths.clipLPath = resolved
                    }
                }

                try Task.checkCancellation()
                await MainActor.run {
                    let primary = (paths.diffusionModelPath ?? paths.modelPath) ?? ""
                    self?.sdModelStatus = "Loading \((primary as NSString).lastPathComponent)…"
                }
                try await runner.load(
                    modelPath: paths.modelPath,
                    diffusionModelPath: paths.diffusionModelPath,
                    vaePath: paths.vaePath,
                    llmPath: paths.llmPath,
                    t5xxlPath: paths.t5xxlPath,
                    clipLPath: paths.clipLPath,
                    offloadParamsToCPU: offload,
                    nThreads: threads
                )
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    let display = (paths.diffusionModelPath ?? paths.modelPath) ?? ""
                    self.sdModelLoaded = true
                    self.sdModelStatus = "SD: \((display as NSString).lastPathComponent)"
                    self.sdIsLoadingModel = false
                    self.sdLoadTask = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    self?.sdModelStatus = "Load cancelled"
                    self?.sdIsLoadingModel = false
                    self?.sdDownloadProgress = nil
                    self?.sdLoadTask = nil
                }
            } catch {
                await MainActor.run {
                    self?.sdErrorMessage = "Failed: \(error.localizedDescription)"
                    self?.sdModelStatus = "No image model loaded"
                    self?.sdIsLoadingModel = false
                    self?.sdDownloadProgress = nil
                    self?.sdLoadTask = nil
                }
            }
        }
    }

    /// Resolve one component's user input to a local file path. Local
    /// absolute paths are passed through unchanged; URLs and HF references
    /// are downloaded into `modelDir` and the destination path returned.
    /// Progress fractions surface via the closure (per-file; the caller
    /// resets between components).
    private static func resolveSDComponent(
        _ comp: SDComponent,
        modelDir: URL,
        downloader: GGUFDownloader,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let raw = comp.input
        if (raw as NSString).isAbsolutePath {
            guard FileManager.default.fileExists(atPath: raw) else {
                throw StableDiffusionError.modelMissing(path: raw)
            }
            return raw
        }
        if let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            let dest = try await downloader.download(
                url: url,
                destinationDir: modelDir,
                progress: progress
            )
            return dest.path
        }
        // HF reference: namespace/name/path/to/file.ext
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw StableDiffusionError.modelMissing(
                path: "\(comp.label): need namespace/name/path/to/file.ext (got `\(raw)`)"
            )
        }
        let repo = Repo.ID(namespace: parts[0], name: parts[1])
        let filename = parts.dropFirst(2).joined(separator: "/")
        try FileManager.default.createDirectory(
            at: modelDir, withIntermediateDirectories: true
        )
        let destURL = modelDir.appendingPathComponent((filename as NSString).lastPathComponent)
        let progressObj = Progress(totalUnitCount: 100)
        let observation = progressObj.observe(\.fractionCompleted) { p, _ in
            progress(p.fractionCompleted)
        }
        defer { observation.invalidate() }
        _ = try await HubClient.default.downloadFile(
            at: filename, from: repo, to: destURL, progress: progressObj
        )
        return destURL.path
    }

    func cancelSDLoad() {
        sdLoadTask?.cancel()
    }

    func browseForSDModel() {
        let types = [
            UTType(filenameExtension: "safetensors"),
            UTType(filenameExtension: "gguf"),
            UTType(filenameExtension: "ckpt"),
        ].compactMap { $0 }
        if let url = FileDialogs.openFile(
            message: "Select a Stable Diffusion model file",
            contentTypes: types
        ) {
            sdModelInput = url.path
        }
    }

    // MARK: - Generate

    func generateImage() {
        // Cloud routes through its own helper because the readiness
        // check is "key resolved" (no model file) and the param set is
        // disjoint from local SD's. Keeps both paths' guards local to
        // their backend.
        if imageBackend == .openai {
            generateImageCloud()
            return
        }

        guard sdModelLoaded, !sdIsGenerating else { return }
        let trimmed = sdPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            sdErrorMessage = "Enter a prompt."
            return
        }
        sdErrorMessage = nil
        sdIsGenerating = true
        sdProgress = nil

        // Resolve seed: empty input = random (signed Int64). Negative seeds
        // are accepted by sd-cpp.
        let seed: Int64
        if let s = Int64(sdSeedInput.trimmingCharacters(in: .whitespacesAndNewlines)) {
            seed = s
        } else {
            seed = Int64.random(in: 0...Int64.max)
        }

        let runner = self.sd
        let directory = self.sdOutputDirectory
        let prompt = sdPrompt
        let negative = sdNegativePrompt
        let width = sdWidth
        let height = sdHeight
        let steps = sdSteps
        let cfg = sdCfgScale
        let sampler = sdSampler

        sdGenerationTask = Task { [weak self] in
            do {
                let stream = await runner.generate(
                    prompt: prompt,
                    negativePrompt: negative,
                    width: width,
                    height: height,
                    steps: steps,
                    cfgScale: cfg,
                    seed: seed,
                    sampler: sampler,
                    outputDirectory: directory
                )
                for try await event in stream {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self?.sdProgress = event
                    }
                    if case .done(let imageURL) = event {
                        await MainActor.run {
                            self?.appendGalleryEntry(at: imageURL)
                        }
                    }
                }
                await MainActor.run {
                    self?.sdIsGenerating = false
                    self?.sdGenerationTask = nil
                }
            } catch {
                await MainActor.run {
                    self?.sdErrorMessage = "Generation failed: \(error.localizedDescription)"
                    self?.sdIsGenerating = false
                    self?.sdGenerationTask = nil
                }
            }
        }
    }

    func cancelImageGeneration() {
        // sd-cpp can't actually interrupt mid-generation (no public hook
        // in the C API). Cancelling the Task here only stops *us* from
        // consuming the stream and from launching follow-on calls — the
        // current generate_image continues until it returns. Documented
        // limitation of sd-cpp.
        //
        // Cloud cancellation is real — the URLSession data task is
        // torn down by Task.cancel() propagation.
        sdGenerationTask?.cancel()
        let runner = self.sd
        let cloud = self.cloudImage
        Task {
            await runner.requestStop()
            await cloud.requestStop()
        }
    }

    /// OpenAI gpt-image-1 generation. Resolves the API key from the
    /// keychain (or env var fallback) on every call so a key rotation
    /// applies on the next generate without an explicit reload.
    /// Status / progress / errors flow through the same `sdIsGenerating`
    /// / `sdProgress` / `sdErrorMessage` fields the local path uses, so
    /// the panel UI doesn't need a parallel state machine.
    private func generateImageCloud() {
        guard !sdIsGenerating else { return }
        let trimmed = sdPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            sdErrorMessage = "Enter a prompt."
            return
        }
        guard let resolved = APIKeyStore.resolve(for: .openai) else {
            sdErrorMessage = "Set an OpenAI API key (Model tab → Set Key…)."
            return
        }

        sdErrorMessage = nil
        sdIsGenerating = true
        sdProgress = nil

        let runner = self.cloudImage
        let directory = self.sdOutputDirectory
        let prompt = sdPrompt
        let params = CloudImageParams(
            model: "gpt-image-1",
            size: openaiImageSize,
            quality: openaiImageQuality,
            outputFormat: openaiImageFormat,
            background: openaiImageBackground,
            n: 1
        )
        let key = resolved.key

        sdGenerationTask = Task { [weak self] in
            do {
                try await runner.configure(apiKey: key)
                let stream = await runner.generate(
                    prompt: prompt,
                    params: params,
                    outputDirectory: directory
                )
                for try await event in stream {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self?.sdProgress = event
                    }
                    if case .done(let imageURL) = event {
                        await MainActor.run {
                            self?.appendGalleryEntry(at: imageURL)
                        }
                    }
                }
                await MainActor.run {
                    self?.sdIsGenerating = false
                    self?.sdGenerationTask = nil
                }
            } catch {
                await MainActor.run {
                    self?.sdErrorMessage = "Generation failed: \(error.localizedDescription)"
                    self?.sdIsGenerating = false
                    self?.sdGenerationTask = nil
                }
            }
        }
    }

    // MARK: - Gallery

    /// Build the gallery from on-disk PNG + sidecar pairs. Called once at
    /// app launch (via `bootstrap` flow) and on demand from the panel.
    func refreshGallery() {
        let dir = self.sdOutputDirectory
        Task { [weak self] in
            let entries = await Self.scanGallery(in: dir)
            await MainActor.run {
                self?.sdGallery = entries
            }
        }
    }

    private static func scanGallery(in directory: URL) async -> [SDGalleryEntry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var entries: [SDGalleryEntry] = []
        // Local SD always writes .png; cloud entries may be .jpg or
        // .webp depending on the user's `output_format`. The sidecar is
        // paired by basename, regardless of extension.
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp"]
        for url in items where imageExts.contains(url.pathExtension.lowercased()) {
            let sidecarURL = url.deletingPathExtension().appendingPathExtension("json")
            // Sidecar is optional — if missing/corrupt we still surface the
            // image with a placeholder metadata so the user can see what's
            // there. Renaming the PNG outside of the app or hand-editing
            // the sidecar shouldn't lose the row.
            let metadata: GeneratedImageMetadata
            if let data = try? Data(contentsOf: sidecarURL),
               let decoded = try? decoder.decode(GeneratedImageMetadata.self, from: data) {
                metadata = decoded
            } else {
                metadata = GeneratedImageMetadata(
                    prompt: "(metadata missing)",
                    negativePrompt: "",
                    width: 0,
                    height: 0,
                    steps: 0,
                    cfgScale: 0,
                    seed: 0,
                    sampler: "",
                    modelPath: "",
                    createdAt: (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                )
            }
            entries.append(SDGalleryEntry(imageURL: url, metadata: metadata))
        }
        return entries.sorted { $0.metadata.createdAt > $1.metadata.createdAt }
    }

    /// Append a fresh generation to the gallery without rescanning the
    /// whole directory. Sidecar JSON was just written by the runner, so
    /// reading it here is safe.
    private func appendGalleryEntry(at imageURL: URL) {
        let sidecarURL = imageURL.deletingPathExtension().appendingPathExtension("json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: sidecarURL),
              let metadata = try? decoder.decode(GeneratedImageMetadata.self, from: data)
        else { return }
        sdGallery.insert(SDGalleryEntry(imageURL: imageURL, metadata: metadata), at: 0)
    }

    /// Open the PNG in Finder and select it. Convenience for gallery row
    /// right-click.
    func revealGalleryEntryInFinder(_ entry: SDGalleryEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.imageURL])
    }

    /// Push a generated image into the chat composer's pending attachment.
    /// Lets the user feed an SD output into a multimodal MLX chat. No-op
    /// if the active backend doesn't accept images (currently MLX only).
    func useGalleryEntryInChat(_ entry: SDGalleryEntry) {
        pendingImageURL = entry.imageURL
    }

    /// Flip the curation flag on a gallery entry. Writes the sidecar
    /// JSON synchronously (small file, main-thread-safe) and updates
    /// `sdGallery` so SwiftUI re-renders. No-op if the entry isn't in
    /// the current gallery (was deleted concurrently).
    func setKept(_ entry: SDGalleryEntry, kept: Bool) {
        guard let idx = sdGallery.firstIndex(where: { $0.id == entry.id }) else { return }
        var updated = sdGallery[idx].metadata
        updated.kept = kept
        let sidecarURL = entry.imageURL
            .deletingPathExtension()
            .appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(updated)
            try data.write(to: sidecarURL, options: .atomic)
            sdGallery[idx] = SDGalleryEntry(imageURL: entry.imageURL, metadata: updated)
        } catch {
            // Failure here is non-fatal — the in-memory flag stays the
            // old value, the user can retry. No alert because the
            // gallery is a high-traffic surface and a transient APFS
            // hiccup shouldn't pop a dialog.
            FileHandle.standardError.write(
                Data("setKept failed for \(entry.imageURL.lastPathComponent): \(error)\n".utf8)
            )
        }
    }

    /// Bulk version. Same write-each-sidecar shape — no batched
    /// optimisation because the file count for a curation pass is
    /// small (tens, not thousands) and the cost is dominated by APFS
    /// overhead, not encoding.
    func bulkSetKept(_ entries: [SDGalleryEntry], kept: Bool) {
        for entry in entries {
            setKept(entry, kept: kept)
        }
    }

    /// Move a gallery entry's PNG + sidecar to the Trash. Recoverable
    /// from Finder's "Put Back" so this is a soft delete. Removes the
    /// entry from `sdGallery` regardless of recycle outcome — if the
    /// recycle fails (file already gone, permission denied), the user
    /// shouldn't keep seeing the row.
    func deleteGalleryEntry(_ entry: SDGalleryEntry) {
        let pngURL = entry.imageURL
        let jsonURL = pngURL.deletingPathExtension().appendingPathExtension("json")
        var urls = [pngURL]
        if FileManager.default.fileExists(atPath: jsonURL.path) {
            urls.append(jsonURL)
        }
        NSWorkspace.shared.recycle(urls) { _, error in
            if let error {
                FileHandle.standardError.write(
                    Data("deleteGalleryEntry recycle failed: \(error)\n".utf8)
                )
            }
        }
        sdGallery.removeAll { $0.id == entry.id }
    }

    /// Bulk delete. Recycles all matched URLs in one NSWorkspace call
    /// so the user gets one Trash sound, not N.
    func bulkDelete(_ entries: [SDGalleryEntry]) {
        var urls: [URL] = []
        for entry in entries {
            urls.append(entry.imageURL)
            let jsonURL = entry.imageURL
                .deletingPathExtension()
                .appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: jsonURL.path) {
                urls.append(jsonURL)
            }
        }
        if !urls.isEmpty {
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error {
                    FileHandle.standardError.write(
                        Data("bulkDelete recycle failed: \(error)\n".utf8)
                    )
                }
            }
        }
        let ids = Set(entries.map { $0.id })
        sdGallery.removeAll { ids.contains($0.id) }
    }

    /// Repopulate the prompt + parameters from a gallery entry's sidecar.
    /// Convenience for "render again with the same settings."
    func reuseGalleryEntrySettings(_ entry: SDGalleryEntry) {
        sdPrompt = entry.metadata.prompt
        sdNegativePrompt = entry.metadata.negativePrompt
        if entry.metadata.width > 0 { sdWidth = entry.metadata.width }
        if entry.metadata.height > 0 { sdHeight = entry.metadata.height }
        if entry.metadata.steps > 0 { sdSteps = entry.metadata.steps }
        if entry.metadata.cfgScale > 0 { sdCfgScale = entry.metadata.cfgScale }
        sdSeedInput = String(entry.metadata.seed)
        if let s = SDSampler(rawValue: entry.metadata.sampler) {
            sdSampler = s
        }
    }
}
