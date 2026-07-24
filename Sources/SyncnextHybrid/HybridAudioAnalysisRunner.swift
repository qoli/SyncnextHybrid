import AetherEngine
import AVFAudio
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import Libswresample

final class HybridAudioAnalysisRun: @unchecked Sendable {
    let id = UUID()
    let gate = HybridAudioDemandGate()

    private let lock = NSLock()
    private var cancelled = false
    private var demuxer: Demuxer?
    private var task: Task<Void, Never>?

    func install(demuxer: Demuxer) throws {
        lock.lock()
        self.demuxer = demuxer
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled {
            demuxer.markClosed()
            throw HybridAudioAnalysisError.cancelled
        }
    }

    func install(task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled {
            task.cancel()
        }
    }

    func throwIfCancelled() throws {
        lock.lock()
        let isCancelled = cancelled
        lock.unlock()
        if isCancelled || Task.isCancelled {
            throw HybridAudioAnalysisError.cancelled
        }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let demuxer = demuxer
        let task = task
        lock.unlock()

        demuxer?.markClosed()
        task?.cancel()
        Task { await gate.cancel() }
    }

    func close() {
        lock.lock()
        let demuxer = demuxer
        self.demuxer = nil
        task = nil
        lock.unlock()
        demuxer?.close()
    }
}

enum HybridAudioAnalysisRunner {
    private static let maximumPendingChunks = 32

    static func run(
        context: HybridAudioAnalysisRun,
        source: AetherIndependentAudioSource,
        range: Range<Double>,
        completion: @escaping @Sendable (HybridAudioAnalysisError?) -> Void
    ) async {
        var terminalError: HybridAudioAnalysisError?
        var preparedHLSCursor: HybridHLSPreparedAudioCursor?
        defer {
            context.close()
            preparedHLSCursor?.removeFile()
            completion(terminalError)
        }

        do {
            // Creating a stream alone performs no network or decode work.
            try await context.gate.waitForDemand()
            try context.throwIfCancelled()

            let demuxer = Demuxer()
            try context.install(demuxer: demuxer)

            let selected: TrackInfo
            if let hlsRequest = source.remoteHLSRequest {
                let prepared = try await
                    HybridHLSVODAudioSource.prepare(
                        request: hlsRequest,
                        range: range
                    )
                preparedHLSCursor = prepared
                try context.throwIfCancelled()
                do {
                    try demuxer.openIndependent(
                        url: prepared.fileURL
                    )
                } catch {
                    throw HybridAudioAnalysisError.demuxFailed(
                        String(describing: error)
                    )
                }
                selected = try
                    HybridHLSVODAudioSource.resolveSelectedTrack(
                        from: demuxer.audioTrackInfos(),
                        prepared: prepared
                    )
            } else {
                do {
                    try source.openDemuxer(demuxer)
                } catch {
                    throw mapSourceError(error)
                }
                guard let expected = source.selectedAudioTrack,
                      let actual = demuxer.audioTrackInfos().first(
                        where: { $0.id == expected.id }
                      ) else {
                    throw HybridAudioAnalysisError
                        .selectedAudioTrackUnavailable
                }
                guard sameTrackContract(actual, expected) else {
                    throw HybridAudioAnalysisError.sourceTrackChanged
                }
                selected = actual
            }
            try context.throwIfCancelled()

            guard let stream = demuxer.stream(
                    at: Int32(selected.id)
                  ),
                  stream.pointee.codecpar.pointee.codec_type
                    == AVMEDIA_TYPE_AUDIO else {
                throw HybridAudioAnalysisError.sourceTrackChanged
            }
            let timelineOrigin = demuxer.formatStartTimeSeconds
            guard range.lowerBound == 0
                    || demuxer.seek(
                        to: range.lowerBound + timelineOrigin
                    ) else {
                throw HybridAudioAnalysisError.demuxFailed(
                    "cannot seek independent cursor to \(range.lowerBound) seconds"
                )
            }
            demuxer.discardAllStreamsExcept([Int32(selected.id)])

            let decoder = HybridFFmpegAudioDecoder()
            defer { decoder.close() }
            try decoder.open(stream: stream)

            try await pump(
                context: context,
                demuxer: demuxer,
                decoder: decoder,
                streamID: selected.id,
                range: range,
                timelineOrigin: timelineOrigin,
                hasOutstandingDemand: true
            )
            await context.gate.finish()
        } catch let error as HybridAudioAnalysisError {
            terminalError = error
            await context.gate.fail(error)
        } catch is CancellationError {
            terminalError = .cancelled
            await context.gate.fail(.cancelled)
        } catch {
            let typed = HybridAudioAnalysisError.decoderFailed(
                String(describing: error)
            )
            terminalError = typed
            await context.gate.fail(typed)
        }
    }

