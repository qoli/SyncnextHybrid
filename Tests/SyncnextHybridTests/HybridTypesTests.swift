import AVFAudio
import XCTest
@testable import SyncnextHybrid

final class HybridTypesTests: XCTestCase {
    func testFingerprintRequestPreservesExplicitDeadline() {
        let request = HybridFingerprintAudioRequest(
            audioSelectionRevision: 11,
            sourceRange: 0..<180,
            deadlineSeconds: 75
        )

        XCTAssertEqual(request.audioSelectionRevision, 11)
        XCTAssertEqual(request.sourceRange, 0..<180)
        XCTAssertEqual(request.deadlineSeconds, 75)
    }

    func testAudioAnalysisRequestPreservesSelectionRevisionAndRange() {
        let request = HybridAudioAnalysisRequest(
            audioSelectionRevision: 11,
            sourceRange: 0..<350
        )

        XCTAssertEqual(request.audioSelectionRevision, 11)
        XCTAssertEqual(request.sourceRange, 0..<350)
    }

    func testNativeHLSSelectionWithoutFFmpegTrackIDIsAdmitted() throws {
        let request = HybridAudioAnalysisRequest(
            audioSelectionRevision: 11,
            sourceRange: 0..<350
        )
        let snapshot = HybridPlaybackSnapshot(
            phase: .playing,
            route: .nativeAVPlayer,
            currentTime: 0,
            duration: 1_400,
            rate: 1,
            audioSelectionRevision: 11,
            selectedAudioTrackID: nil,
            selectedSubtitleTrackID: nil,
            audioTracks: [],
            subtitleTracks: []
        )

        XCTAssertNoThrow(
            try HybridAudioAnalysisSelectionGate.validate(
                request: request,
                sessionRevision: 11,
                snapshot: snapshot
            )
        )
    }

    func testStaleAudioSelectionRevisionIsRejected() {
        let request = HybridAudioAnalysisRequest(
            audioSelectionRevision: 10,
            sourceRange: 0..<350
        )
        let snapshot = HybridPlaybackSnapshot(
            phase: .playing,
            route: .nativeAVPlayer,
            currentTime: 0,
            duration: 1_400,
            rate: 1,
            audioSelectionRevision: 11,
            selectedAudioTrackID: nil,
            selectedSubtitleTrackID: nil,
            audioTracks: [],
            subtitleTracks: []
        )

        XCTAssertThrowsError(
            try HybridAudioAnalysisSelectionGate.validate(
                request: request,
                sessionRevision: 11,
                snapshot: snapshot
            )
        ) { error in
            XCTAssertEqual(
                error as? HybridAudioAnalysisError,
                .audioSelectionChanged
            )
        }
    }

    func testPlaybackRequestRejectsInvalidInitialPosition() {
        XCTAssertThrowsError(
            try HybridPlaybackRequest(
                url: URL(string: "https://example.com/movie.mkv")!,
                initialPosition: -.infinity
            )
        ) { error in
            XCTAssertEqual(
                error as? HybridPlaybackError,
                .invalidInitialPosition
            )
        }
    }

    func testAnalysisFormatIsFixedMonoFloat48kNonInterleaved() {
        let format = HybridAudioAnalysisFormat.pcm
        XCTAssertEqual(format.sampleRate, 48_000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertFalse(format.isInterleaved)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
    }

    func testAnalysisBufferUsesFixedSourceSampleAxis() throws {
        let format = HybridAudioAnalysisFormat.pcm
        let pcm = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)
        )
        pcm.frameLength = 480
        let buffer = HybridAudioAnalysisBuffer(
            pcm: pcm,
            sourceSamplePosition: 96_000,
            isDiscontinuous: false
        )
        XCTAssertEqual(buffer.sourceTime, 2, accuracy: 0.000_001)
    }
}
