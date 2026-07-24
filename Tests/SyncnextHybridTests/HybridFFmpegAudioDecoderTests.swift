import AetherEngine
import AVFAudio
import Libavcodec
import XCTest
@testable import SyncnextHybrid

final class HybridFFmpegAudioDecoderTests: XCTestCase {
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
        let stream = try XCTUnwrap(demuxer.stream(at: Int32(track.id)))
        XCTAssertTrue(demuxer.seek(to: 0.25))
        demuxer.discardAllStreamsExcept([Int32(track.id)])

        let decoder = HybridFFmpegAudioDecoder()
        try decoder.open(stream: stream)
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
