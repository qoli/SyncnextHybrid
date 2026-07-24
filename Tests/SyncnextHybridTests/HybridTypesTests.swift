import AVFAudio
import XCTest
@testable import SyncnextHybrid

final class HybridTypesTests: XCTestCase {
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
