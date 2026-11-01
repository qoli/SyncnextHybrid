import AVFAudio
import XCTest
@testable import SyncnextHybrid

final class RepeatedSegmentFingerprintCoverageTests: XCTestCase {
    private let sampleRate = 16_000.0
    private let sourceRange = 2_506.585..<2_686.585

    func testCompleteAndAcceptedTrailingCoveragePreservesActualSamples() throws {
        for shortfall in [0, 0.02, 0.232104, 0.25 - 1 / sampleRate, 0.25] {
            let buffer = makeBuffer(
                start: sourceRange.lowerBound,
                end: sourceRange.upperBound - shortfall
            )
            let actualEnd = buffer.sourceTime
                + Double(buffer.buffer.frameLength) / sampleRate
            XCTAssertEqual(
                sourceRange.upperBound - actualEnd,
                shortfall,
                accuracy: 1 / sampleRate
            )

            let artifact = try RepeatedSegmentFingerprint.compute(
                audioBatch: batch([buffer]), label: "trailing-\(shortfall)"
            )
            let expected = try RepeatedSegmentFingerprint.compute(
                monoSamples: samples(in: buffer), label: "trailing-\(shortfall)",
                sourceStartSeconds: sourceRange.lowerBound
            )

            // Exact artifact parity proves that no missing audio was padded,
            // stretched, or assigned a different source-time origin.
            XCTAssertEqual(artifact, expected, "shortfall=\(shortfall)")
        }
    }

    func testTrailingCoverageBeyondToleranceIsRejected() {
        for shortfall in [0.25 + 1 / sampleRate, 0.3] {
            assertDiscontinuous([
                makeBuffer(
                    start: sourceRange.lowerBound,
                    end: sourceRange.upperBound - shortfall
                ),
            ])
        }
    }

    func testLeadingShortfallRemainsStrictWithAcceptedTrailingShortfall() {
        for leadingShortfall in [0.05 + 1 / sampleRate, 0.232104] {
            assertDiscontinuous([
                makeBuffer(
                    start: sourceRange.lowerBound + leadingShortfall,
                    end: sourceRange.upperBound - 0.232104
                ),
            ])
        }
    }

    func testInternalGapRemainsStrictWithAcceptedTrailingShortfall() {
        for gap in [0.05 + 1 / sampleRate, 0.232104] {
            let middle = sourceRange.lowerBound + 90
            assertDiscontinuous([
                makeBuffer(start: sourceRange.lowerBound, end: middle),
                makeBuffer(start: middle + gap, end: sourceRange.upperBound - 0.232104),
            ])
        }
    }

    func testExplicitDiscontinuityRemainsRejected() {
        let middle = sourceRange.lowerBound + 90
        assertDiscontinuous([
            makeBuffer(start: sourceRange.lowerBound, end: middle),
            makeBuffer(
                start: middle, end: sourceRange.upperBound - 0.232104,
                discontinuity: true
            ),
        ])
    }

    func testTrailingToleranceDoesNotDiscardAvailableTailOrItsDiscontinuity() throws {
        let tailStart = sourceRange.upperBound - 0.2
        let first = makeBuffer(start: sourceRange.lowerBound, end: tailStart)
        let tail = makeBuffer(start: tailStart, end: sourceRange.upperBound)
        let artifact = try RepeatedSegmentFingerprint.compute(
            audioBatch: batch([first, tail]), label: "complete-tail"
        )
        let expected = try RepeatedSegmentFingerprint.compute(
            monoSamples: samples(in: first) + samples(in: tail), label: "complete-tail",
            sourceStartSeconds: sourceRange.lowerBound
        )
        XCTAssertEqual(artifact, expected)

        assertDiscontinuous([
            first,
            HybridFingerprintAudioBuffer(
                buffer: tail.buffer, sourceTime: tail.sourceTime, discontinuity: true
            ),
        ])
    }

    private func assertDiscontinuous(
        _ buffers: [HybridFingerprintAudioBuffer],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try RepeatedSegmentFingerprint.compute(
                audioBatch: batch(buffers), label: "invalid-coverage"
            ),
            file: file, line: line
        ) { error in
            XCTAssertEqual(
                error as? RepeatedSegmentFingerprintError, .discontinuousAudio,
                file: file, line: line
            )
        }
    }

    private func batch(_ buffers: [HybridFingerprintAudioBuffer]) -> HybridFingerprintAudioBatch {
        HybridFingerprintAudioBatch(
            buffers: buffers, sourceRange: sourceRange, provider: .independentRemoteHLS,
            segmentCount: buffers.count, preparationSeconds: 0, cacheWaitSeconds: 0,
            decodeSeconds: 0
        )
    }

    private func makeBuffer(
        start: Double,
        end: Double,
        discontinuity: Bool = false
    ) -> HybridFingerprintAudioBuffer {
        let frameCount = Int(((end - start) * sampleRate).rounded(.down))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)
        )!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        var seed: UInt64 = 4_729
        for index in 0..<frameCount {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            buffer.floatChannelData![0][index] = Float(
                Double((seed >> 32) & 0xFFFF) / 65_535 - 0.5
            )
        }
        return HybridFingerprintAudioBuffer(
            buffer: buffer, sourceTime: start, discontinuity: discontinuity
        )
    }

    private func samples(in buffer: HybridFingerprintAudioBuffer) -> [Float] {
        Array(UnsafeBufferPointer(
            start: buffer.buffer.floatChannelData![0],
            count: Int(buffer.buffer.frameLength)
        ))
    }
}
