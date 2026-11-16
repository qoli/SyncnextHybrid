import AVFAudio
import AetherEngine
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AetherLibswresample
import Foundation

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
    #if DEBUG
    private static let observesISOFrames = ProcessInfo.processInfo.arguments.contains(
        "--syncnext-acceptance-case=ISOAudioFingerprintCrash"
    )
    #endif

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    private var resampler: OpaquePointer?
    private var resamplerInputLayout = AVChannelLayout()
    private var resamplerInputFormat = AV_SAMPLE_FMT_NONE
    private var resamplerInputRate: Int32 = 0
    private var timeBase = AVRational(num: 1, den: 90_000)
    private var anchorPTS: Double?
    private var samplesSinceAnchor: Int64 = 0
    private var pending: [Float] = []
    private var pendingStartPTS: Double = 0

    func open(demuxer: Demuxer, streamIndex: Int32) throws {
        var preparedContext: UnsafeMutablePointer<AVCodecContext>?
        var preparedCodec: UnsafePointer<AVCodec>?
        let copied = demuxer.withStream(at: streamIndex) { stream -> Bool in
            guard let parameters = stream.pointee.codecpar,
                  let codec = avcodec_find_decoder(parameters.pointee.codec_id),
                  let context = avcodec_alloc_context3(codec) else {
                return false
            }
            guard avcodec_parameters_to_context(context, parameters) >= 0 else {
                var contextToFree: UnsafeMutablePointer<AVCodecContext>? = context
                avcodec_free_context(&contextToFree)
                return false
            }
            timeBase = stream.pointee.time_base
            preparedContext = context
            preparedCodec = codec
            return true
        }
        guard copied == true,
              let context = preparedContext,
              let codec = preparedCodec else {
            throw HybridAudioAnalysisError.decoderFailed(
                "audio codec is unavailable"
            )
        }
        codecContext = context
        guard avcodec_open2(context, codec, nil) >= 0 else {
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
        swr_free(&resampler)
        av_channel_layout_uninit(&resamplerInputLayout)
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
            if let chunk = try ingestDecodedFrame(frame) {
                chunks.append(chunk)
            }
        }
        return chunks
    }

    private func initializeResampler(
        layout: inout AVChannelLayout,
        format: AVSampleFormat,
        rate: Int32
    ) throws -> OpaquePointer {
        swr_free(&resampler)
        av_channel_layout_uninit(&resamplerInputLayout)
        guard av_channel_layout_copy(&resamplerInputLayout, &layout) >= 0 else {
            throw HybridAudioAnalysisError.decoderFailed("FFmpeg could not copy the input audio layout")
        }

        var outputLayout = AVChannelLayout()
        av_channel_layout_default(&outputLayout, 1)
        defer { av_channel_layout_uninit(&outputLayout) }

        let allocation = swr_alloc_set_opts2(
            &resampler,
            &outputLayout,
            AV_SAMPLE_FMT_FLT,
            Int32(HybridAudioAnalysisFormat.sampleRate),
            &layout,
            format,
            rate,
            0,
            nil
        )
        guard allocation >= 0,
              let resampler,
              swr_init(resampler) >= 0 else {
            swr_free(&resampler)
            av_channel_layout_uninit(&resamplerInputLayout)
            throw HybridAudioAnalysisError.decoderFailed(
                "FFmpeg could not initialize mono 48 kHz resampling"
            )
        }
        resamplerInputFormat = format
        resamplerInputRate = rate
        return resampler
    }

    func ingestDecodedFrame(
        _ frame: UnsafeMutablePointer<AVFrame>
    ) throws -> HybridDecodedAudioChunk? {
        let input = frame.pointee
        guard input.nb_samples > 0 else { return nil }
        let format = AVSampleFormat(rawValue: input.format)
        var layout = input.ch_layout
        let rate = input.sample_rate
        guard av_get_bytes_per_sample(format) > 0, rate > 0, av_channel_layout_check(&layout) != 0 else {
            Self.recordInvalidFrame(input, reason: "invalid_configuration")
            throw HybridAudioAnalysisError.decoderFailed("Invalid decoded audio frame configuration")
        }
        let planeCount = av_sample_fmt_is_planar(format) != 0 ? Int(layout.nb_channels) : 1
        guard let planes = input.extended_data,
              (0..<planeCount).allSatisfy({ planes[$0] != nil }) else {
            Self.recordInvalidFrame(input, reason: "missing_data_plane")
            throw HybridAudioAnalysisError.decoderFailed("Decoded audio frame is missing a data plane")
        }

        let framePTS: Double? =
            input.pts != Int64.min && timeBase.den > 0
            ? Double(input.pts)
                * Double(timeBase.num)
                / Double(timeBase.den)
            : nil
        let runningPTS = anchorPTS.map {
            $0 + Double(samplesSinceAnchor)
                / HybridAudioAnalysisFormat.sampleRate
        }
        let startsNewTimeline: Bool
        if let framePTS, let runningPTS {
            startsNewTimeline = abs(framePTS - runningPTS) > 0.25
        } else {
            startsNewTimeline = anchorPTS == nil
        }

        let converter: OpaquePointer
        if let resampler,
           resamplerInputFormat == format, resamplerInputRate == rate,
           av_channel_layout_compare(&resamplerInputLayout, &layout) == 0 {
            converter = resampler
        } else {
            var previous: String?
            if let resampler {
                previous = Self.describeInput(resamplerInputFormat, resamplerInputRate, resamplerInputLayout)
                // Keep delayed samples on the old timeline before replacing the converter.
                if !startsNewTimeline {
                    try appendResampledSamples(using: resampler, input: nil, count: 0)
                }
            }
            converter = try initializeResampler(layout: &layout, format: format, rate: rate)
            if let previous {
                HybridDiagnosticEmitter.emit(
                    "SYNCNEXT_HYBRID_FINGERPRINT_RESAMPLER event=reconfigured pts=\(input.pts) samples=\(input.nb_samples) "
                        + "previous={\(previous)} frame={\(Self.describeInput(format, rate, layout)) planes=\(planeCount)/\(planeCount)}"
                )
            }
            #if DEBUG
            if previous == nil, Self.observesISOFrames {
                HybridDiagnosticEmitter.emit(
                    "SYNCNEXT_HYBRID_FINGERPRINT_RESAMPLER event=input pts=\(input.pts) samples=\(input.nb_samples) "
                        + "frame={\(Self.describeInput(format, rate, layout)) planes=\(planeCount)/\(planeCount)}"
                )
            }
            #endif
        }

        if startsNewTimeline {
            #if DEBUG
            if Self.observesISOFrames, let framePTS, let runningPTS {
                HybridDiagnosticEmitter.emit(
                    "SYNCNEXT_HYBRID_FINGERPRINT_RESAMPLER event=timestamp_reset pts=\(input.pts) "
                        + "expectedSeconds=\(runningPTS) actualSeconds=\(framePTS) pendingSamples=\(pending.count)"
                )
            }
            #endif
            pending.removeAll(keepingCapacity: true)
            anchorPTS = framePTS ?? 0
            samplesSinceAnchor = 0
        }
        try appendResampledSamples(
            using: converter,
            input: UnsafePointer<UnsafePointer<UInt8>?>(OpaquePointer(planes)),
            count: input.nb_samples
        )
        return emitPending(force: false)
    }

    private func appendResampledSamples(
        using resampler: OpaquePointer,
        input: UnsafePointer<UnsafePointer<UInt8>?>?,
        count: Int32
    ) throws {
        let maximumOutput = Int(swr_get_out_samples(resampler, count))
        guard maximumOutput >= 0 else {
            throw HybridAudioAnalysisError.decoderFailed("FFmpeg could not size the resampled output")
        }
        guard maximumOutput > 0 else {
            return
        }
        var output = [Float](repeating: 0, count: maximumOutput)
        let converted: Int32 = output.withUnsafeMutableBytes { raw in
            var outputPointer: UnsafeMutablePointer<UInt8>? =
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return withUnsafeMutablePointer(to: &outputPointer) { outputBuffer in
                swr_convert(resampler, outputBuffer, Int32(maximumOutput), input, count)
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
        if pending.isEmpty, let anchorPTS {
            pendingStartPTS = anchorPTS + Double(samplesSinceAnchor) / HybridAudioAnalysisFormat.sampleRate
        }
        pending.append(contentsOf: output.prefix(Int(converted)))
        samplesSinceAnchor += Int64(converted)
    }

    private static func describeInput(_ format: AVSampleFormat, _ rate: Int32, _ layout: AVChannelLayout) -> String {
        let formatName = av_get_sample_fmt_name(format).map { String(cString: $0) } ?? "unknown"
        var layout = layout
        var layoutDescription = [CChar](repeating: 0, count: 128)
        layoutDescription.withUnsafeMutableBufferPointer {
            _ = av_channel_layout_describe(&layout, $0.baseAddress, $0.count)
        }
        let layoutName = layoutDescription.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return "format=\(formatName) rate=\(rate) channels=\(layout.nb_channels) "
            + "layout=\(String(decoding: layoutName, as: UTF8.self).replacingOccurrences(of: " ", with: "_"))"
    }

    private static func recordInvalidFrame(_ frame: AVFrame, reason: String) {
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_FINGERPRINT_RESAMPLER event=invalid_frame reason=\(reason) pts=\(frame.pts) "
                + "samples=\(frame.nb_samples) format=\(frame.format) rate=\(frame.sample_rate) channels=\(frame.ch_layout.nb_channels)"
        )
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
