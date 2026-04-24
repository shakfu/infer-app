import Foundation
import HuggingFace

/// Canonical reference to the embedding model the app ships with by
/// default. Single source of truth for the HF repo id, the GGUF
/// filename, and the expected dimension. If we switch models later
/// (e.g. to `nomic-embed-text-v1.5`), this is the only place that
/// needs updating — call sites don't hard-code the numbers.
///
/// Dimension is stamped here rather than read from the loaded model
/// so the UI can show "384-d" hints before download; the
/// `EmbeddingRunner.dimension` post-load is the authoritative value
/// used by the vector store.
enum EmbeddingModelRef {
    static let repoId: String = "CompendiumLabs/bge-small-en-v1.5-gguf"
    static let filename: String = "bge-small-en-v1.5-q8_0.gguf"
    static let expectedDimension: Int = 384
    static let approxBytes: Int64 = 140_000_000  // ~130 MB quantized
    static let displayName: String = "bge-small-en-v1.5 (q8_0)"
}

extension ChatViewModel {
    /// Absolute path where the embedding model file would live (in the
    /// same GGUF directory as chat models, as decided in planning).
    /// Doesn't guarantee the file exists — pair with `isPresent`.
    var embeddingModelPath: String {
        resolvedGGUFDirectory
            .appendingPathComponent(EmbeddingModelRef.filename)
            .path
    }

    /// True if the embedding GGUF is already on disk. Used by the
    /// workspace sheet to decide whether to show the "download" banner.
    var embeddingModelPresent: Bool {
        FileManager.default.fileExists(atPath: embeddingModelPath)
    }

    /// Kick off a HuggingFace download of the embedding model. Routes
    /// progress and completion through `LogCenter` + toasts; does not
    /// block the caller. No-op if the file is already present.
    ///
    /// The workspace UI observes `embeddingModelDownloading` for the
    /// progress indicator and disables its "scan folder" affordance
    /// until the model is ready.
    func downloadEmbeddingModel() {
        guard !embeddingModelPresent else {
            toasts.show("Embedding model already downloaded.")
            return
        }
        guard !embeddingModelDownloading else { return }

        embeddingModelDownloading = true
        embeddingModelDownloadProgress = 0

        let destDir = resolvedGGUFDirectory
        let destURL = URL(fileURLWithPath: embeddingModelPath)
        let filename = EmbeddingModelRef.filename
        let repoId = EmbeddingModelRef.repoId
        // Parse "namespace/name" into Repo.ID — swift-huggingface
        // wants the struct, not a slash-delimited string.
        let parts = repoId.split(separator: "/", maxSplits: 1).map(String.init)
        let repo: Repo.ID
        if parts.count == 2 {
            repo = Repo.ID(namespace: parts[0], name: parts[1])
        } else {
            self.embeddingModelDownloading = false
            self.errorMessage = "Malformed embedding model repo id: \(repoId)"
            return
        }
        let logs = self.logs

        Task { [weak self] in
            // Ensure the target directory exists. The user may have
            // pointed ggufDirectory at a path that doesn't exist yet.
            do {
                try FileManager.default.createDirectory(
                    at: destDir,
                    withIntermediateDirectories: true
                )
            } catch {
                await MainActor.run {
                    self?.embeddingModelDownloading = false
                    self?.errorMessage = "Failed to create models folder: \(error.localizedDescription)"
                }
                return
            }

            let progress = Progress(totalUnitCount: 100)
            let observation = progress.observe(\.fractionCompleted) { p, _ in
                Task { @MainActor in
                    self?.embeddingModelDownloadProgress = p.fractionCompleted
                }
            }
            defer { observation.invalidate() }

            logs.log(
                .info,
                source: "embedding",
                message: "downloading \(filename) from \(repoId)"
            )

            do {
                _ = try await HubClient.default.downloadFile(
                    at: filename,
                    from: repo,
                    to: destURL,
                    progress: progress
                )
                await MainActor.run {
                    guard let self else { return }
                    self.embeddingModelDownloading = false
                    self.embeddingModelDownloadProgress = 1.0
                    self.logs.log(
                        .info,
                        source: "embedding",
                        message: "downloaded \(filename) to \(destURL.path)"
                    )
                    self.toasts.show("Embedding model ready.")
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.embeddingModelDownloading = false
                    self.embeddingModelDownloadProgress = 0
                    self.logs.log(
                        .error,
                        source: "embedding",
                        message: "download failed",
                        payload: String(describing: error)
                    )
                    self.errorMessage = "Failed to download embedding model: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Ensure the embedding model is loaded into the `EmbeddingRunner`
    /// actor. Idempotent — re-loading the same path is a no-op on the
    /// runner side. Called lazily from the RAG pipeline (phase 5) on
    /// the first ingest/query per session.
    func ensureEmbeddingModelLoaded() async throws {
        let path = embeddingModelPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw EmbeddingError.modelLoadFailed(path)
        }
        try await embedder.load(modelPath: path)
    }
}
