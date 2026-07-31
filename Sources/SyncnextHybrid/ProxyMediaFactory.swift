#if os(tvOS)
import AVFoundation
import CryptoKit
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
        let assetData: Data
        do {
            assetData = try Data(contentsOf: url)
        } catch {
            throw HybridPlaybackError.proxyAssetUnavailable
        }
        let assetSHA256 = SHA256.hash(data: assetData)
            .map { String(format: "%02x", $0) }
            .joined()
        print(
            "SYNCNEXT_HYBRID_PROXY_ASSET "
                + "name=black-proxy.mp4 sha256=\(assetSHA256)"
        )

        let asset = AVURLAsset(url: url)
        async let videoTracks = asset.loadTracks(withMediaType: .video)
        async let audioTracks = asset.loadTracks(withMediaType: .audio)
        let sourceDuration = try await asset.load(.duration)
        guard let sourceVideoTrack = try await videoTracks.first,
              let sourceAudioTrack = try await audioTracks.first,
              sourceDuration.isNumeric,
              sourceDuration.seconds > 0 else {
            throw HybridPlaybackError.proxyAssetInvalid
        }

        let composition = AVMutableComposition()
        guard let targetVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ),
        let targetAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw HybridPlaybackError.proxyAssetInvalid
        }
        // A single sparse sample stretched across the whole title can pause
        // itself at rates above 1x on tvOS. Repeat the tiny bundled clip so
        // AVKit owns a dense, seekable transport timeline at every rate.
        let targetDuration = CMTime(
            seconds: max(1, duration),
            preferredTimescale: 600
        )
        var insertionTime = CMTime.zero
        while insertionTime < targetDuration {
            let remaining = CMTimeSubtract(targetDuration, insertionTime)
            let chunkDuration = CMTimeMinimum(sourceDuration, remaining)
            let sourceRange = CMTimeRange(
                start: .zero,
                duration: chunkDuration
            )
            try targetVideoTrack.insertTimeRange(
                sourceRange,
                of: sourceVideoTrack,
                at: insertionTime
            )
            try targetAudioTrack.insertTimeRange(
                sourceRange,
                of: sourceAudioTrack,
                at: insertionTime
            )
            insertionTime = CMTimeAdd(insertionTime, chunkDuration)
        }
        print(
            "SYNCNEXT_HYBRID_PROXY_TIMELINE "
                + "requestedDuration=\(duration) "
                + "compositionDuration=\(composition.duration.seconds)"
        )

        let item = AVPlayerItem(asset: composition)
        let videoItemTracks = item.tracks.filter {
            $0.assetTrack?.mediaType == .video
        }
        for videoItemTrack in videoItemTracks {
            videoItemTrack.isEnabled = false
        }
        print(
            "SYNCNEXT_HYBRID_PROXY_VIDEO_TRACK "
                + "count=\(videoItemTracks.count) "
                + "enabled=\(videoItemTracks.contains { $0.isEnabled })"
        )
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        let readinessDeadline =
            ProcessInfo.processInfo.systemUptime + 5
        while item.status == .unknown,
              ProcessInfo.processInfo.systemUptime < readinessDeadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard item.status == .readyToPlay else {
            throw HybridPlaybackError.proxyAssetInvalid
        }
        return player
    }
}
#endif
