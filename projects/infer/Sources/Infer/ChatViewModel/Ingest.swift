import Foundation
import InferRAG

/// Published state of an in-flight folder scan. Exposed on the VM as
/// `ingestProgress`; the workspace sheet observes it for a progress
/// view. Reset to nil when the scan completes or errors out.
struct IngestProgress: Equatable, Sendable {
    let workspaceId: Int64
    let totalFiles: Int
    let processedFiles: Int
    /// Current file's basename. Nil between files (brief window).
    let currentFile: String?
    let ingested: Int       // newly-ingested (not-already-dedup'd)
    let skippedDuplicates: Int
    let failed: Int
}

extension ChatViewModel {
    /// Scan the workspace's data folder and ingest any new files into
    /// the vector store. Sequential: one file at a time, embeddings
    /// computed on the main embedding runner, storage via the shared
    /// vector store actor.
    ///
    /// No-ops cleanly when:
    ///   - Workspace has no data folder set.
    ///   - Folder doesn't exist.
    ///   - Embedding model isn't downloaded yet.
    ///   - A scan is already in flight.
    ///
    /// Per-file failures are collected in `IngestProgress.failed` and
    /// surfaced in the Console as warning events; the scan continues
    /// past them. Only catastrophic failures (embedder won't load,
    /// vector store bootstrap fails) abort the whole scan.
    func scanAndIngest(workspaceId: Int64) {
        guard ingestProgress == nil else {
            toasts.show("A scan is already running.")
            return
        }
        guard let ws = workspaces.first(where: { $0.id == workspaceId }),
              let folderPath = ws.dataFolder,
              !folderPath.isEmpty
        else {
            errorMessage = "This workspace has no data folder set."
            return
        }
        let folderURL = URL(fileURLWithPath: folderPath)
        guard FileManager.default.fileExists(atPath: folderURL.path) else {
            errorMessage = "Data folder not found: \(folderPath)"
            return
        }
        guard embeddingModelPresent else {
            errorMessage = "Embedding model not downloaded. Download it from this sheet first."
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await self.performScan(workspaceId: workspaceId, folder: folderURL)
        }
    }

    @MainActor
    private func performScan(workspaceId: Int64, folder: URL) async {
        let startAt = Date()
        logs.log(
            .info,
            source: "rag",
            message: "scanning \(folder.path) for workspace \(workspaceId)"
        )

        // Ensure the embedder is loaded. Lazy by design — no cost if
        // the user never triggers a scan.
        do {
            try await ensureEmbeddingModelLoaded()
        } catch {
            logs.log(
                .error,
                source: "rag",
                message: "embedder load failed",
                payload: String(describing: error)
            )
            errorMessage = "Failed to load embedding model: \(error)"
            return
        }

        // Register the workspace with the vector store (compatibility
        // check on subsequent scans). Hard-fails if the user swapped
        // embedding models out from under an existing corpus.
        do {
            try await vectorStore.ensureInitialized(
                workspaceId: workspaceId,
                embeddingModel: EmbeddingModelRef.filename,
                dimension: EmbeddingModelRef.expectedDimension,
                chunkSize: 512,
                chunkOverlap: 50
            )
        } catch {
            let detail = String(describing: error)
            logs.log(
                .error,
                source: "rag",
                message: "vector store init failed",
                payload: detail
            )
            errorMessage = "Vector store init failed: \(detail). Check the Console tab for details. If this persists, delete ~/Library/Application Support/Infer/vectors.sqlite and rescan."
            return
        }

        // Enumerate candidate files.
        let candidates = Self.enumerateCandidates(folder: folder)
        if candidates.isEmpty {
            logs.log(
                .info,
                source: "rag",
                message: "no supported files in \(folder.path)"
            )
            toasts.show("No supported files found in the folder.")
            return
        }

        let splitter = TextSplitter(chunkSize: 512, chunkOverlap: 50)
        var ingested = 0
        var skipped = 0
        var failed = 0

        ingestProgress = IngestProgress(
            workspaceId: workspaceId,
            totalFiles: candidates.count,
            processedFiles: 0,
            currentFile: nil,
            ingested: 0,
            skippedDuplicates: 0,
            failed: 0
        )

        for (idx, url) in candidates.enumerated() {
            ingestProgress = IngestProgress(
                workspaceId: workspaceId,
                totalFiles: candidates.count,
                processedFiles: idx,
                currentFile: url.lastPathComponent,
                ingested: ingested,
                skippedDuplicates: skipped,
                failed: failed
            )

            // Load + hash. Hash over raw bytes so binary-identical
            // files dedup cleanly even under OS-specific line-ending
            // normalization.
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                logs.log(
                    .warning,
                    source: "rag",
                    message: "failed to read \(url.lastPathComponent)",
                    payload: String(describing: error)
                )
                failed += 1
                continue
            }
            let hash = SourceLoader.contentHash(of: data)

            let loaded: LoadedSource
            do {
                loaded = try SourceLoader.load(url)
            } catch SourceLoaderError.empty {
                // Empty files aren't worth an error — skip quietly.
                skipped += 1
                continue
            } catch {
                logs.log(
                    .warning,
                    source: "rag",
                    message: "failed to load \(url.lastPathComponent)",
                    payload: String(describing: error)
                )
                failed += 1
                continue
            }

            let chunks = splitter.split(loaded.content)
            if chunks.isEmpty {
                // Non-empty file that produced zero chunks — rare
                // but possible (e.g., a file of only separator chars).
                // Log so a silent skip doesn't look like a success.
                logs.log(
                    .warning,
                    source: "rag",
                    message: "skipped \(url.lastPathComponent): splitter produced 0 chunks"
                )
                skipped += 1
                continue
            }

            // Embed chunks. Sequential — the embedder is a single
            // context and internally throws on concurrent calls.
            var vectorChunks: [VectorChunk] = []
            vectorChunks.reserveCapacity(chunks.count)
            var embedFailed = false
            for chunk in chunks {
                do {
                    let vec = try await embedder.embed(chunk.content)
                    vectorChunks.append(VectorChunk(
                        content: chunk.content,
                        offsetStart: chunk.offsetStart,
                        offsetEnd: chunk.offsetEnd,
                        embedding: vec
                    ))
                } catch {
                    logs.log(
                        .warning,
                        source: "rag",
                        message: "embed failed for chunk of \(url.lastPathComponent)",
                        payload: String(describing: error)
                    )
                    embedFailed = true
                    break
                }
            }
            if embedFailed {
                failed += 1
                continue
            }

            // Store. ingest() is idempotent on (workspaceId, hash)
            // so if the user re-scans, duplicates return fast.
            do {
                _ = try await vectorStore.ingest(
                    workspaceId: workspaceId,
                    uri: url.path,
                    contentHash: hash,
                    kind: loaded.kind,
                    chunks: vectorChunks
                )
                // Per-file success line at debug level so users who
                // want to verify every file landed can filter the
                // Console to source=rag + level=debug and see the
                // full list, without flooding the default view.
                // Dedup-vs-new isn't distinguished here — see the
                // "known debt" note in rag.plan.
                logs.log(
                    .debug,
                    source: "rag",
                    message: "ingested \(url.lastPathComponent) (\(vectorChunks.count) chunk\(vectorChunks.count == 1 ? "" : "s"))"
                )
                ingested += 1
            } catch {
                logs.log(
                    .warning,
                    source: "rag",
                    message: "ingest failed for \(url.lastPathComponent)",
                    payload: String(describing: error)
                )
                failed += 1
            }
        }

