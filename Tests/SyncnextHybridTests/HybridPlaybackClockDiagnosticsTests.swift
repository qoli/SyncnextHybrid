import AetherEngine
import Foundation
import Synchronization
import XCTest
@testable import SyncnextHybrid

final class HybridPlaybackClockDiagnosticsTests: XCTestCase {
    func testUnknownAndInvalidClocksDoNotBecomeZeroOrSuccess() {
        XCTAssertEqual(HybridPlaybackClockDiagnostics.number(nil), "unavailable")
        XCTAssertEqual(HybridPlaybackClockDiagnostics.number(.nan), "nan")
        XCTAssertEqual(HybridPlaybackClockDiagnostics.number(.infinity), "inf")
        XCTAssertEqual(HybridPlaybackClockDiagnostics.number(350.70016921), "350.700")
        XCTAssertEqual(HybridPlaybackClockDiagnostics.ageMilliseconds(since: nil, now: 100), "unavailable")
        XCTAssertEqual(HybridPlaybackClockDiagnostics.ageMilliseconds(since: 50, now: 100), "50000.000")
        XCTAssertEqual(HybridPlaybackClockDiagnostics.phase(.failed("https://private.invalid/?token=secret")), "failed")
    }

    func testSDKRebuildMessagesKeepOnlyTheNumericWitnesses() {
        let begin = "[AetherEngine] reload begin: audioStream=3 resumeAt=350.70s embeddedSub=2 sidecar=/private/subtitle.ass"
        XCTAssertEqual(HybridAudioReloadDiagnostics.safeFields(begin), "event=begin audioStream=3.000 resumeAt=350.700")
        XCTAssertEqual(HybridAudioReloadDiagnostics.safeFields("[AetherEngine] reload: stopInternal done (2ms)"), "event=stop-done")
        XCTAssertEqual(HybridAudioReloadDiagnostics.safeFields("[AetherEngine] reload: loadNative enter audio=3 resumeAt=350.70s"),
                       "event=load-enter backend=native audioStream=3.000 resumeAt=350.700")
        XCTAssertEqual(HybridAudioReloadDiagnostics.safeFields("[AetherEngine] selectAudioTrack reload failed: https://private.invalid/?token=secret"), "event=failed")
        XCTAssertNil(HybridAudioReloadDiagnostics.safeFields("[NativeAVPlayerHost] unrelated https://private.invalid"))
    }

    @MainActor
    func testSDKChildTaskKeepsSessionAndOperationThroughTheHTTPLogNotification() async {
        HybridAudioReloadDiagnostics.install()
        let messages = Mutex<[String]>([])
        let observation = NotificationCenter.default.addObserver(forName: .syncnextHybridDiagnostic, object: nil, queue: nil) { notification in
            guard let line = notification.userInfo?[HybridDiagnosticNotification.messageKey] as? String,
                  line.hasPrefix("ENGINE_REBUILD ") else { return }
            messages.withLock { $0.append(line) }
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        let context = HybridAudioReloadDiagnostics.Context(session: "fixture-session", operation: "fixture-audio-switch")
        await HybridAudioReloadDiagnostics.$context.withValue(context) {
            // The SDK schedules selectAudioTrack's actual rebuild in a child Task.
            await Task { @MainActor in
                EngineLog.emit("[AetherEngine] reload begin: audioStream=3 resumeAt=350.70s sidecar=/private/not-for-logs.ass")
                EngineLog.emit("[AetherEngine] reload: stopInternal done (2ms)")
                EngineLog.emit("[AetherEngine] selectAudioTrack reload failed: https://private.invalid/?token=secret")
            }.value
        }
        let captured = messages.withLock { $0 }
        XCTAssertEqual(captured.count, 3)
        XCTAssertTrue(captured.allSatisfy { $0.contains("session=fixture-session originOperation=fixture-audio-switch") && $0.contains("uptimeMs=") })
        XCTAssertTrue(captured[0].contains("resumeAt=350.700"))
        XCTAssertFalse(captured.joined().contains("https://"))
        XCTAssertFalse(captured.joined().contains("/private/"))
        XCTAssertFalse(captured.joined().contains("token="))
        EngineLog.emit("[AetherEngine] reload: stopInternal done (outside context)")
        XCTAssertEqual(messages.withLock { $0.count }, 3)
    }
}
