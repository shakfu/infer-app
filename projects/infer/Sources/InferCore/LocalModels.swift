import Foundation

/// Loaded local-model config — RAG specs + whisper tier list + Phase-2
/// suggestion lists. Source: `Resources/LocalModels.json` plus optional
/// user override at `~/Library/Application Support/Infer/local-models.json`.
///
/// Fields beyond `repoId` + `filename` (RAG) and `id` + `filename`
/// (whisper) are optional. Computed accessors fill defaults gracefully:
/// missing displayName falls back to the filename, missing approxSize
/// renders as empty string in the UI, etc.
public enum LocalModels {
    /// Currently-active embedding model spec. Reads from the layered
    /// loader; falls back to hardcoded `bge-small-en-v1.5-q8_0` if no
    /// JSON loads.
    public static var embedding: ModelSpec { effective().rag.embedding ?? Self.defaultEmbedding }

    /// Currently-active reranker model spec. Reads from the layered
    /// loader; falls back to hardcoded `bge-reranker-v2-m3-Q8_0` if no
    /// JSON loads.
    public static var reranker: ModelSpec { effective().rag.reranker ?? Self.defaultReranker }

    /// Whisper model choices in display order. Comes from the JSON.
    /// Empty list possible — caller should handle (e.g. show "no
    /// transcription models configured" state). Hardcoded fallback
    /// mirrors the original three (tiny / base / small).
    public static var whisper: [WhisperSpec] {
        let list = effective().whisper
        return list.isEmpty ? Self.defaultWhisper : list
    }

    /// Suggested model ids per local backend, keyed by backend tag.
    /// Surfaced as a Recommended-models dropdown next to the
    /// free-form model input field. Empty array means "no suggestions
    /// — hide the dropdown" (the input still accepts free-form
    /// values). The three keys (`llama`, `mlx`, `stableDiffusion`)
    /// match the local backend kinds in the picker.
    public static var llamaSuggestions: [String] { effective().suggestions.llama }
    public static var mlxSuggestions: [String] { effective().suggestions.mlx }
    public static var stableDiffusionSuggestions: [String] { effective().suggestions.stableDiffusion }

    // MARK: - Public types

    /// RAG model record. `expectedDimension` is the only field the
    /// runtime depends on (vector-store schema); the rest are UI hints.
    /// All optional except `repoId` and `filename`.
    public struct ModelSpec: Decodable, Sendable, Hashable {
        public let repoId: String
        public let filename: String
        public let expectedDimension: Int?
        public let approxBytes: Int64?
        public let displayName: String?

        /// Resolved display name — JSON value, or filename if absent.
        public var resolvedDisplayName: String { displayName ?? filename }
    }

    /// Whisper tier record. `filename` doubles as the on-disk name and
    /// the persisted-selection rawValue (preserves wire compat with the
    /// previous `WhisperModelChoice` enum). `remoteURL` defaults to the
    /// canonical ggerganov path if omitted.
    public struct WhisperSpec: Decodable, Sendable, Hashable, Identifiable {
        public let id: String
        public let filename: String
        public let displayName: String?
        public let approxSize: String?
        public let remoteURL: URL?

        public var resolvedDisplayName: String { displayName ?? id }
        public var resolvedApproxSize: String { approxSize ?? "" }

        /// Default URL points at ggerganov/whisper.cpp on HF — same
        /// scheme the previous enum used. Custom whisper variants can
        /// supply a different repo via `remoteURL`.
        public var resolvedRemoteURL: URL {
            remoteURL ?? URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
        }
    }

    // MARK: - JSON wire shape

    private struct File: Decodable {
        var rag: RAGSection
        var whisper: [WhisperSpec]
        var suggestions: Suggestions?

        struct RAGSection: Decodable {
            var embedding: ModelSpec?
            var reranker: ModelSpec?
        }

        /// Phase 2 — open-ended suggestion lists per local backend.
        /// Decoded but unused until the suggestion-dropdown UI lands.
        struct Suggestions: Decodable {
            var llama: [String]?
            var mlx: [String]?
            var stableDiffusion: [String]?
        }
    }

    /// Resolved view passed around internally. `rag.embedding` /
    /// `rag.reranker` may be nil when neither the user override nor
    /// the bundle supplied them — the public accessors substitute
    /// defaults in that case.
    private struct Resolved {
        var rag: RAG
        var whisper: [WhisperSpec]
        var suggestions: ResolvedSuggestions
        struct RAG {
            var embedding: ModelSpec?
            var reranker: ModelSpec?
        }
        struct ResolvedSuggestions {
            var llama: [String]
            var mlx: [String]
            var stableDiffusion: [String]
        }
    }

    // MARK: - Hardcoded defaults

    private static let defaultEmbedding = ModelSpec(
        repoId: "CompendiumLabs/bge-small-en-v1.5-gguf",
        filename: "bge-small-en-v1.5-q8_0.gguf",
        expectedDimension: 384,
        approxBytes: 140_000_000,
        displayName: "bge-small-en-v1.5 (q8_0)"
    )

    private static let defaultReranker = ModelSpec(
        repoId: "gpustack/bge-reranker-v2-m3-GGUF",
        filename: "bge-reranker-v2-m3-Q8_0.gguf",
        expectedDimension: nil,
        approxBytes: 330_000_000,
        displayName: "bge-reranker-v2-m3 (q8_0)"
    )

    private static let defaultWhisper: [WhisperSpec] = [
        WhisperSpec(id: "tiny",  filename: "ggml-tiny.bin",  displayName: "tiny",  approxSize: "75 MB",  remoteURL: nil),
        WhisperSpec(id: "base",  filename: "ggml-base.bin",  displayName: "base",  approxSize: "142 MB", remoteURL: nil),
        WhisperSpec(id: "small", filename: "ggml-small.bin", displayName: "small", approxSize: "466 MB", remoteURL: nil),
    ]

    // MARK: - Layered load

    /// Loaded via `LayeredJSONConfig`. The hardcoded `defaultValue` is
    /// the all-fallback shape — used only when both JSON layers fail
    /// (corrupt user file + missing bundle resource); `effective()`
    /// post-processes the loaded `File` into `Resolved` so the public
    /// accessors can substitute hardcoded defaults for missing
    /// per-section keys (e.g. user override that only sets `whisper`
    /// keeps the bundled `rag` defaults via the public accessors'
    /// `?? Self.defaultEmbedding` etc.).
    private static let loader = LayeredJSONConfig<File>(
        resourceName: "LocalModels",
        userFilename: "local-models.json",
        bundle: .module,
        defaultValue: File(
            rag: File.RAGSection(embedding: nil, reranker: nil),
            whisper: [],
            suggestions: nil
        )
    )

    private static func effective() -> Resolved {
        let file = loader.resolve()
        return Resolved(
            rag: .init(embedding: file.rag.embedding, reranker: file.rag.reranker),
            whisper: file.whisper,
            suggestions: .init(
                llama: file.suggestions?.llama ?? [],
                mlx: file.suggestions?.mlx ?? [],
                stableDiffusion: file.suggestions?.stableDiffusion ?? []
            )
        )
    }
}
