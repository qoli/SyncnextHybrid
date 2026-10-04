import AVFAudio
import XCTest
@testable import SyncnextHybrid

final class HybridTypesTests: XCTestCase {
    func testFingerprintRequestPreservesExplicitDeadline() {
        let request = HybridFingerprintAudioRequest(
            sourceRange: 0..<180,
            deadlineSeconds: 75
        )

        XCTAssertEqual(request.sourceRange, 0..<180)
        XCTAssertEqual(request.deadlineSeconds, 75)
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

}