    private static func pump(
        context: HybridAudioAnalysisRun,
        demuxer: Demuxer,
        decoder: HybridFFmpegAudioDecoder,
        streamID: Int,
        range: Range<Double>,
        timelineOrigin: Double,
        hasOutstandingDemand: Bool
    ) async throws {
        var pending: [HybridDecodedAudioChunk] = []
        var inputEnded = false
        var decoderDrained = false
        var demandOutstanding = hasOutstandingDemand
        var expectedPosition = Int64(
            (range.lowerBound * HybridAudioAnalysisFormat.sampleRate).rounded()
        )

        while true {
            if !demandOutstanding {
                try await context.gate.waitForDemand()
            }
            try context.throwIfCancelled()

            while true {
                let chunk: HybridDecodedAudioChunk
                if !pending.isEmpty {
                    chunk = pending.removeFirst()
                } else if inputEnded {
                    guard !decoderDrained else {
                        return
                    }
                    decoderDrained = true
                    try append(decoder.drain(), to: &pending)
                    if pending.isEmpty {
                        return
                    }
                    continue
                } else {
                    let packet: UnsafeMutablePointer<AVPacket>?
                    do {
                        packet = try demuxer.readPacket()
                    } catch {
                        throw HybridAudioAnalysisError.demuxFailed(
                            String(describing: error)
                        )
                    }
                    guard let packet else {
                        inputEnded = true
                        continue
                    }
                    var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
                    defer { av_packet_free(&packetToFree) }
                    guard packet.pointee.stream_index == streamID else {
                        continue
                    }
                    try append(
                        try decoder.decode(packet: packet),
                        to: &pending
                    )
                    continue
                }

                switch clip(
                    chunk,
                    to: range,
                    timelineOrigin: timelineOrigin
                ) {
                case .skip:
                    continue
                case .finish:
                    return
                case .emit(let pcm, let sourcePosition):
                    let output = HybridAudioAnalysisBuffer(
                        pcm: pcm,
                        sourceSamplePosition: sourcePosition,
                        isDiscontinuous: sourcePosition != expectedPosition
                    )
                    guard await context.gate.yield(output) else {
                        throw HybridAudioAnalysisError.cancelled
                    }
                    expectedPosition =
                        sourcePosition + Int64(pcm.frameLength)
                    demandOutstanding = false
                }
                break
            }
        }
    }

    private static func sameTrackContract(
        _ actual: TrackInfo,
        _ expected: TrackInfo
    ) -> Bool {
        actual.id == expected.id
            && actual.codec == expected.codec
            && actual.language == expected.language
            && actual.channels == expected.channels
    }

    private static func mapSourceError(
        _ error: Error
    ) -> HybridAudioAnalysisError {
        guard let sourceError =
            error as? AetherIndependentAudioSourceError else {
            return .demuxFailed(String(describing: error))
        }
        switch sourceError {
        case .noActiveSession:
            return .noActivePlayback
        case .liveOrDVRUnsupported:
            return .liveOrDVRUnsupported
        case .sourceNotSeekable:
            return .sourceNotSeekable
        case .selectedAudioTrackUnavailable:
            return .selectedAudioTrackUnavailable
        case .independentReaderUnavailable:
            return .independentReaderUnavailable
        case .remoteHLSPreparationRequired:
            return .demuxFailed(
                "remote HLS VOD requires bounded preparation"
            )
        }
    }

