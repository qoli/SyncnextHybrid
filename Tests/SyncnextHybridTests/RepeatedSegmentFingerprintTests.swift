import AVFAudio
import XCTest
@testable import SyncnextHybrid

final class RepeatedSegmentFingerprintTests: XCTestCase {
    private struct FingerprintEnvelope: Decodable {
        let front: RepeatedSegmentFingerprintArtifact
    }

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
        let startedAt = Date.timeIntervalSinceReferenceDate
        let previous = try RepeatedSegmentFingerprint.compute(
            audioFileURL: URL(fileURLWithPath: previousPath),
            label: "explorer-ep07-front",
            sourceStartSeconds: 0
        )
        let previousReadyAt = Date.timeIntervalSinceReferenceDate
        let current = try RepeatedSegmentFingerprint.compute(
            audioFileURL: URL(fileURLWithPath: currentPath),
            label: "explorer-ep08-front",
            sourceStartSeconds: 0
        )
        let currentReadyAt = Date.timeIntervalSinceReferenceDate

        let match = try XCTUnwrap(
            RepeatedSegmentFingerprint.findBestPairwiseMatch(
                previous: previous,
                current: current
            )
        )
        let matchReadyAt = Date.timeIntervalSinceReferenceDate

        if environment["FINGERPRINT_BENCHMARK"] == "1" {
            print(
                String(
                    format: "fingerprint-benchmark previous=%.6f current=%.6f match=%.6f total=%.6f",
                    previousReadyAt - startedAt,
                    currentReadyAt - previousReadyAt,
                    matchReadyAt - currentReadyAt,
                    matchReadyAt - startedAt
                )
            )
        }

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

