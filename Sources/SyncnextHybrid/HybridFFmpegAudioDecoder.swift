import AVFAudio
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AetherLibswresample

struct HybridAudioContinuityTracker {
    private static let initialOriginTolerance: Int64 = 1

    let requestedStartPosition: Int64
    private(set) var expectedPosition: Int64?

    mutating func consume(
        sourcePosition: Int64,
        frameLength: AVAudioFrameCount
    ) -> Bool {
        let isDiscontinuous: Bool
        if let expectedPosition {
            isDiscontinuous = sourcePosition != expectedPosition
        } else {
            // FFmpeg timestamp conversion and range clipping can place the
            // first decoded sample one position either side of the requested
            // origin. This is rounding, not a break in the emitted PCM stream.
            let delta = sourcePosition - requestedStartPosition
            isDiscontinuous =
                delta < -Self.initialOriginTolerance
                || delta > Self.initialOriginTolerance
        }
        expectedPosition = sourcePosition + Int64(frameLength)
        return isDiscontinuous
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
