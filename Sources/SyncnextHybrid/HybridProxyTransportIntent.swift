import Foundation

struct HybridProxyNavigation: Equatable {
    let generation: UInt64
    let oldTime: Double
    let targetTime: Double

    var distance: Double {
        abs(targetTime - oldTime)
    }
}

/// Tracks the latest AVKit transport intent while an asynchronous Aether seek
/// is in flight. AVKit may publish play or pause after delivering its
/// user-navigation delegate callback; the latest command must win when the
/// seek completes.
struct HybridProxyTransportIntent {
    private(set) var desiredRate: Float = 0
    private(set) var activeNavigation: HybridProxyNavigation?
    private var nextNavigationGeneration: UInt64 = 0

    var isNavigating: Bool {
        activeNavigation != nil
    }

    /// Returns true when the rate can be applied to Aether immediately.
    @discardableResult
    mutating func recordDesiredRate(_ rate: Float) -> Bool {
        desiredRate = rate
        return activeNavigation == nil
    }

    mutating func beginUserNavigation(
        from oldTime: Double,
        to targetTime: Double,
        duration: Double,
        resumeRate: Float
    ) -> HybridProxyNavigation? {
        guard oldTime.isFinite,
              targetTime.isFinite,
              duration.isFinite,
              duration > 0 else {
            return nil
        }

        nextNavigationGeneration &+= 1
        let navigation = HybridProxyNavigation(
            generation: nextNavigationGeneration,
            oldTime: max(0, min(oldTime, duration)),
            targetTime: max(0, min(targetTime, duration))
        )
        activeNavigation = navigation
        desiredRate = max(resumeRate, 1)
        return navigation
    }

    /// Returns the latest desired rate only for the winning navigation.
    mutating func completeUserNavigation(
        _ navigation: HybridProxyNavigation
    ) -> Float? {
        guard activeNavigation?.generation
                == navigation.generation else {
            return nil
        }
        activeNavigation = nil
        return desiredRate
    }

    mutating func cancelUserNavigation() {
        activeNavigation = nil
    }
}
