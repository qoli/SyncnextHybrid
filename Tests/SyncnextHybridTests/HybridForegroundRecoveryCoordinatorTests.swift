import XCTest
@testable import SyncnextHybrid

final class HybridForegroundRecoveryCoordinatorTests: XCTestCase {
    func testActiveWithoutBackgroundDoesNotBeginRecovery() {
        var coordinator = HybridForegroundRecoveryCoordinator()

        XCTAssertNil(coordinator.beginForegroundRecovery())
        XCTAssertEqual(coordinator.phase, .foreground)
    }

    func testBackgroundRecoveryPreservesPlayingRate() throws {
        var coordinator = HybridForegroundRecoveryCoordinator()
        let entered = try XCTUnwrap(
            coordinator.enterBackground(resumeRate: 1.5)
        )

        XCTAssertEqual(
            coordinator.phase,
            .backgrounded(entered)
        )
        let recovery = try XCTUnwrap(
            coordinator.beginForegroundRecovery()
        )
        XCTAssertEqual(recovery.resumeRate, 1.5)
        XCTAssertTrue(coordinator.complete(epoch: recovery.epoch))
        XCTAssertEqual(coordinator.phase, .foreground)
    }

    func testBackgroundRecoveryPreservesPausedIntent() throws {
        var coordinator = HybridForegroundRecoveryCoordinator()
        _ = coordinator.enterBackground(resumeRate: nil)

        let recovery = try XCTUnwrap(
            coordinator.beginForegroundRecovery()
        )
        XCTAssertNil(recovery.resumeRate)
    }

    func testDuplicateActiveDoesNotStartSecondRecovery() throws {
        var coordinator = HybridForegroundRecoveryCoordinator()
        _ = coordinator.enterBackground(resumeRate: 1)

        _ = try XCTUnwrap(coordinator.beginForegroundRecovery())
        XCTAssertNil(coordinator.beginForegroundRecovery())
    }

    func testNewBackgroundSupersedesInFlightRecovery() throws {
        var coordinator = HybridForegroundRecoveryCoordinator()
        _ = coordinator.enterBackground(resumeRate: 1)
        let first = try XCTUnwrap(
            coordinator.beginForegroundRecovery()
        )

        let second = try XCTUnwrap(
            coordinator.enterBackground(resumeRate: nil)
        )

        XCTAssertNotEqual(first.epoch, second.epoch)
        XCTAssertFalse(coordinator.complete(epoch: first.epoch))
        XCTAssertEqual(coordinator.phase, .backgrounded(second))
    }

    func testFailureIsTerminalForSameEpoch() throws {
        var coordinator = HybridForegroundRecoveryCoordinator()
        _ = coordinator.enterBackground(resumeRate: 1)
        let recovery = try XCTUnwrap(
            coordinator.beginForegroundRecovery()
        )

        XCTAssertTrue(coordinator.fail(epoch: recovery.epoch))
        XCTAssertEqual(coordinator.phase, .failed(recovery))
        XCTAssertNil(coordinator.beginForegroundRecovery())
    }

    func testStoppedCoordinatorRejectsLifecycleTransitions() {
        var coordinator = HybridForegroundRecoveryCoordinator()

        coordinator.stop()

        XCTAssertNil(coordinator.enterBackground(resumeRate: 1))
        XCTAssertNil(coordinator.beginForegroundRecovery())
        XCTAssertEqual(coordinator.phase, .stopped)
    }
}
