import AetherEngine
import Foundation
import XCTest
@testable import SyncnextHybrid

final class HybridRemoteSourceAdmissionTests: XCTestCase {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HybridAdmissionFixtureURLProtocol.self,
        ]
        return URLSession(configuration: configuration)
    }

    func testExtensionlessMasterAndMediaPlaylistAdmitHLSVOD()
        async throws
    {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let url = try XCTUnwrap(
            URL(string: "https://admission-fixture.invalid/extensionless")
        )
        let admission = try await
            HybridRemoteSourceAdmission.classify(
                url: url,
                httpHeaders: ["X-Admission-Fixture": "allowed"],
                session: session
            )

        XCTAssertEqual(admission, .hlsVOD)

        let request = try HybridPlaybackRequest(
            url: url,
            httpHeaders: ["X-Admission-Fixture": "allowed"]
        )
        let plan = HybridPlaybackPlan.make(
            request: request,
            externalSubtitles: [],
            admission: admission
        )
        XCTAssertEqual(plan.url, request.url)
        XCTAssertTrue(plan.options.nativeRemoteHLS)
        XCTAssertFalse(plan.options.isLive)
        XCTAssertEqual(
            plan.options.httpHeaders["X-Admission-Fixture"],
            "allowed"
        )
        XCTAssertFalse(plan.options.autoplay)
    }

    func testLiveMediaPlaylistAdmitsNativeRemoteHLSAsLive()
        async throws
    {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let admission = try await
            HybridRemoteSourceAdmission.classify(
                url: try XCTUnwrap(
                    URL(
                        string:
                            "https://admission-fixture.invalid/live-stream"
                    )
                ),
                httpHeaders: ["X-Admission-Fixture": "allowed"],
                session: session
            )

        XCTAssertEqual(admission, .hlsLive)
        XCTAssertTrue(admission.isConfirmedHLS)
        XCTAssertTrue(admission.isLiveHLS)
    }

    func testSingleVariantPQOnlyMasterResolvesValidatedMediaPlaylist()
        async throws
    {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let url = try XCTUnwrap(
            URL(string: "https://admission-fixture.invalid/pq-only-master")
        )
        let admission = try await HybridRemoteSourceAdmission.classify(
            url: url,
            httpHeaders: ["X-Admission-Fixture": "allowed"],
            session: session
        )
        let mediaURL = try XCTUnwrap(
            URL(string: "https://admission-fixture.invalid/pq-video")
        )

        XCTAssertEqual(
            admission,
            .hlsVODPQOnlyMaster(
                mediaPlaylistURL: mediaURL,
                duration: 10.5
            )
        )
        let request = try HybridPlaybackRequest(
            url: url,
            httpHeaders: ["X-Admission-Fixture": "allowed"]
        )
        let plan = HybridPlaybackPlan.make(
            request: request,
            externalSubtitles: [],
            admission: admission
        )
        XCTAssertEqual(plan.url, mediaURL)
        XCTAssertEqual(plan.sourceResolution, .resolvedPQMediaPlaylist)
        XCTAssertTrue(plan.options.nativeRemoteHLS)
        XCTAssertFalse(plan.options.isLive)
        XCTAssertEqual(
            plan.options.httpHeaders["X-Admission-Fixture"],
            "allowed"
        )
    }

    func testPQMasterWithExternalRenditionKeepsOriginalSource()
        async throws
    {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let url = try XCTUnwrap(
            URL(string: "https://admission-fixture.invalid/pq-audio-master")
        )
        let admission = try await HybridRemoteSourceAdmission.classify(
            url: url,
            httpHeaders: ["X-Admission-Fixture": "allowed"],
            session: session
        )

        XCTAssertEqual(admission, .hlsVOD)
        let request = try HybridPlaybackRequest(url: url)
        let plan = HybridPlaybackPlan.make(
            request: request,
            externalSubtitles: [],
            admission: admission
        )
        XCTAssertEqual(plan.url, url)
        XCTAssertEqual(plan.sourceResolution, .original)
    }

    func testMixedSDRAndPQMasterKeepsOriginalSource() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let url = try XCTUnwrap(
            URL(string: "https://admission-fixture.invalid/mixed-master")
        )
        let admission = try await HybridRemoteSourceAdmission.classify(
            url: url,
            httpHeaders: ["X-Admission-Fixture": "allowed"],
            session: session
        )

        XCTAssertEqual(admission, .hlsVOD)
        let request = try HybridPlaybackRequest(url: url)
        XCTAssertEqual(
            HybridPlaybackPlan.make(
                request: request,
                externalSubtitles: [],
                admission: admission
            ).url,
            url
        )
    }

    func testMultiplePQVariantsKeepOriginalSource() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let url = try XCTUnwrap(
            URL(string: "https://admission-fixture.invalid/multi-pq-master")
        )
        let admission = try await HybridRemoteSourceAdmission.classify(
            url: url,
            httpHeaders: ["X-Admission-Fixture": "allowed"],
            session: session
        )

        XCTAssertEqual(admission, .hlsVOD)
        let request = try HybridPlaybackRequest(url: url)
        XCTAssertEqual(
            HybridPlaybackPlan.make(
                request: request,
                externalSubtitles: [],
                admission: admission
            ).url,
            url
        )
    }

    func testFinitePrivateHEVCTransportStreamUsesAetherRemuxPath()
        async throws
    {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let url = try XCTUnwrap(
            URL(string: "https://admission-fixture.invalid/hevc-vod")
        )
        let admission = try await HybridRemoteSourceAdmission.classify(
            url: url,
            httpHeaders: ["X-Admission-Fixture": "allowed"],
            session: session
        )

        XCTAssertEqual(
            admission,
            .hlsVODHEVCMPEGTS(
                duration: 10.5,
                evidence: .registrationDescriptor(streamType: 0x06)
            )
        )
        XCTAssertEqual(admission.avKitProxyDuration, 10.5)
        let request = try HybridPlaybackRequest(url: url)
        let plan = HybridPlaybackPlan.make(
            request: request,
            externalSubtitles: [],
            admission: admission
        )
        XCTAssertFalse(plan.options.nativeRemoteHLS)
        XCTAssertFalse(plan.options.isLive)
    }

    func testAdmissionDiagnosticFieldsDescribeTerminalDecision() {
        XCTAssertEqual(
            HybridRemoteSourceAdmission.hlsVOD.diagnosticFields,
            "result=hls-vod"
        )
        XCTAssertEqual(
            HybridRemoteSourceAdmission
                .hlsVODPQOnlyMaster(
                    mediaPlaylistURL: URL(
                        string: "https://example.invalid/video.m3u8"
                    )!,
                    duration: 10.5
                )
                .diagnosticFields,
            "result=hls-vod-pq-only-master duration=10.500 "
                + "source=resolved-media-playlist"
        )
        XCTAssertEqual(
            HybridRemoteSourceAdmission
                .hlsVODHEVCMPEGTS(
                    duration: 10.5,
                    evidence: .registrationDescriptor(streamType: 0x06)
                )
                .diagnosticFields,
            "result=hls-vod-hevc-mpegts duration=10.500 "
                + "evidence=registration-HEVC-stream-type-06"
        )
        XCTAssertEqual(
            HybridRemoteSourceAdmission.hlsLive.diagnosticFields,
            "result=hls-live"
        )
        XCTAssertEqual(
            HybridRemoteSourceAdmission
                .aetherDefault(.requestFailed)
                .diagnosticFields,
            "result=aether-default reason=request-failed"
        )
        XCTAssertEqual(
            HybridRemoteSourceAdmission
                .aetherDefault(.httpStatus(503))
                .diagnosticFields,
            "result=aether-default reason=http-status status=503"
        )
    }

    func testForcedProxyUsesPlaylistDurationInsteadOfTransientEngineValue()
        throws
    {
        let duration = try HybridProxyDurationPolicy.duration(
            admission: .hlsVODHEVCMPEGTS(
                duration: 1_423.75,
                evidence: .standardStreamType(0x24)
            ),
            engineDuration: 0.01
        )

        XCTAssertEqual(duration, 1_423.75)
    }

    func testForcedProxyRejectsInvalidPlaylistDuration() {
        XCTAssertThrowsError(
            try HybridProxyDurationPolicy.duration(
                admission: .hlsVODHEVCMPEGTS(
                    duration: 0,
                    evidence: .standardStreamType(0x24)
                ),
                engineDuration: 0.01
            )
        ) { error in
            XCTAssertEqual(
                error as? HybridPlaybackError,
                .proxyDurationUnavailable
            )
        }
    }

    func testM3U8SuffixWithBinaryBodyFallsBackToAether()
        async throws
    {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let admission = try await
            HybridRemoteSourceAdmission.classify(
                url: try XCTUnwrap(
                    URL(
                        string:
                            "https://admission-fixture.invalid/fake.m3u8"
                    )
                ),
                httpHeaders: ["X-Admission-Fixture": "allowed"],
                session: session
            )

        XCTAssertEqual(
            admission,
            .aetherDefault(.confirmedNonHLS)
        )

        let request = try HybridPlaybackRequest(
            url: try XCTUnwrap(
                URL(
                    string:
                        "https://admission-fixture.invalid/fake.m3u8"
                )
            )
        )
        let plan = HybridPlaybackPlan.make(
            request: request,
            externalSubtitles: [],
            admission: admission
        )
        XCTAssertFalse(plan.options.nativeRemoteHLS)
        XCTAssertFalse(plan.options.isLive)
    }

    func testRequestFailureFallsBackToAether() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let admission = try await
            HybridRemoteSourceAdmission.classify(
                url: try XCTUnwrap(
                    URL(
                        string:
                            "https://admission-fixture.invalid/timeout"
                    )
                ),
                httpHeaders: ["X-Admission-Fixture": "allowed"],
                session: session
            )

        XCTAssertEqual(admission, .aetherDefault(.requestFailed))
    }

    func testHTTPFailureFallsBackWithStatus() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let admission = try await
            HybridRemoteSourceAdmission.classify(
                url: try XCTUnwrap(
                    URL(
                        string:
                            "https://admission-fixture.invalid/unavailable"
                    )
                ),
                httpHeaders: ["X-Admission-Fixture": "allowed"],
                session: session
            )

        XCTAssertEqual(admission, .aetherDefault(.httpStatus(503)))
    }

    func testIncompletePlaylistEvidenceFallsBackToAether()
        async throws
    {
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let admission = try await
            HybridRemoteSourceAdmission.classify(
                url: try XCTUnwrap(
                    URL(
                        string:
                            "https://admission-fixture.invalid/malformed"
                    )
                ),
                httpHeaders: ["X-Admission-Fixture": "allowed"],
                session: session
            )

        XCTAssertEqual(
            admission,
            .aetherDefault(.invalidPlaylist)
        )
    }

    func testProbeRecognizesEveryStandardHEVCStreamType() {
        for streamType: UInt8 in [0x24, 0x25, 0x28, 0x29, 0x2A, 0x2B, 0x31] {
            XCTAssertEqual(
                MPEGTransportStreamCodecProbe.classify(
                    hybridTransportStreamFixture(streamType: streamType)
                ),
                .hevcInMPEGTS(.standardStreamType(streamType)),
                "stream_type \(String(format: "%02X", streamType))"
            )
        }
    }

    func testProbeRecognizesPrivateHEVCRegistration() {
        let registration = Data([0x05, 0x04, 0x48, 0x45, 0x56, 0x43])
        for streamType: UInt8 in [0x06, 0x80, 0xFF] {
            XCTAssertEqual(
                MPEGTransportStreamCodecProbe.classify(
                    hybridTransportStreamFixture(
                        streamType: streamType,
                        descriptors: registration
                    )
                ),
                .hevcInMPEGTS(
                    .registrationDescriptor(streamType: streamType)
                )
            )
        }
    }

    func testProbeKeepsOrdinaryAVCAndUnregisteredPrivateCarriageNative() {
        XCTAssertEqual(
            MPEGTransportStreamCodecProbe.classify(
                hybridTransportStreamFixture(streamType: 0x1B)
            ),
            .otherCarriage
        )
        XCTAssertEqual(
            MPEGTransportStreamCodecProbe.classify(
                hybridTransportStreamFixture(
                    streamType: 0x06,
                    descriptors: Data([0x05, 0x04, 0x41, 0x43, 0x2D, 0x33])
                )
            ),
            .otherCarriage
        )
    }

    func testProbeTreatsMalformedDescriptorAsInconclusive() {
        XCTAssertEqual(
            MPEGTransportStreamCodecProbe.classify(
                hybridTransportStreamFixture(
                    streamType: 0x06,
                    descriptors: Data([0x05, 0x04, 0x48])
                )
            ),
            .inconclusive
        )
    }

    func testProbeReassemblesSplitPMTBeforeClassification() {
        XCTAssertEqual(
            MPEGTransportStreamCodecProbe.classify(
                splitHybridTransportStreamFixture()
            ),
            .hevcInMPEGTS(.registrationDescriptor(streamType: 0x06))
        )
    }
}

