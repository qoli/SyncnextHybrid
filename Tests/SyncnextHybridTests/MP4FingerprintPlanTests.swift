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
            XCTAssertFalse(plan.allowsAudioExtraction)
            let tail = 2_501.416..<2_801.416
            XCTAssertFalse(plan.isReady(for: tail, playbackTime: 180, isSeeking: false))
            XCTAssertFalse(plan.isReady(for: tail, playbackTime: tail.lowerBound, isSeeking: true))
            XCTAssertTrue(plan.isReady(for: tail, playbackTime: tail.lowerBound, isSeeking: false))
            XCTAssertTrue(HybridFingerprintAudioProviderResolver.requiresPlaybackCache(
                admission: admission, region: .back, containerFormat: mp4
            ), "A cache acquisition failure must not reopen the rate-limited source")
        }
    }

    func testSoftwareMP4TailUsesBoundedReaderBeforePlaybackArrives() throws {
        for admission in [HybridRemoteSourceAdmission.aetherDefault(.confirmedNonHLS), .aetherDefault(.requestFailed)] {
            let plan = try HybridFingerprintAudioProviderResolver.resolve(
                admission: admission, region: .back, containerFormat: mp4, usesSoftwareVideo: true
            )
            XCTAssertEqual(plan.provider, .independentDemuxer)
            XCTAssertEqual(plan.timing, .immediate)
            XCTAssertTrue(plan.isReady(for: 1_161..<1_461, playbackTime: 0, isSeeking: false))
            XCTAssertFalse(plan.allowsAudioExtraction, "A failed software tail must not start another extractor")
            XCTAssertFalse(HybridFingerprintAudioProviderResolver.requiresPlaybackCache(
                admission: admission, region: .back, containerFormat: mp4, usesSoftwareVideo: true
            ))
        }
    }

    func testSoftwareVideoDoesNotChangeUnknownOrEBMLCachePolicy() throws {
        for format: String? in [nil, "matroska,webm"] {
            let plan = try HybridFingerprintAudioProviderResolver.resolve(
                admission: .aetherDefault(.requestFailed), region: .back,
                containerFormat: format, usesSoftwareVideo: true
            )
            XCTAssertEqual(plan.provider, .segmentCache)
            XCTAssertFalse(plan.allowsAudioExtraction)
        }
        let intro = try HybridFingerprintAudioProviderResolver.resolve(
            admission: .aetherDefault(.confirmedNonHLS), region: .front,
            containerFormat: mp4, usesSoftwareVideo: true
        )
        XCTAssertEqual(intro.provider, .independentDemuxer)
        XCTAssertTrue(intro.allowsAudioExtraction)
    }

    func testMP4FrontPCMRequestKeepsExactRangeProviderAndFailurePolicy() throws {
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

    func testOnlyStandardLoopbackMP4IntroArtifactUsesShortenedWindow() {
        func cachedRange(
            _ range: Range<Double> = 0..<300, region: HybridFingerprintAudioRegion = .front,
            admission: HybridRemoteSourceAdmission = .aetherDefault(.confirmedNonHLS),
            format: String? = "mov,mp4,m4a", loopback: Bool = true
        ) -> Range<Double>? {
            HybridFingerprintAudioProviderResolver.cachedMP4IntroRange(
                for: HybridFingerprintAudioRequest(sourceRange: range, region: region),
                admission: admission, containerFormat: format, hasLoopbackVideo: loopback
            )
        }

        XCTAssertEqual(cachedRange(), 2..<300)
        XCTAssertNil(cachedRange(0..<2))
        XCTAssertNil(cachedRange(0..<180))
        XCTAssertNil(cachedRange(30..<180))
        XCTAssertNil(cachedRange(region: .back))
        XCTAssertNil(cachedRange(format: nil))
        XCTAssertNil(cachedRange(format: "matroska,webm"))
        XCTAssertNil(cachedRange(loopback: false))
        XCTAssertNil(cachedRange(admission: .hlsVOD))
        XCTAssertEqual(cachedRange(admission: .aetherDefault(.requestFailed)), 2..<300)
        XCTAssertNil(cachedRange(admission: .aetherDefault(.requestFailed), format: nil))
        XCTAssertNil(cachedRange(admission: .aetherDefault(.nonHTTPSource)))
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
