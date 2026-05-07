import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Coarse-grained host capability bucket used to gate compute-heavy
/// workloads (Stable Diffusion checkpoints in the GB range, large LLMs).
///
/// Three tiers, from least to most capable:
///
/// - `.low`     — base M1 / M2 chip with ≤ 8 GB RAM. Z-Image-Turbo Q6_K
///                and similar large models can saturate GPU + memory
///                enough to freeze the WindowServer here.
/// - `.mid`     — base chips with > 8 GB *or* a Pro/Max/Ultra variant.
///                Heavy models load but may still feel slow.
/// - `.high`    — anything else (Pro/Max/Ultra with 16+ GB, Mac Pro,
///                Intel boxes with discrete GPUs).
///
/// The classification is deliberately conservative — we'd rather warn
/// once and let the user override than crash the WindowServer. Override
/// is per-model (see `SDHardwareGate`).
public struct HardwareTier: Equatable, Sendable {
    public enum Tier: String, Sendable, Equatable {
        case low, mid, high
    }

    /// Total physical RAM in gigabytes (GB = 1024³ bytes for parity with
    /// what the OS reports in About This Mac).
    public let memoryGB: Double
    /// Marketing string from `sysctlbyname("machdep.cpu.brand_string")`,
    /// e.g. "Apple M1", "Apple M3 Pro", "Apple M2 Max". Empty on
    /// non-Apple-Silicon (Intel) hosts.
    public let chipBrand: String
    public let tier: Tier

    public init(memoryGB: Double, chipBrand: String, tier: Tier) {
        self.memoryGB = memoryGB
        self.chipBrand = chipBrand
        self.tier = tier
    }

    /// Detect the current host. Cheap (two sysctls + arithmetic); no
    /// caching here — call sites can cache if they care.
    public static func current() -> HardwareTier {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = Double(bytes) / 1_073_741_824.0
        let brand = readCPUBrand()
        return HardwareTier(
            memoryGB: gb,
            chipBrand: brand,
            tier: classify(memoryGB: gb, chipBrand: brand)
        )
    }

    /// Pure classification function exposed for tests. Mirrors `current()`'s
    /// logic but takes inputs directly instead of reading sysctls.
    public static func classify(memoryGB: Double, chipBrand: String) -> Tier {
        let lowered = chipBrand.lowercased()
        // Pro / Max / Ultra variants ship with enough memory bandwidth +
        // GPU cores that the heavy-SD failure mode (WindowServer freeze)
        // doesn't manifest, regardless of base RAM. Treat any of those as
        // at-least mid; high if 24+ GB.
        let isProMaxUltra = lowered.contains("pro")
            || lowered.contains("max")
            || lowered.contains("ultra")

        if isProMaxUltra {
            return memoryGB >= 24 ? .high : .mid
        }

        // Base M-series chip (M1, M2, M3, M4, ...) or unknown brand.
        // The 8 GB threshold combined with a base chip is the failure
        // case the gate exists for; everything ≥ 16 is mid.
        if memoryGB <= 9 {
            return .low
        }
        if memoryGB >= 24 {
            return .high
        }
        return .mid
    }

    private static func readCPUBrand() -> String {
        #if canImport(Darwin)
        var size: size_t = 0
        let key = "machdep.cpu.brand_string"
        // First call: query required buffer length.
        if sysctlbyname(key, nil, &size, nil, 0) != 0 || size == 0 {
            return ""
        }
        var buffer = [CChar](repeating: 0, count: size)
        if sysctlbyname(key, &buffer, &size, nil, 0) != 0 {
            return ""
        }
        return String(cString: buffer)
        #else
        return ""
        #endif
    }
}
