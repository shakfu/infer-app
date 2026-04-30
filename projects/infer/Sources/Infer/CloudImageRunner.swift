import Foundation
import InferCore
import ImageIO
import UniformTypeIdentifiers

/// Errors specific to the cloud image runner. Wire-level errors come
/// from `CloudError` directly; this enum covers post-wire failures
/// (writing the PNG / sidecar to disk, missing key, etc.).
public enum CloudImageError: Error, LocalizedError {
    case notConfigured
    case missingKey
    case busy
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud image runner not configured"
        case .missingKey: return "No API key set for OpenAI"
        case .busy: return "Image generation already in flight"
        case .writeFailed: return "Failed to write generated image to disk"
        }
    }
}

/// Cloud-image runner. Mirrors `StableDiffusionRunner`'s actor shape so
/// `ChatViewModel` can swap on `imageBackend` without a protocol layer:
/// `generate(prompt:params:dir:) -> AsyncThrowingStream<SDProgress, Error>`,
/// `requestStop()`, `shutdown()`. Reuses `SDProgress.done` for the
/// final-image event so the gallery refresh path stays unchanged.
///
/// No model loading — cloud is stateless. `configure(apiKey:)` just
/// builds the underlying HTTP client; it can be called repeatedly to
/// rotate keys without affecting in-flight generations (each generation
/// holds its own client reference).
///
/// Cancellation: cloud images take 5-30s and the underlying URLSession
/// task is cancellable. Calling `requestStop()` cancels the active
/// generation Task, which propagates to the URLSession data task.
public actor CloudImageRunner {
    private var client: CloudImageClient?
    private var isGenerating = false
    private var activeTask: Task<Void, Never>?

    /// Factory so tests can inject a stub client. Default uses
    /// `OpenAIImageClient` against the canonical base URL.
    private let clientFactory: @Sendable (String) -> CloudImageClient

    public init(
        clientFactory: @escaping @Sendable (String) -> CloudImageClient = CloudImageRunner.defaultClientFactory
    ) {
        self.clientFactory = clientFactory
    }

    public static let defaultClientFactory: @Sendable (String) -> CloudImageClient = { apiKey in
        OpenAIImageClient(apiKey: apiKey)
    }

    public var isConfigured: Bool { client != nil }

    /// Set / replace the API key. Idempotent — safe to call on every
    /// generate() call site to refresh from the keychain.
    public func configure(apiKey: String) throws {
        guard !apiKey.isEmpty else { throw CloudImageError.missingKey }
        self.client = clientFactory(apiKey)
    }

    /// Generate one image (or `params.n` images, but the gallery flow
    /// works one at a time today). Streams a single `.done(imageURL:)`
    /// event per saved image; no per-step progress because gpt-image-1
    /// at this tier doesn't expose mid-flight progress (streaming
    /// partial images is a separate API path that this runner doesn't
    /// implement yet).
    public func generate(
        prompt: String,
        params: CloudImageParams,
        outputDirectory: URL
    ) -> AsyncThrowingStream<SDProgress, Error> {
        AsyncThrowingStream { continuation in
            guard !isGenerating else {
                continuation.finish(throwing: CloudImageError.busy)
                return
            }
            guard let client else {
                continuation.finish(throwing: CloudImageError.notConfigured)
                return
            }

            isGenerating = true
            let task = Task {
                // Task inherits actor isolation from the runner — match
                // the pattern used by `CloudRunner.sendUserMessage`.
                // `finishGeneration()` is a direct sync call.
                defer { self.finishGeneration() }
                do {
                    let results = try await client.generate(prompt: prompt, params: params)
                    if Task.isCancelled {
                        continuation.finish(throwing: CloudError.cancelled)
                        return
                    }
                    for result in results {
                        let url = try Self.writeImage(
                            data: result.data,
                            params: params,
                            prompt: prompt,
                            revisedPrompt: result.revisedPrompt,
                            width: result.width,
                            height: result.height,
                            outputFormat: params.outputFormat,
                            directory: outputDirectory
                        )
                        continuation.yield(.done(imageURL: url))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CloudError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            activeTask = task
        }
    }

    public func requestStop() {
        activeTask?.cancel()
    }

    public func shutdown() {
        activeTask?.cancel()
        activeTask = nil
        client = nil
        isGenerating = false
    }

    private func finishGeneration() {
        isGenerating = false
        activeTask = nil
    }

    /// Write the bytes returned by the API to disk + a JSON sidecar
    /// matching the local-SD shape. Filename uses the local SD
    /// timestamp/seed convention; cloud has no real seed so we
    /// substitute the createdAt epoch in seconds.
    private static func writeImage(
        data: Data,
        params: CloudImageParams,
        prompt: String,
        revisedPrompt: String?,
        width providedWidth: Int,
        height providedHeight: Int,
        outputFormat: CloudImageParams.OutputFormat,
        directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let createdAt = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let stamp = formatter.string(from: createdAt)
        let pseudoSeed = Int64(createdAt.timeIntervalSince1970)
        let basename = "\(stamp)-openai-\(pseudoSeed)"

        let ext: String
        switch outputFormat {
        case .png: ext = "png"
        case .jpeg: ext = "jpg"
        case .webp: ext = "webp"
        }
        // Sidecar always has the same `.json` suffix and shares the basename;
        // the gallery scanner pairs them by stripping the image extension.
        let imageURL = directory.appendingPathComponent("\(basename).\(ext)")
        let jsonURL = directory.appendingPathComponent("\(basename).json")

        do {
            try data.write(to: imageURL, options: .atomic)
        } catch {
            throw CloudImageError.writeFailed
        }

        // Probe actual dimensions from the bytes when the API didn't
        // tell us (size: auto path). CGImageSource is cheap — it reads
        // only the header, not the pixels.
        var width = providedWidth
        var height = providedHeight
        if width == 0 || height == 0,
           let src = CGImageSourceCreateWithData(data as CFData, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            if let w = props[kCGImagePropertyPixelWidth] as? Int { width = w }
            if let h = props[kCGImagePropertyPixelHeight] as? Int { height = h }
        }

        let sidecar = GeneratedImageMetadata(
            prompt: revisedPrompt ?? prompt,
            negativePrompt: "",
            width: width,
            height: height,
            steps: 0,
            cfgScale: 0,
            seed: 0,
            sampler: "",
            modelPath: params.model,
            createdAt: createdAt,
            kept: false,
            provider: "openai"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(sidecar)
        try json.write(to: jsonURL, options: .atomic)

        return imageURL
    }
}
