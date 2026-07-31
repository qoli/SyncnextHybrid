import XCTest
@testable import SyncnextHybrid

final class HybridHLSProxyPlaylistTests: XCTestCase {
    func testPlaylistPublishesFiniteAuthoritativeDuration() throws {
        let playlist = try HybridHLSProxyPlaylist.make(duration: 2.25)

        XCTAssertTrue(playlist.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        XCTAssertTrue(playlist.hasSuffix("#EXT-X-ENDLIST\n"))
        XCTAssertEqual(
            playlist.components(separatedBy: "#EXTINF:").count - 1,
            3
        )
        XCTAssertTrue(playlist.contains("#EXTINF:0.250000,"))
        XCTAssertTrue(playlist.contains("segment-2.ts"))
    }

    func testPlaylistUsesOneContinuousTimestampEpoch() throws {
        let playlist = try HybridHLSProxyPlaylist.make(duration: 3)

        XCTAssertFalse(playlist.contains("#EXT-X-DISCONTINUITY"))
        XCTAssertTrue(playlist.contains("segment-0.ts"))
        XCTAssertTrue(playlist.contains("segment-2.ts"))
    }

    func testSegmentShiftMovesRealFixturePESByPlaylistPosition()
        throws
    {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Sources/SyncnextHybrid/Resources/black-proxy.ts"
            )
        let fixture = try Data(contentsOf: fixtureURL)
        let baseline = try XCTUnwrap(
            HybridMPEGTSProxySegment.shifted(
                fixture,
                segmentIndex: 0
            )
        )
        let shifted = try XCTUnwrap(
            HybridMPEGTSProxySegment.shifted(
                fixture,
                segmentIndex: 10
            )
        )

        XCTAssertNotEqual(baseline, shifted)
        let baselinePTS = try XCTUnwrap(firstPESStamp(in: baseline))
        let shiftedPTS = try XCTUnwrap(firstPESStamp(in: shifted))
        XCTAssertEqual(shiftedPTS - baselinePTS, 900_000)
    }

    func testPlaylistRejectsMissingDurationWithoutFallback() {
        let invalidDurations: [Double] = [
            0,
            -.infinity,
            .infinity,
            .nan,
        ]
        for duration in invalidDurations {
            XCTAssertThrowsError(
                try HybridHLSProxyPlaylist.make(duration: duration)
            ) { error in
                XCTAssertEqual(
                    error as? HybridPlaybackError,
                    .proxyDurationUnavailable
                )
            }
        }
    }

    func testSeekDemandWindowIsChosenByProxyTimeline() {
        XCTAssertFalse(
            HybridHLSProxyReleasePolicy.canRelease(
                segmentStart: 36,
                authoritativePlayhead: 5,
                bufferedThrough: 81,
                duration: 100,
                lead: 3
            )
        )
        XCTAssertTrue(
            HybridHLSProxyReleasePolicy.canRelease(
                segmentStart: 36,
                authoritativePlayhead: 36,
                bufferedThrough: 81,
                duration: 100,
                lead: 3
            )
        )
        XCTAssertFalse(
            HybridHLSProxyReleasePolicy.canRelease(
                segmentStart: 82,
                authoritativePlayhead: 82,
                bufferedThrough: 81,
                duration: 100,
                lead: 3
            )
        )
    }

