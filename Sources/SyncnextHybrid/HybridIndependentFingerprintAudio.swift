import AetherEngine
import AVFAudio
import Foundation
import Libavcodec

enum HybridIndependentFingerprintAudioSource: Sendable {
    case remoteHLS(AetherRemoteHLSAudioRequest)
    case demuxer(
        url: URL,
        httpHeaders: [String: String],
        selectedTrack: TrackInfo?
    )

    var provider: HybridFingerprintAudioProvider {
        switch self {
        case .remoteHLS:
            .independentRemoteHLS
        case .demuxer:
            .independentDemuxer
        }
    }
}

enum HybridIndependentFingerprintAudio {
    private static let coverageTolerance = 0.05

    static func decode(
        source: HybridIndependentFingerprintAudioSource,
        range: Range<Double>,
        hlsSession: URLSession? = nil
    ) async throws -> HybridFingerprintAudioBatch {
        let duration = range.upperBound - range.lowerBound
        guard range.lowerBound.isFinite,
              range.upperBound.isFinite,
              range.lowerBound >= 0,
              duration > 0,
              duration <= 180 else {
            throw HybridFingerprintAudioError.invalidRange
        }

        let preparationStartedAt = ProcessInfo.processInfo.systemUptime
        let demuxer = Demuxer()
        var preparedHLSCursor: HybridHLSPreparedAudioCursor?
        defer {
            demuxer.close()
            preparedHLSCursor?.close()
        }

        let selected: TrackInfo
        do {
            switch source {
            case .remoteHLS(let request):
                let prepared: HybridHLSPreparedAudioCursor
                if let hlsSession {
                    prepared = try await HybridHLSVODAudioSource.prepare(
                        request: request,
                        range: range,
                        session: hlsSession
                    )
                } else {
                    prepared = try await HybridHLSVODAudioSource.prepare(
                        request: request,
                        range: range
                    )
                }
                preparedHLSCursor = prepared
                try Task.checkCancellation()
                try demuxer.openIndependent(
                    reader: prepared.reader,
                    formatHint: prepared.formatHint
                )
                selected = try HybridHLSVODAudioSource.resolveSelectedTrack(
                    from: demuxer.audioTrackInfos(),
                    prepared: prepared
                )
            case .demuxer(let url, let httpHeaders, let expectedTrack):
                try demuxer.openIndependent(
                    url: url,
                    extraHeaders: httpHeaders
                )
                selected = try resolveSelectedTrack(
                    from: demuxer.audioTrackInfos(),
                    expected: expectedTrack
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HybridAudioAnalysisError {
            throw mapAnalysisError(error)
        } catch let error as HybridFingerprintAudioError {
            throw error
        } catch {
            throw HybridFingerprintAudioError.sourceUnavailable
        }
        let preparationSeconds =
            ProcessInfo.processInfo.systemUptime - preparationStartedAt

        guard let stream = demuxer.stream(at: Int32(selected.id)) else {
            throw HybridFingerprintAudioError.audioTrackUnavailable
        }
        let timelineOrigin = demuxer.formatStartTimeSeconds
        if range.lowerBound > 0,
           preparedHLSCursor == nil,
           !demuxer.seek(to: range.lowerBound + timelineOrigin) {
            throw HybridFingerprintAudioError.sourceUnavailable
        }
        demuxer.discardAllStreamsExcept([Int32(selected.id)])

        let decoder = HybridFFmpegAudioDecoder()
        defer { decoder.close() }
        do {
            try decoder.open(stream: stream)
        } catch {
            throw HybridFingerprintAudioError.sourceUnavailable
        }

        let decodeStartedAt = ProcessInfo.processInfo.systemUptime
        var buffers: [HybridFingerprintAudioBuffer] = []
        var continuity = HybridAudioContinuityTracker(
            requestedStartPosition: Int64(
                (
                    range.lowerBound
                        * HybridAudioAnalysisFormat.sampleRate
                ).rounded()
            )
        )
        var reachedRangeEnd = false

        func append(_ chunks: [HybridDecodedAudioChunk]) throws {
            for chunk in chunks {
                let result = clip(
                    chunk,
                    to: range,
                    timelineOrigin: timelineOrigin
                )
                switch result {
                case .skip:
                    continue
                case .finish:
                    reachedRangeEnd = true
                    return
                case .emit(let buffer, let sourcePosition):
                    let discontinuity = continuity.consume(
                        sourcePosition: sourcePosition,
                        frameLength: buffer.frameLength
                    )
                    buffers.append(
                        HybridFingerprintAudioBuffer(
                            buffer: buffer,
                            sourceTime:
                                Double(sourcePosition)
                                / HybridAudioAnalysisFormat.sampleRate,
                            discontinuity: discontinuity
                        )
                    )
                }
            }
        }

        do {
            while !reachedRangeEnd {
                try Task.checkCancellation()
                guard let packet = try demuxer.readPacket() else {
                    break
                }
                var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
                defer { av_packet_free(&packetToFree) }
                guard packet.pointee.stream_index == selected.id else {
                    continue
                }
                try append(try decoder.decode(packet: packet))
            }
            if !reachedRangeEnd {
                try append(try decoder.drain())
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HybridFingerprintAudioError.sourceUnavailable
        }

        try validateCoverage(buffers, range: range)
        return HybridFingerprintAudioBatch(
            buffers: buffers,
            sourceRange: range,
            provider: source.provider,
            segmentCount: preparedHLSCursor?.segmentCount ?? 0,
            preparationSeconds: preparationSeconds,
            cacheWaitSeconds: 0,
            decodeSeconds:
                ProcessInfo.processInfo.systemUptime - decodeStartedAt
        )
    }

    private static func resolveSelectedTrack(
        from tracks: [TrackInfo],
        expected: TrackInfo?
    ) throws -> TrackInfo {
        if let expected {
            guard let actual = tracks.first(where: { $0.id == expected.id }),
                  actual.codec == expected.codec,
                  actual.language == expected.language,
                  actual.channels == expected.channels else {
                throw HybridFingerprintAudioError.audioTrackUnavailable
            }
            return actual
        }
        if tracks.count == 1 {
            return tracks[0]
        }
        let defaults = tracks.filter(\.isDefault)
        guard defaults.count == 1 else {
            throw HybridFingerprintAudioError.audioTrackUnavailable
        }
        return defaults[0]
    }

    private enum ClipResult {
        case skip
        case finish
        case emit(AVAudioPCMBuffer, Int64)
    }

    private static func clip(
        _ chunk: HybridDecodedAudioChunk,
        to range: Range<Double>,
        timelineOrigin: Double
    ) -> ClipResult {
        let frameCount = Int(chunk.buffer.frameLength)
        guard frameCount > 0 else {
            return .skip
        }
        let sampleRate = HybridAudioAnalysisFormat.sampleRate
        let chunkStart = chunk.ptsSeconds - timelineOrigin
        let chunkEnd = chunkStart + Double(frameCount) / sampleRate
        if chunkEnd <= range.lowerBound {
            return .skip
        }
        if chunkStart >= range.upperBound {
            return .finish
        }
        let startFrame = max(
            0,
            Int(ceil((range.lowerBound - chunkStart) * sampleRate))
        )
        let endFrame = min(
            frameCount,
            Int(floor((range.upperBound - chunkStart) * sampleRate))
        )
        guard endFrame > startFrame,
              let pcm = AVAudioPCMBuffer(
                pcmFormat: HybridAudioAnalysisFormat.pcm,
                frameCapacity: AVAudioFrameCount(endFrame - startFrame)
              ),
              let input = chunk.buffer.floatChannelData?[0],
              let output = pcm.floatChannelData?[0] else {
            return .skip
        }
        pcm.frameLength = AVAudioFrameCount(endFrame - startFrame)
        output.update(
            from: input.advanced(by: startFrame),
            count: endFrame - startFrame
        )
        let sourcePosition =
            Int64((chunkStart * sampleRate).rounded()) + Int64(startFrame)
        return .emit(pcm, sourcePosition)
    }

    private static func validateCoverage(
        _ buffers: [HybridFingerprintAudioBuffer],
        range: Range<Double>
    ) throws {
        guard let first = buffers.first,
              let last = buffers.last else {
            throw HybridFingerprintAudioError.incompleteRange
        }
        let lastEnd = last.sourceTime
            + Double(last.buffer.frameLength) / last.buffer.format.sampleRate
        guard first.sourceTime <= range.lowerBound + coverageTolerance,
              lastEnd >= range.upperBound - coverageTolerance else {
            throw HybridFingerprintAudioError.incompleteRange
        }
        if buffers.dropFirst().contains(where: \.discontinuity) {
            throw HybridFingerprintAudioError.discontinuousRange
        }
    }

    private static func mapAnalysisError(
        _ error: HybridAudioAnalysisError
    ) -> HybridFingerprintAudioError {
        switch error {
        case .invalidRange:
            .invalidRange
        case .liveOrDVRUnsupported:
            .liveOrDVRUnsupported
        case .selectedAudioTrackUnavailable,
             .sourceTrackChanged:
            .audioTrackUnavailable
        case .audioSelectionChanged:
            .audioSelectionChanged
        case .cancelled:
            .sessionChanged
        default:
            .sourceUnavailable
        }
    }
}
