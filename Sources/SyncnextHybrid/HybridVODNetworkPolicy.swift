import AetherEngine
import AVFoundation
import Foundation

#if DEBUG
/// Explicit, per-session experiments. Absent from Release and never persisted.
public enum HybridVODNetworkTestVariant: String, CaseIterable, Sendable {
    case baseline
    case adaptive
    case progressive
    case combined

    public var usesAdaptiveBuffer: Bool {
        self == .adaptive || self == .combined
    }

    public var usesProgressiveDelivery: Bool {
        self == .progressive || self == .combined
    }

    func configure(_ options: inout LoadOptions, isLive: Bool) {
        guard !isLive else { return }
        options.progressiveSegmentDelivery = usesProgressiveDelivery
    }
}
#endif

/// Follows eligible VOD item replacements while leaving playback and recovery
/// decisions with the existing session. The caller supplies the forward-buffer
/// preference (twelve seconds by default); zero lets AVPlayer decide automatically.
@MainActor
final class HybridVODBufferPolicy {
    private(set) weak var player: AVPlayer?
    private let preferredForwardBufferDuration: TimeInterval
    private let diagnosticSessionID: String?
    private var itemRevision: UInt64 = 0
    private let isEligible: @MainActor (AVPlayer) -> Bool
    private var observation: NSKeyValueObservation?

    init(
        player: AVPlayer,
        preferredForwardBufferDuration: TimeInterval = 12,
        diagnosticSessionID: String? = nil,
        isEligible: @escaping @MainActor (AVPlayer) -> Bool
    ) {
        self.player = player
        self.preferredForwardBufferDuration = preferredForwardBufferDuration
        self.diagnosticSessionID = diagnosticSessionID
        self.isEligible = isEligible
        apply()
        observation = player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.apply()
            }
        }
    }

    private func apply() {
        guard let player, isEligible(player), let item = player.currentItem else { return }
        let previous = item.preferredForwardBufferDuration
        item.preferredForwardBufferDuration = preferredForwardBufferDuration
        itemRevision &+= 1
        if let diagnosticSessionID {
            HybridDiagnosticEmitter.emit(
                "SYNCNEXT_HYBRID_VOD_BUFFER session=\(diagnosticSessionID) event=applied"
                    + " itemRevision=\(itemRevision) previousPreference=\(previous)"
                    + " preferredForwardBufferDuration=\(item.preferredForwardBufferDuration)"
                    + " automaticallyWaits=\(player.automaticallyWaitsToMinimizeStalling)"
            )
        }
    }
}
