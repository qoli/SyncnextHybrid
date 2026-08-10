import XCTest
@testable import SyncnextHybrid

final class RepeatedSegmentFingerprintTests: XCTestCase {
    func testBoundedExtractionRequestPreservesBackRange() {
        let request = HybridIntroAudioExtractionRequest(
            url: URL(string: "https://example.com/episode.m3u8")!,
            sourceRange: 2_520..<2_700,
            outputURL: URL(fileURLWithPath: "/tmp/back.aac")
        )

        XCTAssertEqual(request.sourceRange, 2_520..<2_700)
        XCTAssertEqual(request.maximumDuration, 180)
    }

    func testExplorerGoldenPairWhenFixturesAreProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let previousPath = environment["FINGERPRINT_GOLDEN_PREVIOUS"],
              let currentPath = environment["FINGERPRINT_GOLDEN_CURRENT"] else {
            throw XCTSkip("Set the two FINGERPRINT_GOLDEN_* paths for explorer parity")
        }
        let previous = try RepeatedSegmentFingerprint.compute(
            audioFileURL: URL(fileURLWithPath: previousPath),
            label: "explorer-ep07-front",
            sourceStartSeconds: 0
        )
        let current = try RepeatedSegmentFingerprint.compute(
            audioFileURL: URL(fileURLWithPath: currentPath),
            label: "explorer-ep08-front",
            sourceStartSeconds: 0
        )

        let match = try XCTUnwrap(
            RepeatedSegmentFingerprint.findBestPairwiseMatch(
                previous: previous,
                current: current
            )
        )

        XCTAssertEqual(match.rightRange.lowerBound, 0, accuracy: 0.5)
        XCTAssertEqual(match.rightRange.upperBound, 86.8, accuracy: 1.0)
    }

    func testPairwiseMatchUsesCurrentEpisodeCoordinates() throws {
        var generator = Generator(state: 0x123456789ABCDEF)
        let previousValues = (0..<1_800).map { _ in generator.next() }
        var currentValues = (0..<1_800).map { _ in generator.next() }
        currentValues.replaceSubrange(
            160..<610,
            with: previousValues[100..<550]
        )
        let previous = RepeatedSegmentFingerprintArtifact(
            label: "episode-1-front",
            sourceStartSeconds: 0,
            fingerprints: previousValues,
            validity: [Bool](repeating: true, count: previousValues.count)
        )
        let current = RepeatedSegmentFingerprintArtifact(
            label: "episode-2-front",
            sourceStartSeconds: 0,
            fingerprints: currentValues,
            validity: [Bool](repeating: true, count: currentValues.count)
        )

        let match = try XCTUnwrap(
            RepeatedSegmentFingerprint.findBestPairwiseMatch(
                previous: previous,
                current: current
            )
        )

        XCTAssertEqual(match.rightRange.lowerBound, 16, accuracy: 0.4)
        XCTAssertEqual(match.rightRange.upperBound, 61, accuracy: 0.4)
        XCTAssertGreaterThan(match.score, 0.99)
        XCTAssertGreaterThan(match.score, match.nullThreshold)
    }

    func testBackRegionRetainsAbsoluteSourceTime() throws {
        var generator = Generator(state: 0xCAFEBABE)
        let previousValues = (0..<1_200).map { _ in generator.next() }
        var currentValues = (0..<1_200).map { _ in generator.next() }
        currentValues.replaceSubrange(
            700..<1_100,
            with: previousValues[650..<1_050]
        )
        let previous = RepeatedSegmentFingerprintArtifact(
            label: "episode-1-back",
            sourceStartSeconds: 2_500,
            fingerprints: previousValues,
            validity: [Bool](repeating: true, count: previousValues.count)
        )
        let current = RepeatedSegmentFingerprintArtifact(
            label: "episode-2-back",
            sourceStartSeconds: 2_600,
            fingerprints: currentValues,
            validity: [Bool](repeating: true, count: currentValues.count)
        )

        let match = try XCTUnwrap(
            RepeatedSegmentFingerprint.findBestPairwiseMatch(
                previous: previous,
                current: current
            )
        )

        XCTAssertEqual(match.rightRange.lowerBound, 2_670, accuracy: 0.4)
        XCTAssertEqual(match.rightRange.upperBound, 2_710, accuracy: 0.4)
    }

    func testFingerprintIsStableUnderGainChange() throws {
        let count = 16_000 * 12
        let samples = (0..<count).map { index -> Float in
            let time = Double(index) / 16_000
            return Float(
                0.4 * sin(2 * Double.pi * 440 * time)
                    + 0.2 * sin(2 * Double.pi * 1_137 * time)
            )
        }
        let original = try RepeatedSegmentFingerprint.compute(
            monoSamples: samples,
            label: "original",
            sourceStartSeconds: 0
        )
        let quieter = try RepeatedSegmentFingerprint.compute(
            monoSamples: samples.map { $0 * 0.35 },
            label: "quieter",
            sourceStartSeconds: 0
        )

        let averageSimilarity = zip(
            original.fingerprints.dropFirst(2),
            quieter.fingerprints.dropFirst(2)
        ).reduce(0.0) { partial, pair in
            partial + 1 - Double((pair.0 ^ pair.1).nonzeroBitCount) / 64
        } / Double(original.fingerprints.count - 2)
        XCTAssertGreaterThan(averageSimilarity, 0.70)
        XCTAssertEqual(original.validity, quieter.validity)
    }
}

private struct Generator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
}
