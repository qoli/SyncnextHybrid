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
        let options = HybridPlaybackLoadOptions.make(
            request: request,
            externalSubtitles: [],
            admission: admission
        )
        XCTAssertTrue(options.nativeRemoteHLS)
        XCTAssertFalse(options.isLive)
        XCTAssertEqual(
            options.httpHeaders["X-Admission-Fixture"],
            "allowed"
        )
        XCTAssertFalse(options.autoplay)
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

    func testFiniteHEVCTransportStreamUsesAetherRemuxPath()
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
            .hlsVODHEVCMPEGTS(duration: 10.5)
        )
        XCTAssertEqual(admission.avKitProxyDuration, 10.5)
        let request = try HybridPlaybackRequest(url: url)
        let options = HybridPlaybackLoadOptions.make(
            request: request,
            externalSubtitles: [],
            admission: admission
        )
        XCTAssertFalse(options.nativeRemoteHLS)
        XCTAssertFalse(options.isLive)
    }

    func testForcedProxyUsesPlaylistDurationInsteadOfTransientEngineValue()
        throws
    {
        let duration = try HybridProxyDurationPolicy.duration(
            admission: .hlsVODHEVCMPEGTS(duration: 1_423.75),
            engineDuration: 0.01
        )

        XCTAssertEqual(duration, 1_423.75)
    }

    func testForcedProxyRejectsInvalidPlaylistDuration() {
        XCTAssertThrowsError(
            try HybridProxyDurationPolicy.duration(
                admission: .hlsVODHEVCMPEGTS(duration: 0),
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
        let options = HybridPlaybackLoadOptions.make(
            request: request,
            externalSubtitles: [],
            admission: admission
        )
        XCTAssertFalse(options.nativeRemoteHLS)
        XCTAssertFalse(options.isLive)
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
            hevcTransportStreamFixture()
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

    private func hevcTransportStreamFixture() -> Data {
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
        bytes[7] = 18
        bytes[8] = 0
        bytes[9] = 1
        bytes[10] = 0xC1
        bytes[11] = 0
        bytes[12] = 0
        bytes[13] = 0xE1
        bytes[14] = 0
        bytes[15] = 0xF0
        bytes[16] = 0
        bytes[17] = 0x24
        bytes[18] = 0xE1
        bytes[19] = 1
        bytes[20] = 0xF0
        bytes[21] = 0
        return Data(bytes)
    }
}
