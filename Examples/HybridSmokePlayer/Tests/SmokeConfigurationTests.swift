import XCTest
@testable import HybridSmokePlayer

final class SmokeConfigurationTests: XCTestCase {
    func testOptionalPlaybackComponentsAreExplicitAndValidated() throws {
        let environment = [
            SmokeConfiguration.modeEnvironmentKey: "hybridAVKit",
            SmokeConfiguration.urlEnvironmentKey: "https://example.test/movie.mkv",
        ]
        let defaults = try XCTUnwrap(SmokeConfiguration.fromEnvironment(environment))
        XCTAssertEqual(defaults.objectAudioRendering, .off)
        XCTAssertFalse(defaults.preferDualLayerDolbyVision)
        XCTAssertNil(defaults.thumbnailSeconds)

        let explicit = try XCTUnwrap(SmokeConfiguration.fromEnvironment(environment.merging([
            SmokeConfiguration.objectAudioEnvironmentKey: "7.1.4",
            SmokeConfiguration.dualLayerEnvironmentKey: "true",
            SmokeConfiguration.thumbnailEnvironmentKey: "2",
        ], uniquingKeysWith: { _, value in value })))
        XCTAssertEqual(explicit.objectAudioRendering, .apac(.l714))
        XCTAssertTrue(explicit.preferDualLayerDolbyVision)
        XCTAssertEqual(explicit.thumbnailSeconds, 2)

        for (key, value) in [
            (SmokeConfiguration.objectAudioEnvironmentKey, "7.1"),
            (SmokeConfiguration.dualLayerEnvironmentKey, "yes"),
            (SmokeConfiguration.thumbnailEnvironmentKey, "nan"),
        ] {
            XCTAssertThrowsError(try SmokeConfiguration.fromEnvironment(
                environment.merging([key: value], uniquingKeysWith: { _, value in value })
            ))
        }
    }

    func testPersistentHTTP1AndSustainedPlaybackAreExplicitOptIns() throws {
        let environment = [
            SmokeConfiguration.modeEnvironmentKey: "hybridAVKit",
            SmokeConfiguration.urlEnvironmentKey: "https://example.test/video.m3u8",
        ]
        let defaults = try XCTUnwrap(SmokeConfiguration.fromEnvironment(environment))
        XCTAssertFalse(defaults.heldSourceConnection)
        XCTAssertEqual(defaults.observationSeconds, 0)
        let explicit = try XCTUnwrap(SmokeConfiguration.fromEnvironment(
            environment.merging([
                SmokeConfiguration.heldSourceConnectionEnvironmentKey: "true",
                SmokeConfiguration.observationSecondsEnvironmentKey: "120",
            ], uniquingKeysWith: { _, value in value })
        ))
        XCTAssertTrue(explicit.heldSourceConnection)
        XCTAssertEqual(explicit.observationSeconds, 120)
        for invalid in ["yes", "1", ""] {
            XCTAssertThrowsError(try SmokeConfiguration.fromEnvironment(
                environment.merging([SmokeConfiguration.heldSourceConnectionEnvironmentKey: invalid], uniquingKeysWith: { _, value in value })
            ))
        }
        for invalid in ["nan", "inf", "-1", "0"] {
            XCTAssertThrowsError(try SmokeConfiguration.fromEnvironment(
                environment.merging([SmokeConfiguration.observationSecondsEnvironmentKey: invalid], uniquingKeysWith: { _, value in value })
            ))
        }
    }

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
        XCTAssertEqual(configuration.scenario, .playbackSeek)
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

    func testTailScenarioPreservesTheExactRegressionTarget() throws {
        let configuration = try XCTUnwrap(
            SmokeConfiguration.fromEnvironment([
                SmokeConfiguration.modeEnvironmentKey: "hybridAVKit",
                SmokeConfiguration.scenarioEnvironmentKey: "tailSeekReplay",
                SmokeConfiguration.urlEnvironmentKey: "https://example.test/video.m3u8",
                SmokeConfiguration.seekEnvironmentKey: "1343.34",
                SmokeConfiguration.preseekEnvironmentKey: "1314",
                SmokeConfiguration.expectedRouteEnvironmentKey: "avKitProxy",
            ])
        )
        XCTAssertEqual(configuration.scenario, .tailSeekReplay)
        XCTAssertEqual(configuration.seekSeconds, 1343.34)
        XCTAssertEqual(configuration.preseekSeconds, 1314)
    }

    func testTailScenarioRejectsDirectAetherMode() {
        XCTAssertThrowsError(
            try SmokeConfiguration.fromEnvironment([
                SmokeConfiguration.modeEnvironmentKey: "aetherEngine",
                SmokeConfiguration.scenarioEnvironmentKey: "tailSeekReplay",
                SmokeConfiguration.urlEnvironmentKey: "https://example.test/video.m3u8",
            ])
        ) { error in
            XCTAssertEqual(
                error as? SmokeConfigurationError,
                .tailScenarioRequiresHybrid
            )
        }
    }

    func testUnknownScenarioFailsInsteadOfRunningTheOrdinarySmoke() {
        XCTAssertThrowsError(
            try SmokeConfiguration.fromEnvironment([
                SmokeConfiguration.modeEnvironmentKey: "hybridAVKit",
                SmokeConfiguration.scenarioEnvironmentKey: "tail",
                SmokeConfiguration.urlEnvironmentKey: "https://example.test/video.m3u8",
            ])
        ) { error in
            XCTAssertEqual(error as? SmokeConfigurationError, .invalidScenario("tail"))
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
