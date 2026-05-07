import Foundation

/// Refuses to load Stable Diffusion checkpoints whose size + quantisation
/// can saturate GPU + memory enough to freeze the WindowServer on
/// low-tier Apple Silicon hosts. The gate is *advisory* — every block
/// can be acknowledged once and the model will load on subsequent
/// attempts.
///
/// The check is filename-based on purpose: it has to fire *before*
/// we kick off a multi-GB Hugging Face download, otherwise the user
/// pays the bandwidth cost to learn their machine can't load the model.
/// File-size verification post-download would be more accurate but adds
/// a second failure point users would hit only after waiting; the
/// filename heuristic catches the canonical heavy quants
/// (`Q6_K`, `Q8_0`, `f16`, `bf16`) and the model families that bundle
/// their own large text encoders (`z_image`, `flux`).
public enum SDHardwareGate {
    public enum Decision: Equatable, Sendable {
        case allow
        /// Loading is blocked unless the user explicitly acknowledges the
        /// risk for this specific model identifier. `reason` is shown in
        /// the SD panel; `acknowledgementKey` is what the caller must
        /// add to its acknowledged-models list to bypass the next time.
        case block(reason: String, acknowledgementKey: String)
    }

    /// Gate the load. `primaryInput` is the user's text in the all-in-one
    /// or diffusion-model field — a local path, an HTTPS URL, or an HF
    /// reference like `namespace/name/path/to/file.gguf`. The filename
    /// heuristic looks at the trailing path component; the
    /// acknowledgement key uses the trimmed full input so re-typing the
    /// same string matches.
    public static func evaluate(
        primaryInput: String,
        tier: HardwareTier,
        acknowledged: Set<String>
    ) -> Decision {
        let trimmed = primaryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .allow }

        if acknowledged.contains(trimmed) { return .allow }

        guard tier.tier == .low else { return .allow }

        let filename = (trimmed as NSString).lastPathComponent.lowercased()
        guard isHeavyFilename(filename) else { return .allow }

        let reason = """
            Heavy model on a low-spec machine (\
            \(formatGB(tier.memoryGB)) GB \
            \(tier.chipBrand.isEmpty ? "Apple Silicon base chip" : tier.chipBrand)) — \
            \((trimmed as NSString).lastPathComponent) can saturate GPU + memory and \
            freeze the WindowServer. Try a lighter quant (Q4_K_S / Q4_0) or load \
            anyway if you accept the risk.
            """
        return .block(reason: reason, acknowledgementKey: trimmed)
    }

    /// Heuristic match against the trailing filename. Looking for one of:
    /// - heavy quantisation tags (Q6_K, Q8_0, F16, BF16) — these mark the
    ///   GGUF tier where memory pressure becomes the dominant failure
    ///   mode on 8 GB machines;
    /// - model families that bundle their own large text encoders or
    ///   diffusion backbones (Z-Image, Flux) — these run a multi-billion-
    ///   parameter encoder + DiT through Metal even at lower quants.
    ///
    /// Visible to tests so the heuristic can be checked without
    /// constructing a `HardwareTier`.
    public static func isHeavyFilename(_ filenameLowercased: String) -> Bool {
        let heavyQuants = ["q6_k", "q8_0", "-f16", "-fp16", "-bf16", ".f16.", ".fp16.", ".bf16."]
        if heavyQuants.contains(where: { filenameLowercased.contains($0) }) {
            return true
        }
        // Model-family markers. `z_image` covers `z_image_turbo` /
        // `z-image-turbo` (we lowercased + the heuristic is substring).
        // `flux` is the SD-derived FLUX.1 family. Both bundle large
        // ancillary encoders that push memory past 8 GB even at Q4.
        let heavyFamilies = ["z_image", "z-image", "flux"]
        return heavyFamilies.contains(where: { filenameLowercased.contains($0) })
    }

    private static func formatGB(_ gb: Double) -> String {
        // Match what About This Mac shows — whole numbers when ≥ 8.
        if gb >= 8 { return String(Int(gb.rounded())) }
        return String(format: "%.1f", gb)
    }
}
