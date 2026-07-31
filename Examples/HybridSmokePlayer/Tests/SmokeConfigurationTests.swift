import XCTest
@testable import HybridSmokePlayer

final class SmokeConfigurationTests: XCTestCase {
    func testNoSmokeEnvironmentSelectsInteractiveMode() throws {
        XCTAssertNil(
            try SmokeConfiguration.fromEnvironment([
                "UNRELATED": "value",
            ])
        )
    }

    func testPartialAutomationConfigurationFailsWithoutURL() {
        XCTAssertThrowsError(
            try SmokeConfiguration.fromEnvironment([
                SmokeConfiguration.seekEnvironmentKey: "10",
            ])
        ) { error in
            XCTAssertEqual(
                error as? SmokeConfigurationError,
                .missingURL
            )
        }
    }

    func testAutomationFailsWithoutExplicitMode() {
        XCTAssertThrowsError(
            try SmokeConfiguration.fromEnvironment([
                SmokeConfiguration.urlEnvironmentKey:
                    "https://example.test/video.mp4",
            ])
        ) { error in
            XCTAssertEqual(
                error as? SmokeConfigurationError,
                .missingMode
            )
        }
    }

    func testAutomationParsesExplicitSourceHeadersAndRoute() throws {
        let configuration = try XCTUnwrap(
            SmokeConfiguration.fromEnvironment([
                SmokeConfiguration.modeEnvironmentKey:
                    SmokePlaybackMode.hybridAVKit.rawValue,
                SmokeConfiguration.urlEnvironmentKey:
                    "http://example.test/video.mkv?token=secret",
                SmokeConfiguration.headersEnvironmentKey:
                    #"{"Authorization":"Bearer secret"}"#,
                SmokeConfiguration.seekEnvironmentKey: "12.5",
                SmokeConfiguration.rateEnvironmentKey: "2.0",
                SmokeConfiguration.expectedRouteEnvironmentKey:
                    "avKitProxy",
            ])
        )

        XCTAssertEqual(configuration.mode, .hybridAVKit)
        XCTAssertEqual(configuration.seekSeconds, 12.5)
        XCTAssertEqual(configuration.playbackRate, 2.0)
        XCTAssertEqual(
            configuration.httpHeaders,
            ["Authorization": "Bearer secret"]
        )
        XCTAssertEqual(
            configuration.expectedRoute,
            .avKitProxy
        )
        XCTAssertFalse(configuration.displaySource.contains("token"))
        XCTAssertFalse(configuration.displaySource.contains("secret"))
    }

    func testHeaderValuesMustBeStrings() {
        XCTAssertThrowsError(
            try SmokeConfiguration.interactive(
                mode: .aetherEngine,
                rawURL: "https://example.test/video.mp4",
                rawHeaders: #"{"X-Retry":3}"#,
                rawSeekSeconds: "10"
            )
        ) { error in
            XCTAssertEqual(
                error as? SmokeConfigurationError,
                .invalidHeadersJSON
            )
        }
    }

    func testRelativeURLFailsExplicitly() {
        XCTAssertThrowsError(
            try SmokeConfiguration.interactive(
                mode: .aetherEngine,
                rawURL: "video.mp4",
                rawHeaders: "",
                rawSeekSeconds: "10"
            )
        ) { error in
            XCTAssertEqual(
                error as? SmokeConfigurationError,
                .invalidURL
            )
        }
    }

    func testRedactorRemovesURLAndHeaderValues() throws {
        let configuration = try SmokeConfiguration.interactive(
            mode: .aetherEngine,
            rawURL: "https://example.test/video.mp4?token=secret",
            rawHeaders: #"{"Authorization":"Bearer abc"}"#,
            rawSeekSeconds: "10"
        )
        let redactor = SmokeRedactor(configuration: configuration)
        let sanitized = redactor.sanitize(
            "https://example.test/video.mp4?token=secret "
                + "Bearer abc"
        )

        XCTAssertEqual(sanitized, "<redacted> <redacted>")
    }

    func testInvalidAutomationModeFailsExplicitly() {
        XCTAssertThrowsError(
            try SmokeConfiguration.fromEnvironment([
                SmokeConfiguration.modeEnvironmentKey: "automatic",
                SmokeConfiguration.urlEnvironmentKey:
                    "https://example.test/video.mp4",
            ])
        ) { error in
            XCTAssertEqual(
                error as? SmokeConfigurationError,
                .invalidMode("automatic")
            )
        }
    }

    func testInvalidPlaybackRateFailsExplicitly() {
        XCTAssertThrowsError(
            try SmokeConfiguration.fromEnvironment([
                SmokeConfiguration.modeEnvironmentKey:
                    SmokePlaybackMode.hybridAVKit.rawValue,
                SmokeConfiguration.urlEnvironmentKey:
                    "https://example.test/video.mp4",
                SmokeConfiguration.rateEnvironmentKey: "0",
            ])
        ) { error in
            XCTAssertEqual(
                error as? SmokeConfigurationError,
                .invalidPlaybackRate
            )
        }
    }

    func testAetherModeRejectsHybridRouteAssertion() {
        XCTAssertThrowsError(
            try SmokeConfiguration.fromEnvironment([
                SmokeConfiguration.modeEnvironmentKey:
                    SmokePlaybackMode.aetherEngine.rawValue,
                SmokeConfiguration.urlEnvironmentKey:
                    "https://example.test/video.mp4",
                SmokeConfiguration.expectedRouteEnvironmentKey:
                    SmokeExpectedRoute.avKitProxy.rawValue,
            ])
        ) { error in
            XCTAssertEqual(
                error as? SmokeConfigurationError,
                .expectedRouteRequiresHybrid
            )
        }
    }

    @MainActor
    func testInteractiveViewModelDefaultsToAetherBaseline() {
        XCTAssertEqual(
            SmokeViewModel().selectedMode,
            .aetherEngine
        )
    }
}
