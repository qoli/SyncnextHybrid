import XCTest
@testable import HybridSmokePlayer

final class SmokePolicyTests: XCTestCase {
    func testFiniteDurationMustContainSeekAndPostSeekBudget()
        throws
    {
        XCTAssertNoThrow(
            try SmokePolicy.validateDuration(
                300,
                seekSeconds: 150
            )
        )

        XCTAssertThrowsError(
            try SmokePolicy.validateDuration(
                12,
                seekSeconds: 10
            )
        ) { error in
            guard let failure = error as? SmokeFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
            guard case .mediaTooShortForSeek = failure else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testNativePrerollIsValidButEarlierTimeFails() {
        XCTAssertNoThrow(
            try SmokePolicy.validateInitialTime(-0.083)
        )
        XCTAssertThrowsError(
            try SmokePolicy.validateInitialTime(-0.251)
        )
    }

    func testSeekLandingUsesExplicitTolerance() {
        XCTAssertNoThrow(
            try SmokePolicy.validateSeekLanding(
                target: 150,
                actual: 150.75
            )
        )
        XCTAssertThrowsError(
            try SmokePolicy.validateSeekLanding(
                target: 150,
                actual: 151.01
            )
        ) { error in
            guard let failure = error as? SmokeFailure else {
                return XCTFail("Unexpected error: \(error)")
            }
            guard case .seekLandingMismatch = failure else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testProgressUsesAuthoritativeMediaTime() throws {
        XCTAssertEqual(
            try SmokePolicy.progress(from: -0.083, to: 2.0),
            2.083,
            accuracy: 0.0001
        )
        XCTAssertThrowsError(
            try SmokePolicy.progress(
                from: 0,
                to: .nan
            )
        )
    }
}
