#if os(tvOS)
import AVFoundation
import Foundation

enum ProxyMediaFactory {
    @MainActor
    static func makePlayer(duration: Double) async throws -> AVPlayer {
        guard let url = Bundle.module.url(
            forResource: "black-proxy",
            withExtension: "mp4"
        ) else {
            throw HybridPlaybackError.proxyAssetUnavailable
        }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let sourceDuration = try await asset.load(.duration)
        guard let sourceTrack = tracks.first,
              sourceDuration.isNumeric,
              sourceDuration.seconds > 0 else {
            throw HybridPlaybackError.proxyAssetInvalid
        }

        let composition = AVMutableComposition()
        guard let targetTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw HybridPlaybackError.proxyAssetInvalid
        }
        let sourceRange = CMTimeRange(
            start: .zero,
            duration: sourceDuration
        )
        try targetTrack.insertTimeRange(
            sourceRange,
            of: sourceTrack,
            at: .zero
        )
        targetTrack.scaleTimeRange(
            sourceRange,
            toDuration: CMTime(
                seconds: max(1, duration),
                preferredTimescale: 600
            )
        )

        let item = AVPlayerItem(asset: composition)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        return player
    }
}
#endif
