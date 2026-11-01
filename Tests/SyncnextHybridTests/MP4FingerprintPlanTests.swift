import XCTest
@testable import SyncnextHybrid

final class MP4FingerprintPlanTests: XCTestCase {
    private let mp4 = "mov,mp4,m4a,3gp,3g2,mj2"

    func testLoadedMP4TailUsesPlaybackCacheAfterPlaybackArrives() throws {
        for admission in [HybridRemoteSourceAdmission.aetherDefault(.confirmedNonHLS), .aetherDefault(.requestFailed)] {
            let plan = try HybridFingerprintAudioProviderResolver.resolve(
                admission: admission, region: .back, containerFormat: mp4
            )
            XCTAssertEqual(plan.provider, .segmentCache)
            XCTAssertEqual(plan.timing, .whenPlaybackReachesRange)
            let tail = 2_621.416..<2_801.416
            XCTAssertFalse(plan.isReady(for: tail, playbackTime: 180, isSeeking: false))
            XCTAssertFalse(plan.isReady(for: tail, playbackTime: tail.lowerBound, isSeeking: true))
            XCTAssertTrue(plan.isReady(for: tail, playbackTime: tail.lowerBound, isSeeking: false))
            XCTAssertTrue(HybridFingerprintAudioProviderResolver.requiresPlaybackCache(
                admission: admission, region: .back, containerFormat: mp4
            ), "A cache acquisition failure must not reopen the rate-limited source")
        }
    }

    func testMP4FrontKeepsExistingProviderAndFailurePolicy() throws {
        let admission = HybridRemoteSourceAdmission.aetherDefault(.confirmedNonHLS)
        let plan = try HybridFingerprintAudioProviderResolver.resolve(
            admission: admission, region: .front, containerFormat: mp4
        )
        XCTAssertEqual(plan.provider, .independentDemuxer)
        XCTAssertEqual(plan.timing, .immediate)
        XCTAssertFalse(HybridFingerprintAudioProviderResolver.requiresPlaybackCache(
            admission: admission, region: .front, containerFormat: mp4
        ))
    }

    func testUnknownAndOtherContainersDoNotSelectMP4Policy() throws {
        for format: String? in [nil, "", "mpegts", "matroska,webm", "notmp4"] {
            let plan = try HybridFingerprintAudioProviderResolver.resolve(
                admission: .aetherDefault(.confirmedNonHLS), region: .back, containerFormat: format
            )
            XCTAssertEqual(plan.provider, .independentDemuxer, format ?? "unknown")
        }
    }

    func testHLSDoesNotUseLoadedMP4TailPolicy() throws {
        let plan = try HybridFingerprintAudioProviderResolver.resolve(
            admission: .hlsVOD, region: .back, containerFormat: mp4
        )
        XCTAssertEqual(plan.provider, .independentRemoteHLS)
        XCTAssertEqual(plan.timing, .immediate)
        XCTAssertThrowsError(try HybridFingerprintAudioProviderResolver.resolve(
            admission: .hlsLive, region: .back, containerFormat: mp4
        ))
    }
}
