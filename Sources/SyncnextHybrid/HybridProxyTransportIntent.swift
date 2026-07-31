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

    init(
        generation: UInt64,
        oldTime: Double,
        targetTime: Double,
        origin: Origin = .avKit
    ) {
        self.generation = generation
        self.oldTime = oldTime
        self.targetTime = targetTime
        self.origin = origin
    }

    var distance: Double {
        abs(targetTime - oldTime)
    }
}
