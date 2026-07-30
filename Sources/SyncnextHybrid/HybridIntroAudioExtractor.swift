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

enum HybridIntroAudioExtractor {
    private static let artifactGate = HybridIntroAudioArtifactGate()

    static func extract(
        source: AetherIndependentAudioSource,
        maximumDuration: Double,
        outputURL: URL
    ) async throws -> HybridIntroAudioArtifact {
        guard maximumDuration.isFinite,
              maximumDuration > 0,
              maximumDuration <= 180 else {
            throw HybridIntroAudioExtractionError.invalidDuration
        }

        await artifactGate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await extractExclusively(
                source: source,
                maximumDuration: maximumDuration,
                outputURL: outputURL
            )
            await artifactGate.release()
            return result
        } catch {
            await artifactGate.release()
            throw error
        }
    }

    private static func extractExclusively(
        source: AetherIndependentAudioSource,
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
            if let hlsRequest = source.remoteHLSRequest {
                let prepared = try await
                    HybridHLSVODAudioSource.prepare(
                        request: hlsRequest,
                        range: 0..<maximumDuration
                    )
                preparedHLSCursor = prepared
                try Task.checkCancellation()
                try demuxer.openIndependent(
                    reader: prepared.reader,
                    formatHint: prepared.formatHint
                )
            } else {
                try source.openDemuxer(demuxer)
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
