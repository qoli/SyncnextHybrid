import Foundation

enum HybridAVKitNavigationPolicy {
    static func requiresLinearPlayback(
        preserving hostRequirement: Bool,
        route: HybridPlaybackRoute,
        sourceIsConfirmedHLS: Bool
    ) -> Bool {
        hostRequirement
            || (route == .avKitProxy && sourceIsConfirmedHLS)
    }
}