private final class HybridAdmissionFixtureURLProtocol:
    URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "admission-fixture.invalid"
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.value(
            forHTTPHeaderField: "X-Admission-Fixture"
        ) == "allowed",
        request.value(forHTTPHeaderField: "Range")?.hasPrefix(
            "bytes=0-"
        ) == true,
        let url = request.url else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.resourceUnavailable)
            )
            return
        }

        if url.lastPathComponent == "timeout" {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.timedOut)
            )
            return
        }

        let statusCode =
            url.lastPathComponent == "unavailable" ? 503 : 200
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
        ) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        if statusCode == 200 {
            client?.urlProtocol(
                self,
                didLoad: fixtureData(for: url.lastPathComponent)
            )
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func fixtureData(for name: String) -> Data {
        switch name {
        case "pq-only-master":
            Data(
                """
                #EXTM3U
                #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x535,VIDEO-RANGE=PQ
                pq-video
                """.utf8
            )
        case "pq-audio-master":
            Data(
                """
                #EXTM3U
                #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="stereo",NAME="Main",DEFAULT=YES,URI="audio"
                #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x535,VIDEO-RANGE=PQ,AUDIO="stereo"
                pq-video
                """.utf8
            )
        case "mixed-master":
            Data(
                """
                #EXTM3U
                #EXT-X-STREAM-INF:BANDWIDTH=700000,RESOLUTION=960x540,VIDEO-RANGE=SDR
                sdr-video
                #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x535,VIDEO-RANGE=PQ
                pq-video
                """.utf8
            )
        case "multi-pq-master":
            Data(
                """
                #EXTM3U
                #EXT-X-STREAM-INF:BANDWIDTH=700000,RESOLUTION=960x400,VIDEO-RANGE=PQ
                pq-video-low
                #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x535,VIDEO-RANGE=PQ
                pq-video
                """.utf8
            )
        case "pq-video", "pq-video-low", "sdr-video":
            Data(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:6
                #EXTINF:6,
                avc-segment.ts
                #EXTINF:4.5,
                avc-segment.ts
                #EXT-X-ENDLIST
                """.utf8
            )
        case "avc-segment.ts":
            hybridTransportStreamFixture(streamType: 0x1B)
        case "extensionless":
            Data(
                """
                #EXTM3U
                #EXT-X-STREAM-INF:BANDWIDTH=800000
                video
                """.utf8
            )
        case "video":
            Data(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:6
                #EXTINF:6,
                segment-0.ts
                #EXT-X-ENDLIST
                """.utf8
            )
        case "live-stream":
            Data(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:6
                #EXTINF:6,
                segment-live.ts
                """.utf8
            )
        case "hevc-vod":
            Data(
                """
                #EXTM3U
                #EXT-X-TARGETDURATION:6
                #EXTINF:6,
                hevc-segment.ts
                #EXTINF:4.5,
                hevc-segment.ts
                #EXT-X-ENDLIST
                """.utf8
            )
        case "hevc-segment.ts":
            hybridTransportStreamFixture(
                streamType: 0x06,
                descriptors: Data([0x05, 0x04, 0x48, 0x45, 0x56, 0x43])
            )
        case "malformed":
            Data(
                """
                #EXTM3U
                # This is extended M3U text, not a usable HLS playlist.
                """.utf8
            )
        case "fake.m3u8":
            Data([
                0x00, 0x00, 0x00, 0x18,
                0x66, 0x74, 0x79, 0x70,
            ])
        default:
            Data()
        }
    }

}

private func hybridTransportStreamFixture(
    streamType: UInt8,
    descriptors: Data = Data()
) -> Data {
    var bytes = [UInt8](repeating: 0xFF, count: 188 * 3)
    for packet in 0..<3 {
        bytes[packet * 188] = 0x47
        bytes[packet * 188 + 3] = 0x10
    }
    bytes[1] = 0x40
    bytes[2] = 0x64
    bytes[4] = 0
    bytes[5] = 0x02
    bytes[6] = 0xB0
    bytes[7] = UInt8(18 + descriptors.count)
    bytes[8] = 0
    bytes[9] = 1
    bytes[10] = 0xC1
    bytes[11] = 0
    bytes[12] = 0
    bytes[13] = 0xE1
    bytes[14] = 0
    bytes[15] = 0xF0
    bytes[16] = 0
    bytes[17] = streamType
    bytes[18] = 0xE1
    bytes[19] = 1
    bytes[20] = 0xF0 | UInt8((descriptors.count >> 8) & 0x0F)
    bytes[21] = UInt8(descriptors.count & 0xFF)
    bytes.replaceSubrange(22..<(22 + descriptors.count), with: descriptors)
    return Data(bytes)
}

private func splitHybridTransportStreamFixture() -> Data {
    let descriptors = Data(
        [0x40, 0xA0]
            + [UInt8](repeating: 0, count: 160)
            + [0x05, 0x04, 0x48, 0x45, 0x56, 0x43]
    )
    let sectionLength = 18 + descriptors.count
    var section = [UInt8](repeating: 0, count: 3 + sectionLength)
    section[0] = 0x02
    section[1] = 0xB0 | UInt8((sectionLength >> 8) & 0x0F)
    section[2] = UInt8(sectionLength & 0xFF)
    section[4] = 1
    section[5] = 0xC1
    section[8] = 0xE1
    section[10] = 0xF0
    section[12] = 0x06
    section[13] = 0xE1
    section[14] = 1
    section[15] = 0xF0 | UInt8((descriptors.count >> 8) & 0x0F)
    section[16] = UInt8(descriptors.count & 0xFF)
    section.replaceSubrange(17..<(17 + descriptors.count), with: descriptors)

    var packets = [UInt8](repeating: 0xFF, count: 188 * 3)
    packets[0] = 0x47
    packets[1] = 0x40
    packets[2] = 0x64
    packets[3] = 0x10
    packets[4] = 0
    let firstCount = min(183, section.count)
    packets.replaceSubrange(5..<(5 + firstCount), with: section[..<firstCount])

    packets[188] = 0x47
    packets[189] = 0x00
    packets[190] = 0x64
    packets[191] = 0x10
    let remaining = section.dropFirst(firstCount)
    packets.replaceSubrange(192..<(192 + remaining.count), with: remaining)

    packets[376] = 0x47
    packets[379] = 0x10
    return Data(packets)
}
