import AetherEngine
import Libavcodec
import Foundation
import XCTest
@testable import SyncnextHybrid

final class HybridHLSVODAudioSourceTests: XCTestCase {
    func testFingerprintProviderResolutionIsExplicitPerAdmission() throws {
        XCTAssertEqual(
            try HybridFingerprintAudioProviderResolver.resolve(
                admission: .hlsVOD
            ),
            .independentRemoteHLS
        )
        XCTAssertEqual(
            try HybridFingerprintAudioProviderResolver.resolve(
                admission: .hlsVODHEVCMPEGTS(duration: 120)
            ),
            .segmentCache
        )
        XCTAssertEqual(
            try HybridFingerprintAudioProviderResolver.resolve(
                admission: .aetherDefault(.confirmedNonHLS)
            ),
            .independentDemuxer
        )
        XCTAssertThrowsError(
            try HybridFingerprintAudioProviderResolver.resolve(
                admission: .hlsLive
            )
        ) { error in
            XCTAssertEqual(
                error as? HybridFingerprintAudioError,
                .liveOrDVRUnsupported
            )
        }
    }

    func testDedicatedHLSVODRenditionBuildsIndependentFFmpegCursor()
        async throws
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HybridHLSFixtureURLProtocol.self,
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let request = AetherRemoteHLSAudioRequest(
            url: try XCTUnwrap(
                URL(string: "https://hybrid-fixture.invalid/master.m3u8")
            ),
            httpHeaders: ["X-Hybrid-Fixture": "allowed"],
            selection: AetherRemoteHLSAudioSelection(
                displayName: "English",
                language: "en",
                optionOrdinal: 0
            )
        )
        let prepared = try await HybridHLSVODAudioSource.prepare(
            request: request,
            range: 0..<2,
            session: session
        )
        defer { prepared.close() }

        let demuxer = Demuxer()
        try demuxer.openIndependent(
            reader: prepared.reader,
            formatHint: prepared.formatHint
        )
        defer { demuxer.close() }
        XCTAssertTrue(prepared.usesDedicatedAudioRendition)
        let selected = try
            HybridHLSVODAudioSource.resolveSelectedTrack(
                from: demuxer.audioTrackInfos(),
                prepared: prepared
        )
        XCTAssertEqual(selected.codec, "aac")
        let stream = try XCTUnwrap(
            demuxer.stream(at: Int32(selected.id))
        )
        demuxer.discardAllStreamsExcept([Int32(selected.id)])

        let decoder = HybridFFmpegAudioDecoder()
        try decoder.open(stream: stream)
        defer { decoder.close() }
        var decoded = [HybridDecodedAudioChunk]()
        while decoded.isEmpty, let packet = try demuxer.readPacket() {
            var packetToFree: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&packetToFree) }
            guard packet.pointee.stream_index == selected.id else {
                continue
            }
            decoded.append(
                contentsOf: try decoder.decode(packet: packet)
            )
        }
        let first = try XCTUnwrap(decoded.first)
        XCTAssertEqual(
            first.ptsSeconds - demuxer.formatStartTimeSeconds,
            0,
            accuracy: 0.025
        )
    }

    func testHLSWithoutEndListFailsAsLiveOrDVR() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HybridHLSFixtureURLProtocol.self,
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let request = AetherRemoteHLSAudioRequest(
            url: try XCTUnwrap(
                URL(string: "https://hybrid-fixture.invalid/live.m3u8")
            ),
            httpHeaders: [:],
            selection: AetherRemoteHLSAudioSelection(
                displayName: nil,
                language: nil,
                optionOrdinal: nil
            )
        )

        do {
            _ = try await HybridHLSVODAudioSource.prepare(
                request: request,
                range: 0..<1,
                session: session
            )
            XCTFail("live playlist unexpectedly admitted")
        } catch let error as HybridAudioAnalysisError {
            XCTAssertEqual(error, .liveOrDVRUnsupported)
        }
    }

    func testRemoteHLSFingerprintAdapterReturnsBoundedPCM() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HybridHLSFixtureURLProtocol.self,
        ]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let request = AetherRemoteHLSAudioRequest(
            url: try XCTUnwrap(
                URL(string: "https://hybrid-fixture.invalid/master.m3u8")
            ),
            httpHeaders: ["X-Hybrid-Fixture": "allowed"],
            selection: AetherRemoteHLSAudioSelection(
                displayName: "English",
                language: "en",
                optionOrdinal: 0
            )
        )
        let source = HybridIndependentFingerprintAudioSource.remoteHLS(
            request
        )
        let batch = try await HybridIndependentFingerprintAudio.decode(
            source: source,
            range: 0..<2,
            hlsSession: session
        )

        XCTAssertEqual(batch.provider, .independentRemoteHLS)
        XCTAssertGreaterThan(batch.segmentCount, 0)
        XCTAssertFalse(batch.buffers.isEmpty)
        XCTAssertEqual(batch.sourceRange, 0..<2)
        XCTAssertEqual(batch.cacheWaitSeconds, 0)
    }

    func testDirectDemuxFingerprintAdapterReturnsBoundedPCM() async throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "tone",
                withExtension: "m4a",
                subdirectory: "Fixtures"
            )
        )
        let source = HybridIndependentFingerprintAudioSource.demuxer(
            url: url,
            httpHeaders: [:],
            selectedTrack: nil
        )
        let batch = try await HybridIndependentFingerprintAudio.decode(
            source: source,
            range: 0..<1
        )

        XCTAssertEqual(batch.provider, .independentDemuxer)
        XCTAssertEqual(batch.segmentCount, 0)
        XCTAssertFalse(batch.buffers.isEmpty)
        XCTAssertEqual(batch.sourceRange, 0..<1)
        XCTAssertEqual(batch.cacheWaitSeconds, 0)
    }
}

private final class HybridHLSFixtureURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    override class func canInit(
        with request: URLRequest
    ) -> Bool {
        request.url?.host == "hybrid-fixture.invalid"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.value(
            forHTTPHeaderField: "X-Hybrid-Fixture"
        ) == "allowed" || request.url?.lastPathComponent == "live.m3u8",
              let url = request.url,
              let data = fixtureData(for: url.lastPathComponent),
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Length": String(data.count),
                ]
              ) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func fixtureData(for name: String) -> Data? {
        if name == "live.m3u8" {
            return Data(
                """
                #EXTM3U
                #EXT-X-VERSION:3
                #EXT-X-TARGETDURATION:1
                #EXTINF:1,
                audio-00.ts
                """.utf8
            )
        }
        let parts = name.split(separator: ".", maxSplits: 1)
        guard parts.count == 2,
              let url = Bundle.module.url(
                forResource: String(parts[0]),
                withExtension: String(parts[1]),
                subdirectory: "Fixtures/hls-vod"
              ) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
