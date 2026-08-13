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
    private static let leadingCoverageTolerance = 0.05
    /// Container duration can exceed the selected audio track because of codec
    /// padding or edit-list rounding. This remains negligible for a 180-second
    /// fingerprint window and is emitted as a structured diagnostic below.
    private static let trailingCoverageTolerance = 0.25

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
                        scope: .boundedRange,
                        session: hlsSession
                    )
                } else {
                    prepared = try await HybridHLSVODAudioSource.prepare(
                        request: request,
                        range: range,
                        scope: .boundedRange
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
        let timelineOffset = preparedHLSCursor?.timelineOffset ?? 0
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
                    timelineOrigin: timelineOrigin,
                    timelineOffset: timelineOffset
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
        timelineOrigin: Double,
        timelineOffset: Double
    ) -> ClipResult {
        let frameCount = Int(chunk.buffer.frameLength)
        guard frameCount > 0 else {
            return .skip
        }
        let sampleRate = HybridAudioAnalysisFormat.sampleRate
        let chunkStart =
            chunk.ptsSeconds - timelineOrigin + timelineOffset
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
        let coversStart =
            first.sourceTime <= range.lowerBound + leadingCoverageTolerance
        let trailingShortfall = max(0, range.upperBound - lastEnd)
        let coversEnd = trailingShortfall <= trailingCoverageTolerance
        guard coversStart, coversEnd else {
            let requestedStart = String(
                format: "%.6f",
                range.lowerBound
            )
            let requestedEnd = String(
                format: "%.6f",
                range.upperBound
            )
            let actualStart = String(
                format: "%.6f",
                first.sourceTime
            )
            let actualEnd = String(format: "%.6f", lastEnd)
            HybridDiagnosticEmitter.emit(
                "SYNCNEXT_HYBRID_FINGERPRINT_COVERAGE "
                    + "result=incomplete "
                    + "requestedStart=\(requestedStart) "
                    + "requestedEnd=\(requestedEnd) "
                    + "actualStart=\(actualStart) "
                    + "actualEnd=\(actualEnd) "
                    + "buffers=\(buffers.count)"
            )
            throw HybridFingerprintAudioError.incompleteRange
        }
        if trailingShortfall > leadingCoverageTolerance {
            let requestedEnd = String(format: "%.6f", range.upperBound)
            let actualEnd = String(format: "%.6f", lastEnd)
            let acceptedShortfall = String(
                format: "%.6f",
                trailingShortfall
            )
            let acceptedTolerance = String(
                format: "%.6f",
                trailingCoverageTolerance
            )
            HybridDiagnosticEmitter.emit(
                "SYNCNEXT_HYBRID_FINGERPRINT_COVERAGE "
                    + "result=trailing-shortfall-accepted "
                    + "requestedEnd=\(requestedEnd) "
                    + "actualEnd=\(actualEnd) "
                    + "shortfall=\(acceptedShortfall) "
                    + "tolerance=\(acceptedTolerance) "
                    + "buffers=\(buffers.count)"
            )
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
