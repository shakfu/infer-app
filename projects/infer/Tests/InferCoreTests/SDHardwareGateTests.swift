import XCTest
@testable import InferCore

final class HardwareTierClassifyTests: XCTestCase {
    func testM1Base8GBClassifiesLow() {
        XCTAssertEqual(
            HardwareTier.classify(memoryGB: 8, chipBrand: "Apple M1"),
            .low
        )
    }

    func testM2Base8GBClassifiesLow() {
        XCTAssertEqual(
            HardwareTier.classify(memoryGB: 8, chipBrand: "Apple M2"),
            .low
        )
    }

    func testM1Base16GBClassifiesMid() {
        XCTAssertEqual(
            HardwareTier.classify(memoryGB: 16, chipBrand: "Apple M1"),
            .mid
        )
    }

    func testM3Pro18GBClassifiesMid() {
        XCTAssertEqual(
            HardwareTier.classify(memoryGB: 18, chipBrand: "Apple M3 Pro"),
            .mid
        )
    }

    func testM2Max32GBClassifiesHigh() {
        XCTAssertEqual(
            HardwareTier.classify(memoryGB: 32, chipBrand: "Apple M2 Max"),
            .high
        )
    }

    func testM1Ultra128GBClassifiesHigh() {
        XCTAssertEqual(
            HardwareTier.classify(memoryGB: 128, chipBrand: "Apple M1 Ultra"),
            .high
        )
    }

    func testProMaxUltraWith8GBStillMid() {
        // Pro/Max/Ultra variants don't exist at 8 GB in shipping
        // hardware, but the classifier shouldn't downgrade them to .low
        // even on a hypothetical low-RAM Pro — the failure mode the gate
        // exists for is base-chip-specific.
        XCTAssertEqual(
            HardwareTier.classify(memoryGB: 8, chipBrand: "Apple M2 Pro"),
            .mid
        )
    }

    func testUnknownBrandTreatedAsBase() {
        XCTAssertEqual(
            HardwareTier.classify(memoryGB: 8, chipBrand: ""),
            .low
        )
        XCTAssertEqual(
            HardwareTier.classify(memoryGB: 32, chipBrand: ""),
            .high
        )
    }
}

final class SDHardwareGateHeuristicTests: XCTestCase {
    func testHeavyQuantsDetected() {
        XCTAssertTrue(SDHardwareGate.isHeavyFilename("z_image_turbo-q6_k.gguf"))
        XCTAssertTrue(SDHardwareGate.isHeavyFilename("model-q8_0.gguf"))
        XCTAssertTrue(SDHardwareGate.isHeavyFilename("flux1-dev-f16.safetensors"))
        XCTAssertTrue(SDHardwareGate.isHeavyFilename("model-bf16.gguf"))
    }

    func testHeavyFamiliesDetected() {
        XCTAssertTrue(SDHardwareGate.isHeavyFilename("z-image-turbo-q4_k_s.gguf"))
        XCTAssertTrue(SDHardwareGate.isHeavyFilename("flux1-schnell-q4_0.safetensors"))
    }

    func testLightQuantsAllowed() {
        XCTAssertFalse(SDHardwareGate.isHeavyFilename("sd-v1-5-q4_k_s.gguf"))
        XCTAssertFalse(SDHardwareGate.isHeavyFilename("sdxl-base-q4_0.safetensors"))
        XCTAssertFalse(SDHardwareGate.isHeavyFilename("model.ckpt"))
    }
}

final class SDHardwareGateDecisionTests: XCTestCase {
    private let lowTier = HardwareTier(
        memoryGB: 8,
        chipBrand: "Apple M1",
        tier: .low
    )
    private let midTier = HardwareTier(
        memoryGB: 16,
        chipBrand: "Apple M1",
        tier: .mid
    )

    func testLowTierBlocksHeavyModel() {
        let decision = SDHardwareGate.evaluate(
            primaryInput: "/Users/me/models/z_image_turbo-Q6_K.gguf",
            tier: lowTier,
            acknowledged: []
        )
        if case .block(let reason, let key) = decision {
            XCTAssertTrue(reason.contains("Heavy model"))
            XCTAssertEqual(key, "/Users/me/models/z_image_turbo-Q6_K.gguf")
        } else {
            XCTFail("expected block, got \(decision)")
        }
    }

    func testLowTierAllowsLightModel() {
        let decision = SDHardwareGate.evaluate(
            primaryInput: "/Users/me/sd-v1-5-q4_k_s.gguf",
            tier: lowTier,
            acknowledged: []
        )
        XCTAssertEqual(decision, .allow)
    }

    func testMidTierAllowsHeavyModel() {
        let decision = SDHardwareGate.evaluate(
            primaryInput: "/Users/me/z_image_turbo-Q6_K.gguf",
            tier: midTier,
            acknowledged: []
        )
        XCTAssertEqual(decision, .allow)
    }

    func testAcknowledgedKeyBypassesGate() {
        let key = "namespace/repo/z_image_turbo-Q6_K.gguf"
        let decision = SDHardwareGate.evaluate(
            primaryInput: key,
            tier: lowTier,
            acknowledged: [key]
        )
        XCTAssertEqual(decision, .allow)
    }

    func testEmptyInputAllowed() {
        let decision = SDHardwareGate.evaluate(
            primaryInput: "  ",
            tier: lowTier,
            acknowledged: []
        )
        XCTAssertEqual(decision, .allow)
    }

    func testHFReferenceUsesTrailingFilenameForHeuristic() {
        let decision = SDHardwareGate.evaluate(
            primaryInput: "city96/z-image-turbo-gguf/z_image_turbo-Q6_K.gguf",
            tier: lowTier,
            acknowledged: []
        )
        if case .block(_, let key) = decision {
            XCTAssertEqual(key, "city96/z-image-turbo-gguf/z_image_turbo-Q6_K.gguf")
        } else {
            XCTFail("expected block on HF reference")
        }
    }
}