    func testServerAuthorityOwnsClockRateWaitingAndSeekGeneration() {
        var authority = HybridHLSTimelineAuthority(
            duration: 2_000,
            initialPosition: 10,
            uptime: 100
        )

        XCTAssertEqual(authority.snapshot(uptime: 100).phase, .loading)
        authority.markReady(uptime: 100)
        XCTAssertEqual(authority.snapshot(uptime: 100).phase, .paused)

        authority.setRate(1, uptime: 100)
        let playing = authority.snapshot(uptime: 103)
        XCTAssertEqual(playing.phase, .playing)
        XCTAssertEqual(playing.currentTime, 13, accuracy: 0.001)

        authority.update(
            material: HybridHLSProxyMaterial(
                phase: .waiting,
                bufferedThrough: 20
            ),
            uptime: 103
        )
        let waiting = authority.snapshot(uptime: 108)
        XCTAssertEqual(waiting.phase, .waitingToPlay)
        XCTAssertEqual(waiting.currentTime, 13, accuracy: 0.001)

        XCTAssertEqual(authority.seek(to: 913, uptime: 108), 1)
        let seekWaiting = authority.snapshot(uptime: 113)
        XCTAssertEqual(seekWaiting.phase, .waitingToPlay)
        XCTAssertEqual(seekWaiting.currentTime, 913)
        XCTAssertTrue(
            authority.recordResolvedSegment(
                913,
                requestGeneration: 1,
                uptime: 108
            )
        )
        XCTAssertEqual(
            authority.snapshot(uptime: 108).resolvedSegmentIndices,
            [913]
        )

        authority.update(
            material: HybridHLSProxyMaterial(
                phase: .flowing,
                bufferedThrough: 920
            ),
            uptime: 113
        )
        let flowing = authority.snapshot(uptime: 115)
        XCTAssertEqual(flowing.phase, .playing)
        XCTAssertEqual(flowing.currentTime, 915, accuracy: 0.001)

        XCTAssertEqual(authority.seek(to: 30, uptime: 115), 2)
        XCTAssertFalse(
            authority.recordResolvedSegment(
                914,
                requestGeneration: 1,
                uptime: 115
            )
        )
        XCTAssertEqual(
            authority.snapshot(uptime: 108).resolvedSegmentIndices,
            []
        )

        XCTAssertEqual(authority.seek(to: 60, uptime: 116), 3)
        XCTAssertFalse(
            authority.recordResolvedSegment(
                30,
                requestGeneration: 2,
                uptime: 130
            )
        )
        let latestStillWaiting = authority.snapshot(uptime: 135)
        XCTAssertEqual(latestStillWaiting.phase, .waitingToPlay)
        XCTAssertEqual(latestStillWaiting.currentTime, 60, accuracy: 0.001)
        XCTAssertTrue(
            authority.recordResolvedSegment(
                60,
                requestGeneration: 3,
                uptime: 135
            )
        )
        XCTAssertEqual(
            authority.snapshot(uptime: 136).currentTime,
            61,
            accuracy: 0.001
        )
    }

    func testAetherMaterialOnlyProjectsWaitingAndTerminalState() {
        var authority = HybridHLSTimelineAuthority(
            duration: 100,
            initialPosition: 10,
            uptime: 100
        )
        authority.markReady(uptime: 100)
        authority.setRate(1, uptime: 100)

        authority.update(
            material: HybridHLSProxyMaterial(
                phase: .waiting,
                bufferedThrough: 10
            ),
            uptime: 101
        )
        let waiting = authority.snapshot(uptime: 105)
        XCTAssertEqual(waiting.phase, .waitingToPlay)
        XCTAssertEqual(waiting.currentTime, 11, accuracy: 0.001)
        XCTAssertEqual(waiting.rate, 1)

        authority.update(
            material: HybridHLSProxyMaterial(
                phase: .flowing,
                bufferedThrough: 20
            ),
            uptime: 105
        )
        XCTAssertEqual(authority.snapshot(uptime: 106).phase, .playing)

        authority.update(
            material: HybridHLSProxyMaterial(
                phase: .failed("network"),
                bufferedThrough: 20
            ),
            uptime: 106
        )
        XCTAssertEqual(
            authority.snapshot(uptime: 107).phase,
            .failed("network")
        )

        authority.update(
            material: HybridHLSProxyMaterial(
                phase: .ended,
                bufferedThrough: 100
            ),
            uptime: 107
        )
        XCTAssertEqual(authority.snapshot(uptime: 108).phase, .ended)
    }

    private func firstPESStamp(in data: Data) -> UInt64? {
        let bytes = Array(data)
        for packetStart in stride(from: 0, to: bytes.count, by: 188) {
            guard packetStart + 188 <= bytes.count,
                  bytes[packetStart] == 0x47 else {
                return nil
            }
            let control = (bytes[packetStart + 3] >> 4) & 0x03
            guard control == 1 || control == 3,
                  bytes[packetStart + 1] & 0x40 != 0 else {
                continue
            }
            var payloadStart = packetStart + 4
            if control == 3 {
                payloadStart += 1 + Int(bytes[packetStart + 4])
            }
            guard payloadStart + 14 <= packetStart + 188,
                  bytes[payloadStart] == 0,
                  bytes[payloadStart + 1] == 0,
                  bytes[payloadStart + 2] == 1,
                  ((bytes[payloadStart + 7] >> 6) & 0x03) >= 2 else {
                continue
            }
            let offset = payloadStart + 9
            return
                (UInt64((bytes[offset] >> 1) & 0x07) << 30)
                | (UInt64(bytes[offset + 1]) << 22)
                | (UInt64((bytes[offset + 2] >> 1) & 0x7f) << 15)
                | (UInt64(bytes[offset + 3]) << 7)
                | UInt64((bytes[offset + 4] >> 1) & 0x7f)
        }
        return nil
    }
}