    func testPairwiseMatchRanksExpandedEvidenceOverHigherShortSeed() throws {
        var generator = Generator(state: 0xE71D_3A91_4C62_B805)
        var previousValues = (0..<1_800).map { _ in generator.next() }
        var currentValues = (0..<1_800).map { _ in generator.next() }
        let longMask = (UInt64(1) << 13) - 1
        let shortMask = (UInt64(1) << 12) - 1

        // The intended alignment covers 100 seconds at offset -0.1 seconds.
        // A repeated subsection produces a slightly stronger 11.1-second seed
        // at +86.8 seconds, matching the observed episode-20/21 failure shape.
        for index in 0..<111 {
            previousValues[869 + index] = previousValues[index]
                ^ longMask
                ^ shortMask
        }
        for index in 0..<1_000 {
            currentValues[index] = previousValues[index + 1] ^ longMask
        }

        let previous = RepeatedSegmentFingerprintArtifact(
            label: "expanded-evidence-previous",
            sourceStartSeconds: 0,
            fingerprints: previousValues,
            validity: [Bool](repeating: true, count: previousValues.count)
        )
        let current = RepeatedSegmentFingerprintArtifact(
            label: "expanded-evidence-current",
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

        XCTAssertEqual(match.rightRange.lowerBound, 0, accuracy: 0.4)
        XCTAssertEqual(match.rightRange.upperBound, 100, accuracy: 0.4)
        XCTAssertEqual(match.leftRange.lowerBound, 0.1, accuracy: 0.4)
        XCTAssertEqual(match.leftRange.upperBound, 100.1, accuracy: 0.4)
    }

    func testPulledEpisode20And21EnvelopesWhenProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let previousPath = environment["FINGERPRINT_EP20_ENVELOPE"],
              let currentPath = environment["FINGERPRINT_EP21_ENVELOPE"] else {
            throw XCTSkip("Set the two FINGERPRINT_EP*_ENVELOPE paths")
        }
        let decoder = PropertyListDecoder()
        let previous = try decoder.decode(
            FingerprintEnvelope.self,
            from: Data(contentsOf: URL(fileURLWithPath: previousPath))
        ).front
        let current = try decoder.decode(
            FingerprintEnvelope.self,
            from: Data(contentsOf: URL(fileURLWithPath: currentPath))
        ).front

        let match = try XCTUnwrap(
            RepeatedSegmentFingerprint.findBestPairwiseMatch(
                previous: previous,
                current: current
            )
        )

        XCTAssertEqual(match.score, 0.8078125, accuracy: 0.0000001)
        XCTAssertEqual(match.leftRange.lowerBound, 0.3, accuracy: 0.1)
        XCTAssertEqual(match.leftRange.upperBound, 98.8, accuracy: 0.1)
        XCTAssertEqual(match.rightRange.lowerBound, 0.2, accuracy: 0.1)
        XCTAssertEqual(match.rightRange.upperBound, 98.7, accuracy: 0.1)
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

    func testBoundaryRefinementDoesNotTightenForStrongerSeed() throws {
        var generator = Generator(state: 0xB0A1DA7E)
        let previousValues = (0..<1_000).map { _ in generator.next() }
        let unrelatedValues = (0..<1_000).map { _ in generator.next() }
        let seedMask = (UInt64(1) << 13) - 1
        let tailMask = (UInt64(1) << 19) - 1

        func currentValues(seedMask: UInt64) -> [UInt64] {
            var values = unrelatedValues
            for index in 0..<700 {
                values[index] = previousValues[index] ^ seedMask
            }
            for index in 700..<760 {
                values[index] = previousValues[index] ^ tailMask
            }
            return values
        }

        let previous = RepeatedSegmentFingerprintArtifact(
            label: "boundary-previous",
            sourceStartSeconds: 0,
            fingerprints: previousValues,
            validity: [Bool](repeating: true, count: previousValues.count)
        )
        let stronger = RepeatedSegmentFingerprintArtifact(
            label: "boundary-stronger",
            sourceStartSeconds: 0,
            fingerprints: currentValues(seedMask: 0),
            validity: [Bool](repeating: true, count: previousValues.count)
        )
        let weaker = RepeatedSegmentFingerprintArtifact(
            label: "boundary-weaker",
            sourceStartSeconds: 0,
            fingerprints: currentValues(seedMask: seedMask),
            validity: [Bool](repeating: true, count: previousValues.count)
        )

        let strongerMatch = try XCTUnwrap(
            RepeatedSegmentFingerprint.findBestPairwiseMatch(
                previous: previous,
                current: stronger
            )
        )
        let weakerMatch = try XCTUnwrap(
            RepeatedSegmentFingerprint.findBestPairwiseMatch(
                previous: previous,
                current: weaker
            )
        )

        XCTAssertGreaterThan(strongerMatch.score, weakerMatch.score)
        XCTAssertEqual(
            strongerMatch.rightRange.upperBound,
            weakerMatch.rightRange.upperBound,
            accuracy: 0.2
        )
        XCTAssertEqual(strongerMatch.rightRange.upperBound, 76, accuracy: 0.5)
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

    func testCacheBackedPCMBuildsFingerprintWithoutFileArtifact() throws {
        let first = makePCMBuffer(startSeconds: 0, duration: 6)
        let second = makePCMBuffer(startSeconds: 6, duration: 6)
        let batch = HybridFingerprintAudioBatch(
            buffers: [first, second],
            sourceRange: 0..<12,
            provider: .segmentCache,
            segmentCount: 2,
            preparationSeconds: 0,
            cacheWaitSeconds: 0,
            decodeSeconds: 0
        )

        let artifact = try RepeatedSegmentFingerprint.compute(
            audioBatch: batch,
            label: "cache-backed"
        )

        XCTAssertEqual(artifact.sourceStartSeconds, 0)
        XCTAssertGreaterThanOrEqual(artifact.fingerprints.count, 118)
        XCTAssertEqual(artifact.fingerprints.count, artifact.validity.count)
    }

    func testCacheBackedPCMRejectsMidRangeDiscontinuity() throws {
        let first = makePCMBuffer(startSeconds: 0, duration: 6)
        var second = makePCMBuffer(startSeconds: 6, duration: 6)
        second = HybridFingerprintAudioBuffer(
            buffer: second.buffer,
            sourceTime: second.sourceTime,
            discontinuity: true
        )
        let batch = HybridFingerprintAudioBatch(
            buffers: [first, second],
            sourceRange: 0..<12,
            provider: .segmentCache,
            segmentCount: 2,
            preparationSeconds: 0,
            cacheWaitSeconds: 0,
            decodeSeconds: 0
        )

        XCTAssertThrowsError(
            try RepeatedSegmentFingerprint.compute(
                audioBatch: batch,
                label: "discontinuous"
            )
        ) { error in
            XCTAssertEqual(
                error as? RepeatedSegmentFingerprintError,
                .discontinuousAudio
            )
        }
    }

    private func makePCMBuffer(
        startSeconds: Double,
        duration: Double
    ) -> HybridFingerprintAudioBuffer {
        let sampleRate = 48_000.0
        let frames = Int(duration * sampleRate)
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frames)
        )!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        for index in 0..<frames {
            let time = startSeconds + Double(index) / sampleRate
            channel[index] = Float(
                0.4 * sin(2 * Double.pi * 440 * time)
                    + 0.2 * sin(2 * Double.pi * 1_137 * time)
            )
        }
        return HybridFingerprintAudioBuffer(
            buffer: buffer,
            sourceTime: startSeconds,
            discontinuity: startSeconds == 0
        )
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