        ingestProgress = IngestProgress(
            workspaceId: workspaceId,
            totalFiles: candidates.count,
            processedFiles: candidates.count,
            currentFile: nil,
            ingested: ingested,
            skippedDuplicates: skipped,
            failed: failed
        )

        let elapsed = Date().timeIntervalSince(startAt)
        // Distinct terminal assertion so the Console shows an
        // unambiguous success/partial signal, not just a count that
        // could hide silent errors. Failures in the loop surface as
        // `.warning` per-file; this line is the summary state.
        if failed > 0 || skipped > 0 {
            let level: LogLevel = failed > 0 ? .warning : .info
            logs.log(
                level,
                source: "rag",
                message: "scan completed with warnings: \(ingested) ingested, \(skipped) skipped, \(failed) failed in \(String(format: "%.1f", elapsed))s"
            )
        } else {
            logs.log(
                .info,
                source: "rag",
                message: "scan successful: \(ingested) file\(ingested == 1 ? "" : "s") ingested in \(String(format: "%.1f", elapsed))s"
            )
        }

        // Refresh stats if the sheet is observing this workspace.
        refreshCorpusStats(workspaceId: workspaceId)

        // Toast summary. Delay clearing the progress state briefly
        // so the UI's "100%" tick is visible.
        let summary: String
        if failed > 0 {
            summary = "Scan done: \(ingested) added, \(skipped) skipped, \(failed) failed."
        } else if ingested == 0 {
            summary = "No new files to ingest."
        } else {
            summary = "Scan done: \(ingested) file\(ingested == 1 ? "" : "s") added."
        }
        toasts.show(summary)

        try? await Task.sleep(nanoseconds: 600_000_000)
        ingestProgress = nil
    }

    /// Walk `folder` recursively, return URLs of files with
    /// supported extensions. Skips hidden files (dotfiles) and
    /// bundles. Symbolic links are resolved once at enumeration time
    /// — we don't follow cycles because the enumerator has its own
    /// cycle detection.
    private static func enumerateCandidates(folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var out: [URL] = []
        for case let url as URL in enumerator {
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  vals.isRegularFile == true
            else { continue }
            if SourceLoader.isSupported(url) {
                out.append(url)
            }
        }
        // Stable order so the progress UI's "current file" is
        // predictable across rescans.
        out.sort { $0.path < $1.path }
        return out
    }

    /// Refresh `corpusStats` for the workspace currently in the
    /// management sheet. Cheap query (two COUNTs); safe to call on
    /// sheet appearance and after every ingest.
    func refreshCorpusStats(workspaceId: Int64) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let (n, c) = try await self.vectorStore.sourceStatistics(
                    workspaceId: workspaceId
                )
                await MainActor.run {
                    self.corpusStats = (workspaceId, n, c)
                }
            } catch {
                self.logs.logFromBackground(
                    .warning,
                    source: "rag",
                    message: "sourceStatistics failed",
                    payload: String(describing: error)
                )
            }
        }
    }
}
