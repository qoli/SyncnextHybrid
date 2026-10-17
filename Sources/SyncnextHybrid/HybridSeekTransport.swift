import AetherEngine
import Foundation

public enum HybridPlaybackSeekIntent: Sendable, Equatable {
    /// Position the playhead; reaching the end parks playback without finishing it.
    case position
    /// Skip a detected segment; a segment reaching the media end finishes playback.
    case automaticSkip
}

enum HybridSeekEndDisposition: Equatable {
    case none
    case parked
    case completed
}

enum HybridSeekEndPolicy {
    // Compatibility with the pinned AetherEngine #164 park/replay contract.
    // This is its existing end tolerance, not an offset applied to seek targets.
    static let tolerance: Double = 0.5

    static func target(
        requested: Double,
        duration: Double,
        isLive: Bool,
        intent: HybridPlaybackSeekIntent
    ) throws -> Double {
        let bounded = try HybridSeekTargetPolicy.target(
            requested: requested,
            duration: duration
        )
        return disposition(
            target: bounded,
            duration: duration,
            isLive: isLive,
            intent: intent
        ) == .completed ? duration : bounded
    }

    static func isAtEnd(
        time: Double,
        duration: Double,
        isLive: Bool
    ) -> Bool {
        !isLive && duration.isFinite && duration > 0
            && time >= duration - tolerance
    }

    static func disposition(
        target: Double,
        duration: Double,
        isLive: Bool,
        intent: HybridPlaybackSeekIntent
    ) -> HybridSeekEndDisposition {
        guard isAtEnd(time: target, duration: duration, isLive: isLive) else {
            return .none
        }
        return intent == .automaticSkip ? .completed : .parked
    }
}

@MainActor
protocol HybridSeekEngine: AnyObject {
    var currentTime: Double { get }
    var duration: Double { get }
    var isLive: Bool { get }
    var hybridHasEnded: Bool { get }
    func seek(to seconds: Double) async
    func reloadAtCurrentPosition() async throws
    func pause()
    func play()
    func setRate(_ rate: Float)
}

extension AetherEngine: HybridSeekEngine {
    var hybridHasEnded: Bool { state == .ended }
}

/// Executes the renderer half of a navigation. The owner accepts the landing
/// on its authoritative timeline before this code restores transport. Keeping
/// this boundary outside the tvOS presentation also makes the real dispatch
/// order testable without an AVPlayerViewController.
@MainActor
enum HybridSeekTransport {
    enum Completion {
        case superseded
        case preserveTransport
        case restoreRate(Float)
    }

    @discardableResult
    static func perform(
        engine: any HybridSeekEngine,
        target: Double,
        intent: HybridPlaybackSeekIntent,
        isCurrent: () -> Bool,
        acceptLanding: (HybridSeekEndDisposition) -> Completion
    ) async throws -> HybridSeekEndDisposition? {
        guard isCurrent() else { return nil }
        // Aether's organic .ended is terminal. An explicit new navigation
        // reopens that same session before positioning it; it never asks
        // play() to revive or implicitly rewind a finished renderer.
        if engine.hybridHasEnded {
            try await engine.reloadAtCurrentPosition()
            guard isCurrent() else { return nil }
        }
        try Task.checkCancellation()
        await engine.seek(to: target)
        try Task.checkCancellation()
        guard isCurrent() else { return nil }

        var disposition = HybridSeekEndPolicy.disposition(
            target: target,
            duration: engine.duration,
            isLive: engine.isLive,
            intent: intent
        )
        if disposition == .none,
           HybridSeekEndPolicy.isAtEnd(
               time: engine.currentTime,
               duration: engine.duration,
               isLive: engine.isLive
           ) {
            // AVPlayer's measured landing can be nearer the end than the
            // requested target. It must not turn the resume into a rewind.
            // Only an intentional tail skip is allowed to finish the item.
            disposition = .parked
        }
        if disposition != .none {
            // pause() also stops the actual host; Aether's parked state alone
            // does not authorize a play press, which would rewind to zero.
            engine.pause()
        }
        let completion = acceptLanding(disposition)
        guard isCurrent() else { return nil }
        switch completion {
        case .superseded:
            return nil
        case .preserveTransport:
            break
        case .restoreRate(let rate):
            if rate == 0 {
                engine.pause()
            } else if disposition == .none {
                // A paused speed change only seeds Aether's resume rate (#730).
                // Seed it before Play, and never send Play to a tail landing.
                engine.setRate(rate)
                engine.play()
            }
        }
        return disposition
    }
}
