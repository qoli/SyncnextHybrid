import AetherEngine
import XCTest
@testable import SyncnextHybrid

final class CacheBackedFingerprintWindowTests: XCTestCase {
    @MainActor
    func testAppWindowsPassSDKValidationBeforeCacheAvailability() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        let window = HybridFingerprintAudioRequest.maximumDurationSeconds
        let duration = 1_433.1
        let ranges = [0..<window, (duration - window)..<duration, 2..<window]

        for range in ranges {
            do {
                _ = try await engine.fingerprintAudio(in: range)
                XCTFail("An unloaded engine has no loopback cache")
            } catch let error as AetherFingerprintAudioError {
                XCTAssertEqual(error, .loopbackVODRequired,
                               "The SDK must admit the App's 300-second window: \(range)")
            }
        }
    }

    @MainActor
    func testSDKStillRejectsRequestsBeyondTheSharedLimit() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        do {
            _ = try await engine.fingerprintAudio(
                in: 0..<(HybridFingerprintAudioRequest.maximumDurationSeconds + 1)
            )
            XCTFail("A request above the analysis limit must fail")
        } catch let error as AetherFingerprintAudioError {
            XCTAssertEqual(error, .invalidRange)
        }
    }
}