    private static func append(
        _ chunks: [HybridDecodedAudioChunk],
        to pending: inout [HybridDecodedAudioChunk]
    ) throws {
        guard pending.count + chunks.count <= maximumPendingChunks else {
            throw HybridAudioAnalysisError.decoderFailed(
                "one decoder operation exceeded the bounded PCM queue"
            )
        }
        pending.append(contentsOf: chunks)
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
        let position =
            Int64((chunkStart * sampleRate).rounded()) + Int64(startFrame)
        return .emit(pcm, position)
    }
}

struct HybridDecodedAudioChunk {
    let buffer: AVAudioPCMBuffer
    let ptsSeconds: Double
}

final class HybridFFmpegAudioDecoder: @unchecked Sendable {
    private static let minimumSamplesPerChunk = 4_800

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var resampler: OpaquePointer?
    private var timeBase = AVRational(num: 1, den: 90_000)
    private var anchorPTS: Double?
    private var samplesSinceAnchor: Int64 = 0
    private var pending: [Float] = []
    private var pendingStartPTS: Double = 0

    func open(stream: UnsafeMutablePointer<AVStream>) throws {
        guard let parameters = stream.pointee.codecpar else {
            throw HybridAudioAnalysisError.decoderFailed(
                "audio stream has no codec parameters"
            )
        }
        timeBase = stream.pointee.time_base
        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id),
              let context = avcodec_alloc_context3(codec) else {
            throw HybridAudioAnalysisError.decoderFailed(
                "audio codec is unavailable"
            )
        }
        codecContext = context
        guard avcodec_parameters_to_context(context, parameters) >= 0,
              avcodec_open2(context, codec, nil) >= 0 else {
            avcodec_free_context(&codecContext)
            throw HybridAudioAnalysisError.decoderFailed(
                "FFmpeg could not open the audio decoder"
            )
        }
    }

    func decode(
        packet: UnsafeMutablePointer<AVPacket>
    ) throws -> [HybridDecodedAudioChunk] {
        guard let context = codecContext else {
            throw HybridAudioAnalysisError.decoderFailed(
                "audio decoder is not open"
            )
        }
        guard avcodec_send_packet(context, packet) >= 0 else {
            throw HybridAudioAnalysisError.decoderFailed(
                "FFmpeg rejected an audio packet"
            )
        }
        return try receiveAll(context)
    }

    func drain() throws -> [HybridDecodedAudioChunk] {
        guard let context = codecContext else {
            return []
        }
        _ = avcodec_send_packet(context, nil)
        var chunks = try receiveAll(context)
        if let tail = emitPending(force: true) {
            chunks.append(tail)
        }
        return chunks
    }

    func close() {
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        if resampler != nil {
            swr_free(&resampler)
        }
        pending.removeAll()
        anchorPTS = nil
        samplesSinceAnchor = 0
    }

    deinit {
        close()
    }

    private func receiveAll(
        _ context: UnsafeMutablePointer<AVCodecContext>
    ) throws -> [HybridDecodedAudioChunk] {
        var chunks: [HybridDecodedAudioChunk] = []
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let frame else {
            throw HybridAudioAnalysisError.decoderFailed(
                "FFmpeg could not allocate an audio frame"
            )
        }

        while avcodec_receive_frame(context, frame) >= 0 {
            if resampler == nil {
                try initializeResampler(from: frame)
            }
            try ingest(frame)
            if pending.count >= Self.minimumSamplesPerChunk,
               let chunk = emitPending(force: false) {
                chunks.append(chunk)
            }
        }
        return chunks
    }

    private func initializeResampler(
        from frame: UnsafeMutablePointer<AVFrame>
    ) throws {
        var outputLayout = AVChannelLayout()
        av_channel_layout_default(&outputLayout, 1)
        var inputLayout = AVChannelLayout()
        if frame.pointee.ch_layout.nb_channels > 0 {
            av_channel_layout_copy(&inputLayout, &frame.pointee.ch_layout)
        } else {
            av_channel_layout_default(&inputLayout, 2)
        }
        defer {
            av_channel_layout_uninit(&inputLayout)
            av_channel_layout_uninit(&outputLayout)
        }

        let allocation = swr_alloc_set_opts2(
            &resampler,
            &outputLayout,
            AV_SAMPLE_FMT_FLT,
            Int32(HybridAudioAnalysisFormat.sampleRate),
            &inputLayout,
            AVSampleFormat(rawValue: frame.pointee.format),
            frame.pointee.sample_rate,
            0,
            nil
        )
        guard allocation >= 0,
              resampler != nil,
              swr_init(resampler) >= 0 else {
            if resampler != nil {
                swr_free(&resampler)
            }
            throw HybridAudioAnalysisError.decoderFailed(
                "FFmpeg could not initialize mono 48 kHz resampling"
            )
        }
    }

    private func ingest(
        _ frame: UnsafeMutablePointer<AVFrame>
    ) throws {
        guard let resampler, frame.pointee.nb_samples > 0 else {
            return
        }

        let framePTS: Double? =
            frame.pointee.pts != Int64.min && timeBase.den > 0
            ? Double(frame.pointee.pts)
                * Double(timeBase.num)
                / Double(timeBase.den)
            : nil
        let runningPTS = anchorPTS.map {
            $0 + Double(samplesSinceAnchor)
                / HybridAudioAnalysisFormat.sampleRate
        }
        if anchorPTS == nil
            || (
                framePTS != nil
                    && runningPTS != nil
                    && abs(framePTS! - runningPTS!) > 0.25
            ) {
            pending.removeAll(keepingCapacity: true)
            anchorPTS = framePTS ?? 0
            samplesSinceAnchor = 0
        }
        if pending.isEmpty {
            pendingStartPTS =
                anchorPTS!
                + Double(samplesSinceAnchor)
                    / HybridAudioAnalysisFormat.sampleRate
        }

        let maximumOutput = Int(
            swr_get_out_samples(resampler, frame.pointee.nb_samples)
        )
        guard maximumOutput > 0 else {
            return
        }
        var output = [Float](repeating: 0, count: maximumOutput)
        let converted: Int32 = output.withUnsafeMutableBytes { raw in
            var outputPointer: UnsafeMutablePointer<UInt8>? =
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return withUnsafeMutablePointer(to: &outputPointer) { outputBuffer in
                let input = UnsafePointer<UnsafePointer<UInt8>?>(
                    OpaquePointer(frame.pointee.extended_data)
                )
                return swr_convert(
                    resampler,
                    outputBuffer,
                    Int32(maximumOutput),
                    input,
                    frame.pointee.nb_samples
                )
            }
        }
        guard converted >= 0 else {
            throw HybridAudioAnalysisError.decoderFailed(
                "FFmpeg resampling failed"
            )
        }
        guard converted > 0 else {
            return
        }
        pending.append(contentsOf: output.prefix(Int(converted)))
        samplesSinceAnchor += Int64(converted)
    }

    private func emitPending(
        force: Bool
    ) -> HybridDecodedAudioChunk? {
        guard !pending.isEmpty,
              force || pending.count >= Self.minimumSamplesPerChunk,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: HybridAudioAnalysisFormat.pcm,
                frameCapacity: AVAudioFrameCount(pending.count)
              ),
              let output = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(pending.count)
        pending.withUnsafeBufferPointer { input in
            guard let baseAddress = input.baseAddress else {
                return
            }
            output.update(from: baseAddress, count: input.count)
        }
        let chunk = HybridDecodedAudioChunk(
            buffer: buffer,
            ptsSeconds: pendingStartPTS
        )
        pendingStartPTS +=
            Double(pending.count) / HybridAudioAnalysisFormat.sampleRate
        pending.removeAll(keepingCapacity: true)
        return chunk
    }
}
