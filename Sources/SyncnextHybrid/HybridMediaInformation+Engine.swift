#if os(tvOS)
import AetherEngine
import AetherLibavcodec
import Foundation

extension HybridMediaInformation {
    @MainActor
    static func loaded(engine: AetherEngine, snapshot: HybridPlaybackSnapshot) -> Self {
        func positive<T: BinaryInteger>(_ value: T) -> T? { value > 0 ? value : nil }
        func positive(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        // TrackInfo can use decoder names (srt/dca); the API reports codec names (subrip/dts).
        func codecName(_ name: String) -> String {
            guard let decoder = avcodec_find_decoder_by_name(name) else { return name }
            return String(cString: avcodec_get_name(decoder.pointee.id))
        }
        func videoFormat(_ format: VideoStreamFormat?) -> VideoFormat {
            VideoFormat(profile: format?.profile, pixelFormat: format?.pixelFormat,
                        bitDepth: format?.bitDepth, colorPrimaries: format?.colorPrimaries,
                        transferFunction: format?.transfer, colorMatrix: format?.matrix, colorRange: format?.range)
        }
        func disposition(_ track: TrackInfo) -> Disposition {
            Disposition(isDefault: track.isDefault, isForced: track.isForced,
                        isHearingImpaired: track.isHearingImpaired, isCommentary: track.isCommentary)
        }
        let width = positive(Int(engine.sourceVideoWidth))
        let height = positive(Int(engine.sourceVideoHeight))
        let pixelAspect = width == nil ? nil : positive(engine.sourceVideoPixelAspectRatio)
        let hasVideo = width != nil || height != nil || engine.sourceVideoCodecName != nil
        let sourceDynamicRange = engine.sourceVideoFormat == .sdr && engine.sourceVideoStreamFormat?.transfer == nil
            ? nil : String(describing: engine.sourceVideoFormat)
        let video: Video? = hasVideo ? Video(
            codec: engine.sourceVideoCodecName, width: width, height: height,
            frameRate: positive(engine.sourceVideoFrameRate), bitrateBps: positive(engine.sourceVideoBitrate),
            pixelAspectRatio: pixelAspect,
            displayAspectRatio: width.flatMap { w in height.flatMap { h in pixelAspect.map { Double(w) * $0 / Double(h) } } },
            format: videoFormat(engine.sourceVideoStreamFormat), dynamicRange: sourceDynamicRange,
            dolbyVisionProfile: engine.sourceDVProfile
        ) : nil
        let audio = engine.audioTracks.map { track in
            AudioTrack(id: track.id, name: track.name, codec: codecName(track.codec),
                       profile: track.profile, language: track.language,
                       sampleRateHz: positive(track.sampleRate), channels: positive(track.channels),
                       channelLayout: track.channelLayout, bitsPerSample: positive(track.bitsPerSample),
                       sampleFormat: track.sampleFormat, bitrateBps: positive(track.bitrate),
                       atmosDetected: track.isAtmos, dtsXDetected: track.isDTSX,
                       disposition: disposition(track), selected: engine.activeAudioTrackIndex.map { $0 == track.id })
        }
        let subtitles = engine.subtitleTracks.map { track in
            SubtitleTrack(id: track.id, name: track.name, codec: codecName(track.codec), language: track.language,
                          disposition: disposition(track), isExternal: track.isExternal,
                          isNativelyRendered: track.isNativelyRenderedSubtitle,
                          selected: engine.activeSubtitleTrackIndex.map { $0 == track.id })
        }
        let isDisc = engine.selectedDiscTitle != nil
        let chapters = (isDisc ? engine.discChapters : engine.mediaChapters).map {
            Chapter(id: $0.id, title: $0.name, startSeconds: $0.startSeconds,
                    durationSeconds: $0.durationSeconds, timeline: isDisc ? "disc-title" : "playback")
        }
        let telemetry = engine.liveTelemetry.map { value in
            Telemetry(instantBitrateBps: positive(value.instantBitrateMbps).map { $0 * 1_000_000 },
                      averageBitrateBps: positive(value.averageBitrateMbps).map { $0 * 1_000_000 },
                      audioBridgeBitrateBps: positive(value.audioBridgeBitrateMbps).map { $0 * 1_000_000 },
                      networkThroughputBps: positive(value.networkThroughputMbps).map { $0 * 1_000_000 },
                      observedFrameRate: positive(value.observedFps), droppedFrameCount: value.droppedFrameCount,
                      forwardBufferSeconds: finite(value.forwardBufferSeconds),
                      displayCushionSeconds: finite(value.displayCushionSeconds), cachedBytes: value.cachedBytes,
                      readerWindowAheadBytes: value.readerWindowAheadBytes,
                      avSyncGapMilliseconds: finite(value.avSyncGapMs), sourceBytesFetched: value.demuxerBytesFetched)
        }
        return Self(
            format: Format(name: engine.sourceContainerFormat, durationSeconds: positive(engine.duration),
                           isLive: engine.isLive, title: engine.metadata?.title,
                           artist: engine.metadata?.artist, album: engine.metadata?.album),
            video: video, audioTracks: audio, subtitleTracks: subtitles, chapters: chapters,
            playback: Playback(route: String(describing: snapshot.route), videoRoute: engine.videoRoute.rawValue,
                               audioDelivery: engine.audioDelivery.rawValue,
                               videoDecoder: engine.activeVideoDecoder, audioDecoder: engine.activeAudioDecoder,
                               displayDynamicRange: hasVideo ? String(describing: engine.videoFormat) : nil,
                               dolbyVisionConversion: engine.dolbyVisionConversion.map { String(describing: $0) },
                               decodedVideoFormat: engine.decodedVideoFormat.map { videoFormat($0.frame) },
                               pixelBufferFormat: engine.decodedVideoFormat?.pixelBufferFormat,
                               selectedAudioTrackID: engine.activeAudioTrackIndex,
                               selectedSubtitleTrackID: engine.activeSubtitleTrackIndex, telemetry: telemetry)
        )
    }
}
#endif
