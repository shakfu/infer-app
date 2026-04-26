import Foundation
import AppKit
import UniformTypeIdentifiers
import InferCore

extension ChatViewModel {
    /// Autoload the most-recently-used model whose artifact still exists on
    /// disk. Iterates the vault's `models` table in last-used order; the first
    /// entry that passes the availability check wins.
    func autoLoadLastModel() {
        guard !modelLoaded, !isLoadingModel else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.vault.listModels()
                for entry in entries {
                    guard let b = Backend(rawValue: entry.backend) else { continue }
                    switch b {
                    case .llama where ModelStore.llamaArtifactExists(path: entry.modelId):
                        await MainActor.run {
                            self.backend = .llama
                            self.modelInput = entry.modelId
                            self.loadLlama(at: entry.modelId)
                        }
                        return
                    case .mlx where ModelStore.mlxArtifactExists(hfId: entry.modelId):
                        await MainActor.run {
                            self.backend = .mlx
                            self.modelInput = entry.modelId
                            self.loadMLX(hfId: entry.modelId)
                        }
                        return
                    default:
                        continue
                    }
                }
            } catch {
                self.logs.logFromBackground(
                    .error,
                    source: "vault",
                    message: "listModels failed (autoload path)",
                    payload: String(describing: error)
                )
            }
        }
    }

    /// Entry point from the sidebar's Load button. Interprets `modelInput`
    /// according to the current backend.
    func loadCurrentBackend() {
        let raw = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        switch backend {
        case .mlx:
            loadMLX(hfId: raw)
        case .llama:
            if raw.isEmpty {
                errorMessage = "Enter a .gguf path, filename, or URL — or click Browse."
                return
            }
            if let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                downloadAndLoadLlama(url: url)
                return
            }
            let path = resolveLocalGGUFPath(raw)
            if ModelStore.llamaArtifactExists(path: path) {
                loadLlama(at: path)
            } else {
                errorMessage = "No .gguf found at \(path)"
            }
        }
    }

    /// Select a model from the unified dropdown. Populates the text field and
    /// switches the backend segment but does not load — user presses Load.
    func selectAvailableModel(_ entry: VaultModelEntry) {
        guard let b = Backend(rawValue: entry.backend) else { return }
        backend = b
        modelInput = entry.modelId
    }

    func browseForLlamaModel() {
        let types = [UTType(filenameExtension: "gguf")].compactMap { $0 }
        if let url = FileDialogs.openFile(message: "Select a .gguf model file", contentTypes: types) {
            modelInput = url.path
        }
    }

    func pickGGUFDirectory() {
        if let url = FileDialogs.openDirectory(message: "Select a folder to store .gguf downloads") {
            ggufDirectory = url.path
        }
    }

    func resetGGUFDirectory() {
        ggufDirectory = ""
    }

    var resolvedGGUFDirectory: URL {
        ModelStore.resolvedGGUFDirectory(setting: ggufDirectory)
    }

    fileprivate func resolveLocalGGUFPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath { return expanded }
        if raw.contains("/") {
            // Treat as a relative path from the working dir; rare but honor it.
            return (FileManager.default.currentDirectoryPath as NSString)
                .appendingPathComponent(expanded)
        }
        return resolvedGGUFDirectory.appendingPathComponent(expanded).path
    }

    /// Public-from-view entry point for the sidebar's onAppear. Refreshes
    /// whenever the Model tab is shown.
    func refreshAvailableModelsIfNeeded() {
        refreshAvailableModels()
    }

    func refreshAvailableModels() {
        let ggufDir = resolvedGGUFDirectory
        Task { [weak self] in
            guard let self else { return }
            let vaultEntries: [VaultModelEntry]
            do {
                vaultEntries = try await self.vault.listModels()
            } catch {
                self.logs.logFromBackground(
                    .error,
                    source: "vault",
                    message: "listModels failed (refresh)",
                    payload: String(describing: error)
                )
                vaultEntries = []
            }

            // Vault entries ranked by recency, filtered to those still on disk.
            var seen = Set<String>()
            var merged: [VaultModelEntry] = []
            for entry in vaultEntries {
                let present: Bool
                switch entry.backend {
                case Backend.llama.rawValue:
                    present = ModelStore.llamaArtifactExists(path: entry.modelId)
                case Backend.mlx.rawValue:
                    present = ModelStore.mlxArtifactExists(hfId: entry.modelId)
                default:
                    present = false
                }
                guard present else { continue }
                seen.insert("\(entry.backend):\(entry.modelId)")
                merged.append(entry)
            }

            // Union with filesystem scan for models the vault hasn't seen yet
            // (e.g. pre-existing HF cache entries from before the models table,
            // or .gguf files dropped into the folder manually). These sort
            // after vault entries since they have no last-used timestamp.
            let scannedMLX = ModelStore.scanMLXCache()
            for id in scannedMLX where !seen.contains("mlx:\(id)") {
                merged.append(VaultModelEntry(
                    backend: Backend.mlx.rawValue,
                    modelId: id,
                    sourceURL: nil,
                    lastUsedAt: .distantPast
                ))
                seen.insert("mlx:\(id)")
            }
            let scannedGGUF = ModelStore.scanGGUFDirectory(ggufDir)
            for path in scannedGGUF where !seen.contains("llama:\(path)") {
                merged.append(VaultModelEntry(
                    backend: Backend.llama.rawValue,
                    modelId: path,
                    sourceURL: nil,
                    lastUsedAt: .distantPast
                ))
                seen.insert("llama:\(path)")
            }

            await MainActor.run { self.availableModels = merged }
        }
    }

    fileprivate func downloadAndLoadLlama(url: URL) {
        guard !isLoadingModel else { return }
        isLoadingModel = true
        modelLoaded = false
        downloadProgress = 0
        modelStatus = "Downloading \(url.lastPathComponent)…"
        errorMessage = nil
        let dir = resolvedGGUFDirectory
        let downloader = self.ggufDownloader
        loadTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let destination = try await downloader.download(
                    url: url,
                    destinationDir: dir,
                    progress: { frac in
                        Task { @MainActor in
                            guard let self else { return }
                            self.downloadProgress = frac
                        }
                    }
                )
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    self.isLoadingModel = false
                    self.downloadProgress = nil
                    self.loadTask = nil
                    self.modelInput = destination.path
                    // Hand off to the normal load path. Records source URL on
                    // success so the entry is traceable back to its origin.
                    self.loadLlama(at: destination.path, sourceURL: url.absoluteString)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self else { return }
                    self.modelStatus = "Download cancelled"
                    self.isLoadingModel = false
                    self.downloadProgress = nil
                    self.loadTask = nil
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.errorMessage = "Download failed: \(error.localizedDescription)"
                    self.modelStatus = "No model loaded"
                    self.isLoadingModel = false
                    self.downloadProgress = nil
                    self.loadTask = nil
                }
            }
        }
    }

    fileprivate func loadLlama(at path: String, sourceURL: String? = nil) {
        guard !isLoadingModel else { return }
        isLoadingModel = true
        modelLoaded = false
        downloadProgress = nil
        modelStatus = "Loading \((path as NSString).lastPathComponent)…"
        errorMessage = nil
        let runner = self.llama
        let s = self.settings
        loadTask = Task {
            do {
                try Task.checkCancellation()
                try await runner.load(
                    path: path,
                    systemPrompt: s.systemPrompt,
                    temperature: Float(s.temperature),
                    topP: Float(s.topP),
                    topK: 40,
                    seed: s.seed
                )
                try Task.checkCancellation()
                let detected = await runner.detectedTemplateFamily()
                await MainActor.run {
                    self.modelLoaded = true
                    self.modelStatus = "llama: \((path as NSString).lastPathComponent)"
                    self.isLoadingModel = false
                    self.loadTask = nil
                    self.currentModelId = path
                    // Tell the agent layer what tool-call template the
                    // newly-loaded GGUF speaks. Drives the picker's
                    // template-family compatibility check + per-family
                    // tool-prompt composition (M4).
                    self.agentController.setDetectedTemplateFamily(detected)
                    UserDefaults.standard.set(Backend.llama.rawValue, forKey: PersistKey.backend)
                    self.refreshTokenUsage()
                }
                try? await self.vault.recordModel(
                    backend: Backend.llama.rawValue,
                    modelId: path,
                    sourceURL: sourceURL
                )
                await MainActor.run { self.refreshAvailableModels() }
            } catch is CancellationError {
                await MainActor.run {
                    self.modelStatus = "Load cancelled"
                    self.isLoadingModel = false
                    self.loadTask = nil
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to load model: \(error)"
                    self.modelStatus = "No model loaded"
                    self.isLoadingModel = false
                    self.loadTask = nil
                }
            }
        }
    }

    fileprivate func loadMLX(hfId: String) {
        guard !isLoadingModel else { return }
        isLoadingModel = true
        modelLoaded = false
        // Start as nil so statusView shows an indeterminate spinner during
        // the HF metadata/resolution phase (before any byte-level progress
        // callback fires). A stale 0% is misleading when the repo name is
        // wrong and the resolver is retrying.
        downloadProgress = nil
        let id = hfId.isEmpty ? nil : hfId
        modelStatus = "Resolving \(id ?? "default")…"
        errorMessage = nil
        let runner = self.mlx
        let s = self.settings
        let vault = self.vault
        loadTask = Task { [weak self] in
            let progressHandler: @Sendable (Progress) -> Void = { progress in
                let frac = progress.totalUnitCount > 0
                    ? Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
                    : nil
                Task { @MainActor in
                    guard let self else { return }
                    self.downloadProgress = frac
                    if frac != nil, self.modelStatus.hasPrefix("Resolving ") {
                        self.modelStatus = "Downloading \(id ?? "default")…"
                    }
                }
            }
            do {
                try Task.checkCancellation()
                try await runner.load(
                    hfId: id,
                    systemPrompt: s.systemPrompt,
                    temperature: Float(s.temperature),
                    topP: Float(s.topP),
                    seed: s.seed,
                    progress: progressHandler
                )
                try Task.checkCancellation()
                let shown = await runner.loadedModelId ?? "mlx"
                await MainActor.run {
                    guard let self else { return }
                    self.modelLoaded = true
                    self.modelStatus = "MLX: \(shown)"
                    self.isLoadingModel = false
                    self.downloadProgress = nil
                    self.loadTask = nil
                    self.currentModelId = shown
                    // MLX has no GGUF template metadata path; clear the
                    // agent layer's cached fingerprint so a previously-
                    // loaded llama family doesn't gate MLX-targeted
                    // agents incorrectly.
                    self.agentController.setDetectedTemplateFamily(nil)
                    UserDefaults.standard.set(Backend.mlx.rawValue, forKey: PersistKey.backend)
                    self.refreshTokenUsage()
                }
                try? await vault.recordModel(
                    backend: Backend.mlx.rawValue,
                    modelId: shown
                )
                await MainActor.run { [weak self] in
                    self?.refreshAvailableModels()
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self else { return }
                    self.modelStatus = "Load cancelled"
                    self.isLoadingModel = false
                    self.downloadProgress = nil
                    self.loadTask = nil
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.errorMessage = "Failed to load MLX model: \(error)"
                    self.modelStatus = "No model loaded"
                    self.isLoadingModel = false
                    self.downloadProgress = nil
                    self.loadTask = nil
                }
            }
        }
    }

    func cancelLoad() {
        loadTask?.cancel()
    }
}
