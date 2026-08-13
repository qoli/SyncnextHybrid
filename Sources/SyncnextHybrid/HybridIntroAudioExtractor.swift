import AetherEngine
import Foundation
import Libavcodec
import Libavformat
import Libavutil

public enum HybridIntroAudioExtractionError:
    Error,
    Sendable,
    Equatable
{
    case invalidDuration
    case sourceUnavailable
    case noAudioStream
    case unsupportedAudioCodec(String)
    case outputPreparationFailed
    case packetReadFailed
    case packetWriteFailed
    case emptyOutput
    case cancelled
}

public struct HybridIntroAudioArtifact:
    Sendable,
    Equatable
{
    public let url: URL
    public let sourceDuration: Double
    public let packetCount: Int
    public let byteCount: Int64
    public let elapsedSeconds: Double

    public init(
        url: URL,
        sourceDuration: Double,
        packetCount: Int,
        byteCount: Int64,
        elapsedSeconds: Double
    ) {
        self.url = url
        self.sourceDuration = sourceDuration
        self.packetCount = packetCount
        self.byteCount = byteCount
        self.elapsedSeconds = elapsedSeconds
    }
}

/// Immutable source facts for intro-audio extraction.
///
/// This value deliberately contains no playback session, AVPlayer, or
/// AetherEngine instance. Extraction owns a fresh demuxer and network cursor.
public struct HybridIntroAudioExtractionRequest:
    Sendable,
    Equatable
{
    public let url: URL
    public let httpHeaders: [String: String]
    public let sourceRange: Range<Double>
    public let outputURL: URL

    public var maximumDuration: Double {
        sourceRange.upperBound - sourceRange.lowerBound
    }

    public init(
        url: URL,
        httpHeaders: [String: String] = [:],
        maximumDuration: Double = 180,
        outputURL: URL
    ) {
        self.url = url
        self.httpHeaders = httpHeaders
        self.sourceRange = 0..<maximumDuration
        self.outputURL = outputURL
    }

    public init(
        url: URL,
        httpHeaders: [String: String] = [:],
        sourceRange: Range<Double>,
        outputURL: URL
    ) {
        self.url = url
        self.httpHeaders = httpHeaders
        self.sourceRange = sourceRange
        self.outputURL = outputURL
    }
}

private actor HybridIntroAudioArtifactGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation {
            waiters.append($0)
        }
    }

    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

public enum HybridIntroAudioExtractor {
    private static let artifactGate = HybridIntroAudioArtifactGate()

