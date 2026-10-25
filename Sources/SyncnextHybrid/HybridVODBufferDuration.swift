import Foundation

/// The supported forward-buffer preference. Zero delegates buffering to AVPlayer.
/// Only the supported choices may reach a player: long targets can cause
/// system memory pressure even while this process still has memory headroom.
public enum HybridVODBufferDuration {
    public static let defaultSeconds: TimeInterval = 12
    public static let maximumSeconds: TimeInterval = 45
    public static let choices: [TimeInterval] = [0, 4, 12, 30, 45]

    public static func isSupported(_ seconds: TimeInterval) -> Bool {
        choices.contains(seconds)
    }
}
