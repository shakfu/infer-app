import Foundation
import HuggingFace

/// Canonical reference to the reranker model the app ships with.
/// Mirrors `EmbeddingModelRef` — single source of truth for the HF
/// repo, the GGUF filename, and approximate size. Switching models
/// later means editing one enum (and re-downloading).
///
/// bge-reranker-v2-m3 is multilingual and the strongest small
/// open-weight cross-encoder as of this writing; Q8_0 quant trades
/// ~0.5 point of reranker accuracy for half the download size.
enum RerankerModelRef {
    static let repoId: String = "gpustack/bge-reranker-v2-m3-GGUF"
    static let filename: String = "bge-reranker-v2-m3-Q8_0.gguf"
    static let approxBytes: Int64 = 330_000_000  // ~315 MB
    static let displayName: String = "bge-reranker-v2-m3 (q8_0)"
}

extension ChatViewModel {
    /// Absolute path where the reranker model file lives — same
    /// directory as chat models + embedding model (user's configured
    /// `ggufDirectory`). One place to look for anything GGUF.
    var rerankerModelPath: String {
        resolvedGGUFDirectory
            .appendingPathComponent(RerankerModelRef.filename)
            .path
    }

    var rerankerModelPresent: Bool {
        FileManager.default.fileExists(atPath: rerankerModelPath)
    }

    /// Download the reranker model via HuggingFace. Same shape as
    /// `downloadEmbeddingModel` — progress via KVO on `Progress`,
    /// log messages through `LogCenter` with source `rerank`, toast
    /// on completion. Caller is responsible for UI gating so we
    /// don't start two downloads at once.
    func downloadRerankerModel() {
        guard !rerankerModelPresent else {
            toasts.show("Reranker model already downloaded.")
            return
        }
        guard !rerankerModelDownloading else { return }

        rerankerModelDownloading = true
        rerankerModelDownloadProgress = 0

        let destDir = resolvedGGUFDirectory
        let destURL = URL(fileURLWithPath: rerankerModelPath)
        let filename = RerankerModelRef.filename
        let repoIdString = RerankerModelRef.repoId
        let parts = repoIdString.split(separator: "/", maxSplits: 1).map(String.init)
        let repo: Repo.ID
        if parts.count == 2 {
            repo = Repo.ID(namespace: parts[0], name: parts[1])
        } else {
            self.rerankerModelDownloading = false
            self.errorMessage = "Malformed reranker repo id: \(repoIdString)"
            return
        }
        let logs = self.logs

        Task { [weak self] in
            do {
                try FileManager.default.createDirectory(
                    at: destDir, withIntermediateDirectories: true
                )
            } catch {
                await MainActor.run {
                    self?.rerankerModelDownloading = false
                    self?.errorMessage = "Failed to create models folder: \(error.localizedDescription)"
                }
                return
            }

            let progress = Progress(totalUnitCount: 100)
            let observation = progress.observe(\.fractionCompleted) { p, _ in
                Task { @MainActor in
                    self?.rerankerModelDownloadProgress = p.fractionCompleted
                }
            }
            defer { observation.invalidate() }

            logs.log(
                .info,
                source: "rerank",
                message: "downloading \(filename) from \(repoIdString)"
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
                    self.rerankerModelDownloading = false
                    self.rerankerModelDownloadProgress = 1.0
                    self.logs.log(
                        .info,
                        source: "rerank",
                        message: "downloaded \(filename) to \(destURL.path)"
                    )
                    self.toasts.show("Reranker model ready.")
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.rerankerModelDownloading = false
                    self.rerankerModelDownloadProgress = 0
                    self.logs.log(
                        .error,
                        source: "rerank",
                        message: "download failed",
                        payload: String(describing: error)
                    )
                    self.errorMessage = "Failed to download reranker: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Ensure the reranker model is loaded. Idempotent on the
    /// runner side. Called from the RAG pipeline on first
    /// rerank-enabled query per session.
    func ensureRerankerLoaded() async throws {
        let path = rerankerModelPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw RerankerError.modelLoadFailed(path)
        }
        try await reranker.load(modelPath: path)
    }
}
