import AetherEngine
import AVFAudio
import AetherLibavcodec
import AetherLibavutil
import XCTest
@testable import SyncnextHybrid

final class HybridFFmpegAudioDecoderTests: XCTestCase {
    func testSixToTwoPlanarChannelsKeepContinuousMonoAudio() throws {
        let decoder = HybridFFmpegAudioDecoder()
        let frameSamples = 512
        let framesBeforeSwitch = 9
        var chunks: [HybridDecodedAudioChunk] = []
        for index in 0..<20 {
            let surround = index < framesBeforeSwitch
            var storage = av_frame_alloc()
            defer { av_frame_free(&storage) }
            let frame = try XCTUnwrap(storage)
            frame.pointee.format = AV_SAMPLE_FMT_S16P.rawValue
            frame.pointee.sample_rate = 48_000
            frame.pointee.nb_samples = Int32(frameSamples)
            frame.pointee.pts = 54_000_000 + Int64(index) * 960
            XCTAssertEqual(av_channel_layout_from_string(&frame.pointee.ch_layout, surround ? "5.1(side)" : "stereo"), 0)
            XCTAssertEqual(av_frame_get_buffer(frame, 0), 0)
            let planes = try XCTUnwrap(frame.pointee.extended_data)
            for plane in 0..<Int(frame.pointee.ch_layout.nb_channels) {
                let data = try XCTUnwrap(planes[plane])
                data.withMemoryRebound(to: Int16.self, capacity: frameSamples) { samples in
                    samples.update(repeating: surround ? 1000 : -1000, count: frameSamples)
                }
            }
            if let chunk = try decoder.ingestDecodedFrame(frame) {
                chunks.append(chunk)
            }
        }

        XCTAssertEqual(chunks.map { $0.buffer.frameLength }, [5120, 5120])
        let first = try XCTUnwrap(chunks.first)
        let last = try XCTUnwrap(chunks.last)
        XCTAssertEqual(first.ptsSeconds, 600, accuracy: 0.000_001)
        XCTAssertEqual(last.ptsSeconds, 600 + 5120.0 / 48_000, accuracy: 0.000_001)
        XCTAssertEqual(first.buffer.format.sampleRate, 48_000)
        XCTAssertEqual(first.buffer.format.channelCount, 1)
        let mono = try XCTUnwrap(first.buffer.floatChannelData?[0])
        let transition = frameSamples * framesBeforeSwitch
        XCTAssertGreaterThan(mono[transition - 1], 0)
        XCTAssertLessThan(mono[transition], 0)
    }

    func testIndependentDemuxDecodeAndResample() throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(
                forResource: "tone",
                withExtension: "m4a",
                subdirectory: "Fixtures"
            )
        )
        let demuxer = Demuxer()
        try demuxer.openIndependent(url: fixture)
        defer { demuxer.close() }

        XCTAssertTrue(demuxer.isSourceSeekable)
        let track = try XCTUnwrap(demuxer.audioTrackInfos().first)
        XCTAssertTrue(demuxer.seek(to: 0.25))
        demuxer.discardAllStreamsExcept([Int32(track.id)])

        let decoder = HybridFFmpegAudioDecoder()
        try decoder.open(demuxer: demuxer, streamIndex: Int32(track.id))
        defer { decoder.close() }

        var decoded = [HybridDecodedAudioChunk]()
        while decoded.isEmpty, let packet = try demuxer.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&packetToFree) }
            guard packet.pointee.stream_index == track.id else {
                continue
            }
            decoded.append(contentsOf: try decoder.decode(packet: packet))
        }
        if decoded.isEmpty {
            decoded.append(contentsOf: try decoder.drain())
        }

        let chunk = try XCTUnwrap(decoded.first)
        XCTAssertEqual(chunk.buffer.format.sampleRate, 48_000)
        XCTAssertEqual(chunk.buffer.format.channelCount, 1)
        XCTAssertFalse(chunk.buffer.format.isInterleaved)
        XCTAssertGreaterThan(chunk.buffer.frameLength, 0)
        XCTAssertTrue(chunk.ptsSeconds.isFinite)
    }
}
