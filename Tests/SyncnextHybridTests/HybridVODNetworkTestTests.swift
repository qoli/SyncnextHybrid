import AVFoundation
import XCTest
@testable import SyncnextHybrid

final class HybridVODNetworkTestTests: XCTestCase {
    #if DEBUG
    func testFourVariantsReachVODLoadOptionsAndLeaveLiveUnchanged() throws {
        for variant in HybridVODNetworkTestVariant.allCases {
            var request = try HybridPlaybackRequest(url: URL(string: "https://fixture.invalid/media")!)
            request.vodNetworkTestVariant = variant
            let vod = HybridPlaybackPlan.make(
                request: request, externalSubtitles: [],
                admission: .hlsVODHEVCMPEGTS(duration: 30, evidence: .standardStreamType(0x24))
            )
            XCTAssertEqual(vod.options.progressiveSegmentDelivery, variant.usesProgressiveDelivery)
            XCTAssertFalse(vod.options.autoplay)
            let live = HybridPlaybackPlan.make(request: request, externalSubtitles: [], admission: .hlsLive)
            XCTAssertTrue(live.options.isLive)
            XCTAssertTrue(live.options.nativeRemoteHLS)
            XCTAssertFalse(live.options.progressiveSegmentDelivery)
            XCTAssertFalse(live.options.autoplay)
        }
        let ordinary = try HybridPlaybackRequest(url: URL(string: "https://fixture.invalid/media")!)
        XCTAssertNil(ordinary.vodNetworkTestVariant)
    }
    #endif

    func testAcceptedDefaultEnablesVODRemuxButLeavesNativeHLSAndLiveUnchanged() throws {
        let request = try HybridPlaybackRequest(url: URL(string: "https://fixture.invalid/media")!)
        let remux = HybridPlaybackPlan.make(
            request: request, externalSubtitles: [],
            admission: .hlsVODHEVCMPEGTS(duration: 30, evidence: .standardStreamType(0x24))
        )
        XCTAssertTrue(remux.options.progressiveSegmentDelivery)
        XCTAssertFalse(remux.options.autoplay)
        for admission: HybridRemoteSourceAdmission in [.hlsVOD, .hlsLive] {
            let native = HybridPlaybackPlan.make(request: request, externalSubtitles: [], admission: admission)
            XCTAssertTrue(native.options.nativeRemoteHLS)
            XCTAssertFalse(native.options.progressiveSegmentDelivery)
            XCTAssertFalse(native.options.autoplay)
        }
    }

    func testPlaybackRequestCarriesBufferPreference() throws {
        let url = URL(string: "https://fixture.invalid/media")!
        XCTAssertEqual(try HybridPlaybackRequest(url: url).preferredForwardBufferDuration, 12)
        let selected = try HybridPlaybackRequest(url: url, preferredForwardBufferDuration: 45)
        XCTAssertEqual(selected.preferredForwardBufferDuration, 45)
        let automatic = try HybridPlaybackRequest(url: url, preferredForwardBufferDuration: 0)
        XCTAssertEqual(automatic.preferredForwardBufferDuration, 0)
    }

    func testUnsafeBufferPreferencesAreRejectedBeforeSourceLoading() {
        let invalid: [Double] = [-1, .nan, .infinity, -.infinity,
                                 HybridVODBufferDuration.maximumSeconds.nextUp, 0.5, 6, 9.5, 60, 90, 600, 3600,
                                 .greatestFiniteMagnitude]
        for seconds in invalid {
            XCTAssertThrowsError(try HybridPlaybackRequest(
                url: URL(string: "https://fixture.invalid/media")!,
                preferredForwardBufferDuration: seconds
            )) { error in
                XCTAssertEqual(error as? HybridPlaybackError, .invalidForwardBufferDuration)
            }
        }
    }

    @MainActor
    func testChosenBufferPreferenceFollowsActualItemReplacement() async throws {
        for seconds: TimeInterval in [0, 4, 12, 30, 45] {
            let request = try HybridPlaybackRequest(
                url: URL(string: "https://fixture.invalid/media")!,
                preferredForwardBufferDuration: seconds
            )
            let first = AVPlayerItem(asset: AVMutableComposition())
            let player = AVPlayer(playerItem: first)
            let policy = HybridVODBufferPolicy(
                player: player,
                preferredForwardBufferDuration: request.preferredForwardBufferDuration,
                isEligible: { _ in true }
            )
            XCTAssertEqual(first.preferredForwardBufferDuration, seconds)
            let replacement = AVPlayerItem(asset: AVMutableComposition())
            replacement.preferredForwardBufferDuration = 7
            player.replaceCurrentItem(with: replacement)
            let deadline = Date().addingTimeInterval(2)
            while replacement.preferredForwardBufferDuration != seconds, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(replacement.preferredForwardBufferDuration, seconds)
            XCTAssertTrue(player.automaticallyWaitsToMinimizeStalling)
            XCTAssertEqual(player.rate, 0)
            withExtendedLifetime(policy) {}
        }
    }

    @MainActor
    func testAdaptivePolicyFollowsActualItemReplacement() async throws {
        let first = AVPlayerItem(asset: AVMutableComposition())
        first.preferredForwardBufferDuration = 12
        let player = AVPlayer(playerItem: first)
        let policy = HybridVODBufferPolicy(
            player: player, preferredForwardBufferDuration: 0, isEligible: { _ in true }
        )
        XCTAssertEqual(first.preferredForwardBufferDuration, 0)
        let second = AVPlayerItem(asset: AVMutableComposition())
        second.preferredForwardBufferDuration = 12
        player.replaceCurrentItem(with: second)
        let deadline = Date().addingTimeInterval(2)
        while second.preferredForwardBufferDuration != 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(second.preferredForwardBufferDuration, 0)
        XCTAssertTrue(player.automaticallyWaitsToMinimizeStalling)
        XCTAssertEqual(player.rate, 0, "Applying a preference must not start playback")
        withExtendedLifetime(policy) {}
    }

    @MainActor
    func testOrdinaryVODKeepsTwelveSecondsAfterItemReplacement() async throws {
        let first = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: first)
        let policy = HybridVODBufferPolicy(player: player, isEligible: { _ in true })
        XCTAssertEqual(first.preferredForwardBufferDuration, 12)
        let replacement = AVPlayerItem(asset: AVMutableComposition())
        player.replaceCurrentItem(with: replacement)
        let deadline = Date().addingTimeInterval(2)
        while replacement.preferredForwardBufferDuration != 12, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(replacement.preferredForwardBufferDuration, 12)
        XCTAssertTrue(player.automaticallyWaitsToMinimizeStalling)
        XCTAssertEqual(player.rate, 0)
        withExtendedLifetime(policy) {}
    }

    @MainActor
    func testIneligibleLiveOrNonLoopbackPlayerIsUntouched() {
        let item = AVPlayerItem(asset: AVMutableComposition())
        item.preferredForwardBufferDuration = 7
        let player = AVPlayer(playerItem: item)
        let policy = HybridVODBufferPolicy(player: player, isEligible: { _ in false })
        XCTAssertEqual(item.preferredForwardBufferDuration, 7)
        XCTAssertTrue(player.automaticallyWaitsToMinimizeStalling)
        XCTAssertEqual(player.rate, 0)
        withExtendedLifetime(policy) {}
    }
}
