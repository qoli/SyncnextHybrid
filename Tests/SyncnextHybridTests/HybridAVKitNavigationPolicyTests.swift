import XCTest
@testable import SyncnextHybrid

final class HybridAVKitNavigationPolicyTests: XCTestCase {
    func testHLSProxyRequiresLinearPlayback() {
        XCTAssertTrue(
            HybridAVKitNavigationPolicy.requiresLinearPlayback(
                preserving: false,
                route: .avKitProxy,
                sourceIsConfirmedHLS: true
            )
        )
    }

    func testNonHLSProxyRemainsNavigable() {
        XCTAssertFalse(
            HybridAVKitNavigationPolicy.requiresLinearPlayback(
                preserving: false,
                route: .avKitProxy,
                sourceIsConfirmedHLS: false
            )
        )
    }

    func testNativeHLSRemainsNavigable() {
        XCTAssertFalse(
            HybridAVKitNavigationPolicy.requiresLinearPlayback(
                preserving: false,
                route: .nativeAVPlayer,
                sourceIsConfirmedHLS: true
            )
        )
    }

    func testHostLinearPlaybackRequirementIsPreserved() {
        XCTAssertTrue(
            HybridAVKitNavigationPolicy.requiresLinearPlayback(
                preserving: true,
                route: .nativeAVPlayer,
                sourceIsConfirmedHLS: false
            )
        )
    }
}
