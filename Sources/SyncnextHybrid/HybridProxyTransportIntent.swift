import Foundation

struct HybridProxyNavigation: Equatable {
    enum Origin: Equatable {
        case avKit
        case programmatic
    }

    let generation: UInt64
    let oldTime: Double
    let targetTime: Double
    let origin: Origin
    let intent: HybridPlaybackSeekIntent

    init(
        generation: UInt64,
        oldTime: Double,
        targetTime: Double,
        origin: Origin = .avKit,
        intent: HybridPlaybackSeekIntent = .position
    ) {
        self.generation = generation
        self.oldTime = oldTime
        self.targetTime = targetTime
        self.origin = origin
        self.intent = intent
    }

    var distance: Double {
        abs(targetTime - oldTime)
    }
}