    public static func extract(
        request: HybridIntroAudioExtractionRequest
    ) async throws -> HybridIntroAudioArtifact {
        let maximumDuration = request.maximumDuration
        guard request.sourceRange.lowerBound.isFinite,
              request.sourceRange.upperBound.isFinite,
              request.sourceRange.lowerBound >= 0,
              maximumDuration.isFinite,
              maximumDuration > 0,
              maximumDuration <= 180 else {
            throw HybridIntroAudioExtractionError.invalidDuration
        }

        await artifactGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await extractExclusively(
                request: request,
                maximumDuration: maximumDuration,
                outputURL: request.outputURL
            )
            await artifactGate.release()
            return result
        } catch {
            await artifactGate.release()
            throw error
        }
    }

    private static func extractExclusively(
        request: HybridIntroAudioExtractionRequest,
        maximumDuration: Double,
        outputURL: URL
    ) async throws -> HybridIntroAudioArtifact {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let demuxer = Demuxer()
        var preparedHLSCursor: HybridHLSPreparedAudioCursor?
        defer {
            demuxer.close()
            preparedHLSCursor?.close()
        }

        do {
            let admission = try await
                HybridRemoteSourceAdmission.classify(
                    url: request.url,
                    httpHeaders: request.httpHeaders
                )
            switch admission {
            case .hlsVOD, .hlsVODPQOnlyMaster,
                 .hlsVODHEVCMPEGTS:
                let hlsRequest = AetherRemoteHLSAudioRequest(
                    url: request.url,
                    httpHeaders: request.httpHeaders,
                    selection: AetherRemoteHLSAudioSelection(
                        displayName: nil,
                        language: nil,
                        optionOrdinal: nil
                    )
                )
                let prepared = try await
                    HybridHLSVODAudioSource.prepare(
                        request: hlsRequest,
                        range: request.sourceRange
                    )
                preparedHLSCursor = prepared
                try Task.checkCancellation()
                try demuxer.openIndependent(
                    reader: prepared.reader,
                    formatHint: prepared.formatHint
                )
            case .hlsLive:
                throw HybridIntroAudioExtractionError.sourceUnavailable
            case .aetherDefault:
                try demuxer.openIndependent(
                    url: request.url,
                    extraHeaders: request.httpHeaders
                )
            }
        } catch is CancellationError {
            throw HybridIntroAudioExtractionError.cancelled
        } catch {
            throw HybridIntroAudioExtractionError.sourceUnavailable
        }

        let tracks = demuxer.audioTrackInfos()
        guard let selected = tracks.first(where: \.isDefault)
                ?? tracks.first,
              let inputStream = demuxer.stream(
                at: Int32(selected.id)
              ) else {
            throw HybridIntroAudioExtractionError.noAudioStream
        }
        guard selected.codec == "aac" else {
            throw HybridIntroAudioExtractionError
                .unsupportedAudioCodec(selected.codec)
        }
        let timelineOrigin = demuxer.formatStartTimeSeconds
        if request.sourceRange.lowerBound > 0,
           preparedHLSCursor == nil,
           !demuxer.seek(
               to: request.sourceRange.lowerBound + timelineOrigin
           ) {
            throw HybridIntroAudioExtractionError.sourceUnavailable
        }
        demuxer.discardAllStreamsExcept([Int32(selected.id)])

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            do {
                try fileManager.removeItem(at: outputURL)
            } catch {
                throw HybridIntroAudioExtractionError
                    .outputPreparationFailed
            }
        }

        var outputContext: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_alloc_output_context2(
            &outputContext,
            nil,
            "adts",
            outputURL.path
        ) >= 0,
        let outputContext else {
            throw HybridIntroAudioExtractionError.outputPreparationFailed
        }
        var outputIsOpen = false
        defer {
            if outputIsOpen {
                avio_closep(&outputContext.pointee.pb)
            }
            avformat_free_context(outputContext)
        }

        guard let outputStream = avformat_new_stream(
            outputContext,
            nil
        ), avcodec_parameters_copy(
            outputStream.pointee.codecpar,
            inputStream.pointee.codecpar
        ) >= 0 else {
            throw HybridIntroAudioExtractionError.outputPreparationFailed
        }
        outputStream.pointee.codecpar.pointee.codec_tag = 0
        outputStream.pointee.time_base = inputStream.pointee.time_base

        guard avio_open(
            &outputContext.pointee.pb,
            outputURL.path,
            AVIO_FLAG_WRITE
        ) >= 0 else {
            throw HybridIntroAudioExtractionError.outputPreparationFailed
        }
        outputIsOpen = true
        guard avformat_write_header(outputContext, nil) >= 0 else {
            throw HybridIntroAudioExtractionError.outputPreparationFailed
        }

        let inputTimeBase = inputStream.pointee.time_base
        var firstTimestamp: Int64?
        var sourceDuration = 0.0
        var packetCount = 0

        while true {
            try Task.checkCancellation()
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                throw HybridIntroAudioExtractionError.packetReadFailed
            }
            guard let packet else {
                break
            }
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            defer {
                av_packet_free(&packetToFree)
            }
            guard packet.pointee.stream_index == selected.id else {
                continue
            }

            let timestamp = packet.pointee.pts != Int64.min
                ? packet.pointee.pts
                : packet.pointee.dts
            if timestamp != Int64.min {
                if firstTimestamp == nil {
                    firstTimestamp = timestamp
                }
                if let firstTimestamp {
                    let endTimestamp =
                        timestamp - firstTimestamp
                            + max(packet.pointee.duration, 0)
                    sourceDuration = Double(endTimestamp)
                        * Double(inputTimeBase.num)
                        / Double(inputTimeBase.den)
                    if sourceDuration > maximumDuration + 0.001 {
                        break
                    }
                }
            }

            av_packet_rescale_ts(
                packet,
                inputTimeBase,
                outputStream.pointee.time_base
            )
            packet.pointee.stream_index = 0
            packet.pointee.pos = -1
            guard av_interleaved_write_frame(
                outputContext,
                packet
            ) >= 0 else {
                throw HybridIntroAudioExtractionError.packetWriteFailed
            }
            packetCount += 1
        }

        guard packetCount > 0,
              av_write_trailer(outputContext) >= 0 else {
            throw HybridIntroAudioExtractionError.emptyOutput
        }
        avio_closep(&outputContext.pointee.pb)
        outputIsOpen = false

        let byteCount = Int64(
            (
                try? outputURL.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize
            ) ?? 0
        )
        guard byteCount > 0 else {
            throw HybridIntroAudioExtractionError.emptyOutput
        }
        return HybridIntroAudioArtifact(
            url: outputURL,
            sourceDuration: min(sourceDuration, maximumDuration),
            packetCount: packetCount,
            byteCount: byteCount,
            elapsedSeconds:
                ProcessInfo.processInfo.systemUptime - startedAt
        )
    }
}
