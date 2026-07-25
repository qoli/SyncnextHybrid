import Foundation

enum SmokePolicy {
    static let maximumSessionReadinessSeconds = 30.0
    static let minimumStartupProgressSeconds = 2.0
    static let minimumPostSeekProgressSeconds = 2.0
    static let maximumZeroProgressSeconds = 60.5
    static let seekLandingToleranceSeconds = 1.0
    static let minimumInitialTimeSeconds = -0.25
    static let readinessDiagnosticCheckpointsSeconds = [5.0, 15.0, 30.0]
    static let diagnosticCheckpointsSeconds = [15.0, 30.0, 45.0, 60.5]

    static func validateDuration(
        _ duration: Double,
        seekSeconds: Double
    ) throws {
        guard duration.isFinite, duration > 0 else {
            throw SmokeFailure.nonFiniteDuration
        }
        let requiredDuration =
            seekSeconds
            + minimumPostSeekProgressSeconds
            + seekLandingToleranceSeconds
        guard duration > requiredDuration else {
            throw SmokeFailure.mediaTooShortForSeek(
                duration: duration,
                requiredDuration: requiredDuration
            )
        }
    }

    static func validateInitialTime(_ currentTime: Double) throws {
        guard currentTime.isFinite,
              currentTime >= minimumInitialTimeSeconds else {
            throw SmokeFailure.invalidMediaTime(currentTime)
        }
    }

    static func progress(
        from baseline: Double,
        to currentTime: Double
    ) throws -> Double {
        guard baseline.isFinite,
              currentTime.isFinite else {
            throw SmokeFailure.invalidMediaTime(currentTime)
        }
        return currentTime - baseline
    }

    static func validateSeekLanding(
        target: Double,
        actual: Double
    ) throws {
        guard actual.isFinite else {
            throw SmokeFailure.invalidMediaTime(actual)
        }
        let error = abs(actual - target)
        guard error <= seekLandingToleranceSeconds else {
            throw SmokeFailure.seekLandingMismatch(
                target: target,
                actual: actual,
                tolerance: seekLandingToleranceSeconds
            )
        }
    }
}

enum SmokeFailure: Error, Sendable, LocalizedError {
    case aetherInitializationFailed(String)
    case aetherSourceLoadFailed(String)
    case aetherVideoRequired(width: Int32, height: Int32)
    case aetherBackendUnavailable(String)
    case aetherPresentationChanged
    case sessionReadinessTimeout(
        phase: String,
        duration: Double,
        timeout: Double
    )
    case nonFiniteDuration
    case mediaTooShortForSeek(
        duration: Double,
        requiredDuration: Double
    )
    case invalidMediaTime(Double)
    case controllerBindingChanged
    case unexpectedRoute(expected: String, actual: String)
    case routeChanged(expected: String, actual: String)
    case playerFailed(String)
    case endedBeforeProgress(stage: String)
    case noMediaProgress(
        stage: String,
        baseline: Double,
        currentTime: Double,
        timeout: Double
    )
    case seekLandingMismatch(
        target: Double,
        actual: Double,
        tolerance: Double
    )

    var code: String {
        switch self {
        case .aetherInitializationFailed:
            "aether_initialization_failed"
        case .aetherSourceLoadFailed:
            "aether_source_load_failed"
        case .aetherVideoRequired:
            "aether_video_required"
        case .aetherBackendUnavailable:
            "aether_backend_unavailable"
        case .aetherPresentationChanged:
            "aether_presentation_changed"
        case .sessionReadinessTimeout:
            "session_readiness_timeout"
        case .nonFiniteDuration:
            "non_finite_duration"
        case .mediaTooShortForSeek:
            "media_too_short_for_seek"
        case .invalidMediaTime:
            "invalid_media_time"
        case .controllerBindingChanged:
            "controller_binding_changed"
        case .unexpectedRoute:
            "unexpected_route"
        case .routeChanged:
            "route_changed"
        case .playerFailed:
            "player_failed"
        case .endedBeforeProgress:
            "ended_before_progress"
        case .noMediaProgress:
            "no_media_progress"
        case .seekLandingMismatch:
            "seek_landing_mismatch"
        }
    }

    var errorDescription: String? {
        switch self {
        case .aetherInitializationFailed(let message):
            "AetherEngine initialization failed: \(message)"
        case .aetherSourceLoadFailed(let message):
            "AetherEngine source load failed: \(message)"
        case .aetherVideoRequired(let width, let height):
            "AetherEngine baseline requires video, but the source dimensions are \(width)x\(height)"
        case .aetherBackendUnavailable(let backend):
            "AetherEngine did not select a playable video backend: \(backend)"
        case .aetherPresentationChanged:
            "The active AetherEngine presentation changed during the smoke run"
        case .sessionReadinessTimeout(
            let phase,
            let duration,
            let timeout
        ):
            "Playback did not reach a paused finite VOD snapshot within \(timeout)s (phase \(phase), duration \(duration))"
        case .nonFiniteDuration:
            "Playback did not publish a finite positive VOD duration"
        case .mediaTooShortForSeek(
            let duration,
            let requiredDuration
        ):
            "Media duration \(duration) is not greater than the required smoke duration \(requiredDuration)"
        case .invalidMediaTime(let currentTime):
            "Playback published invalid media time \(currentTime)"
        case .controllerBindingChanged:
            "AVPlayerViewController is not bound to session.avPlayer"
        case .unexpectedRoute(let expected, let actual):
            "Hybrid selected route \(actual), expected \(expected)"
        case .routeChanged(let expected, let actual):
            "Hybrid route changed from \(expected) to \(actual)"
        case .playerFailed(let message):
            "Playback entered a typed failure: \(message)"
        case .endedBeforeProgress(let stage):
            "Playback ended before satisfying \(stage) progress"
        case .noMediaProgress(
            let stage,
            let baseline,
            let currentTime,
            let timeout
        ):
            "\(stage) made no media progress within \(timeout)s (baseline \(baseline), current \(currentTime))"
        case .seekLandingMismatch(
            let target,
            let actual,
            let tolerance
        ):
            "Seek landed at \(actual), expected \(target) ± \(tolerance)s"
        }
    }
}
