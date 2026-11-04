import CryptoKit
import Foundation
import Testing
@testable import AetherEngine

extension PrewarmStoreSuites {
    @Suite("HTTP disc MIME recognition (AE#860)", .serialized, .offCooperativePool, .timeLimit(.minutes(2)))
    struct HTTPDiscRetirementTests {
        private var image: Data {
            let vob = PrewarmStoreSuites.RemoteDiscSessionReleaseTests.vob
            let sector = ISO9660Fixture.sectorSize
            var image = ISO9660Fixture.make(files: [
                .init(name: "VTS_01_1.VOB", length: vob.count, content: [UInt8](vob.prefix(sector))),
            ])
            image.append(vob.dropFirst(sector))
            return image
        }

        private func url(_ origin: KeepAliveRangeOrigin, path: String = "play/opaque-id") -> URL {
            URL(string: "http://127.0.0.1:\(origin.port)/\(path)")!
        }

        // Reuse the existing MPEG-2 VOB fixture: this must open a real video stream after adapting
        // the ISO filesystem, rather than merely failing differently on a recognised signature.
        private func expectDisc(_ demuxer: Demuxer, url: URL,
                                profile: DemuxerOpenProfile = .playback) throws {
            try demuxer.open(url: url, profile: profile)
            #expect(demuxer.isDiscSource)
            #expect(!demuxer.discTitles.isEmpty)
            #expect(demuxer.videoStreamIndex >= 0)
        }

        @Test("Extensionless ISO uses the disc adapter on both HTTP transports",
              arguments: [false, true],
              ["application/x-iso9660-image", "Application/X-ISO9660-Image; charset=binary"])
        func extensionlessISO(held: Bool, contentType: String) throws {
            let origin = try #require(KeepAliveRangeOrigin(data: image, contentType: contentType))
            defer { origin.stop() }
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try expectDisc(demuxer, url: url(origin), profile: .playback.withHeldSourceConnection(held))
        }

        @Test("Extensionless ISO with generic MIME reaches the real disc title",
              arguments: [false, true],
              ["application/octet-stream", "Application/Octet-Stream; charset=binary"])
        func genericMIMEISO(held: Bool, contentType: String) throws {
            let vob = PrewarmStoreSuites.RemoteDiscSessionReleaseTests.vob
            let sector = ISO9660Fixture.sectorSize
            // A real image need not carry a media signature in libavformat's initial probe.
            // Keep the title at 4 MiB so raw-container scanning cannot make this pass.
            var bytes = ISO9660Fixture.make(files: [
                .init(name: "VTS_01_1.VOB", length: vob.count, content: [UInt8](vob.prefix(sector))),
            ], firstFileLBA: 2048)
            bytes.append(vob.dropFirst(sector))
            let origin = try #require(KeepAliveRangeOrigin(data: bytes, contentType: contentType))
            defer { origin.stop() }
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try expectDisc(demuxer, url: url(origin), profile: .playback.withHeldSourceConnection(held))
        }

        @Test("A UDF Blu-ray with generic MIME is validated by the existing disc reader",
              arguments: [false, true])
        func genericMIMEBluRay(held: Bool) throws {
            var item = Array("00001M2TS".utf8)
            item += ISO9660Fixture.be16(0); item.append(0)
            item += ISO9660Fixture.be32(0); item += ISO9660Fixture.be32(90_000)
            item += [UInt8](repeating: 0, count: 8)
            var playlist = ISO9660Fixture.be32(0)
            playlist += ISO9660Fixture.be16(0); playlist += ISO9660Fixture.be16(1)
            playlist += ISO9660Fixture.be16(0); playlist += ISO9660Fixture.be16(item.count)
            playlist += item
            var mpls = Array("MPLS0200".utf8)
            mpls += ISO9660Fixture.be32(40); mpls += ISO9660Fixture.be32(0)
            mpls += [UInt8](repeating: 0, count: 40 - mpls.count)
            mpls += playlist
            // Keep the complete transport stream in both extents. The empty CLPI is optional.
            var bytes = UDFFixture.make(mplsBytes: mpls,
                                       m2tsBytes: Array(TinyTransportStreamFixture.data), clpiBytes: [])
            for (index, identifier) in ["BEA01", "NSR03", "TEA01"].enumerated() {
                let offset = (16 + index) * UDFFixture.ss
                bytes.replaceSubrange(offset..<(offset + 7), with: [0] + Array(identifier.utf8) + [1])
            }
            let origin = try #require(KeepAliveRangeOrigin(data: bytes,
                                                         contentType: "application/octet-stream"))
            defer { origin.stop() }
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try expectDisc(demuxer, url: url(origin), profile: .playback.withHeldSourceConnection(held))
        }

        @Test("A prewarmed extensionless ISO retains its representation type",
              arguments: ["application/x-iso9660-image", "application/octet-stream"])
        func prewarmedISO(contentType: String) async throws {
            let bytes = image
            let origin = try #require(KeepAliveRangeOrigin(data: bytes,
                                                         contentType: contentType))
            defer { origin.stop() }
            let source = url(origin)
            let report = await SourcePrewarmFetcher.warm(url: source, extraHeaders: [:],
                                                         byteBudget: bytes.count)
            #expect(report.retainedBytes == bytes.count)
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try expectDisc(demuxer, url: source)
        }

        @Test("An ordinary extensionless source adds no disc or HEAD probe",
              arguments: [false, true], ["video/mp2t", "application/octet-stream"])
        func ordinaryMedia(held: Bool, contentType: String) throws {
            let origin = try #require(KeepAliveRangeOrigin(data: TinyTransportStreamFixture.data,
                                                         contentType: contentType))
            defer { origin.stop() }
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: url(origin), profile: .playback.withHeldSourceConnection(held))
            #expect(!demuxer.isDiscSource)
            #expect(demuxer.videoStreamIndex >= 0)
            #expect(!origin.requests.contains { $0.hasPrefix("HEAD ") })
            #expect(!origin.requests.contains { $0.contains("bytes=0-0\r\n") })
        }

        @Test("ISO MIME alone does not turn ordinary media into a disc")
        func mislabelledMedia() throws {
            let origin = try #require(KeepAliveRangeOrigin(data: TinyTransportStreamFixture.data,
                                                         contentType: "application/x-iso9660-image"))
            defer { origin.stop() }
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: url(origin))
            #expect(!demuxer.isDiscSource)
            #expect(demuxer.videoStreamIndex >= 0)
        }

        @Test("A generic response with only an ISO signature is not a playable disc",
              arguments: [false, true])
        func genericMIMESignatureWithoutFilesystem(held: Bool) throws {
            var bytes = Data(repeating: 0, count: 257 * ISO9660Fixture.sectorSize)
            let offset = 16 * ISO9660Fixture.sectorSize
            bytes.replaceSubrange(offset..<(offset + 7), with: [1] + Array("CD001".utf8) + [1])
            let origin = try #require(KeepAliveRangeOrigin(data: bytes,
                                                         contentType: "application/octet-stream"))
            defer { origin.stop() }
            let demuxer = Demuxer()
            defer { demuxer.close() }
            #expect(throws: (any Error).self) {
                try demuxer.open(url: url(origin), profile: .playback.withHeldSourceConnection(held))
            }
            #expect(!demuxer.isDiscSource)
        }

        @Test("The existing ISO suffix still works with generic MIME")
        func suffixISO() throws {
            let origin = try #require(KeepAliveRangeOrigin(data: image,
                                                         contentType: "application/octet-stream"))
            defer { origin.stop() }
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try expectDisc(demuxer, url: url(origin, path: "disc.iso"))
        }

        @Test("A seekable extraction open also reads the actual response MIME",
              arguments: ["application/x-iso9660-image", "application/octet-stream"])
        func seekableISO(contentType: String) throws {
            let origin = try #require(KeepAliveRangeOrigin(data: image,
                                                         contentType: contentType))
            defer { origin.stop() }
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try expectDisc(demuxer, url: url(origin), profile: .stillExtraction)
        }

        @Test("Cancellation at the reported source stage aborts open without subsequent requests",
              arguments: ["application/x-iso9660-image", "application/octet-stream"])
        func cancelAtReportedSourceStage(contentType: String) async throws {
            let origin = try #require(KeepAliveRangeOrigin(data: image, contentType: contentType))
            defer { origin.stop() }
            let demuxer = Demuxer()
            defer { demuxer.close() }
            let cancelled = ProbeTestBox(false)
            let requestsAtCancel = ProbeTestBox(0)
            demuxer.onOpenProgress = { [weak demuxer] stage in
                if case .sourceOpened = stage {
                    cancelled.update { $0 = true }
                    requestsAtCancel.update { $0 = origin.requests.count }
                    demuxer?.markClosed()
                }
            }
            #expect(throws: (any Error).self) { try demuxer.open(url: url(origin)) }
            #expect(cancelled.value, "the cancellation must actually have been issued")
            // The real provider may be the adapted disc. Its metadata and earlier
            // requests are not evidence of work after this cancellation.
            demuxer.close()
            #expect(origin.requests.count == requestsAtCancel.value, "no request may start after cancellation")
        }

        @Test("Cancellation on the real opening response prevents a subsequent disc probe",
              arguments: [false, true],
              ["application/x-iso9660-image", "application/octet-stream"])
        func cancelOnOpeningResponse(held: Bool, contentType: String) async throws {
            let origin = try #require(KeepAliveRangeOrigin(data: image, contentType: contentType))
            defer { origin.stop() }
            let source = url(origin)
            let sourceID = SHA256.hash(data: Data(source.absoluteString.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let demuxer = Demuxer()
            defer { demuxer.close() }
            let cancelled = ProbeTestBox(false)
            let finished = ProbeTestBox(false)
            let previous = MediaRequestDiagnostics.handler
            defer { MediaRequestDiagnostics.handler = previous }
            MediaRequestDiagnostics.handler = { [weak demuxer] line in
                guard line.contains("sourceID=\(sourceID)") else { return }
                if line.contains("event=finished ") { finished.update { $0 = true } }
                guard line.contains("event=response ") else { return }
                cancelled.update { $0 = true }
                demuxer?.markClosed()
            }
            #expect(throws: (any Error).self) {
                try demuxer.open(url: source, profile: .playback.withHeldSourceConnection(held))
            }
            #expect(cancelled.value, "the origin's response must trigger cancellation")
            #expect(!demuxer.isDiscSource)
            #expect(!origin.requests.contains { $0.contains("bytes=0-0\r\n") })
            demuxer.close()
            // The shared AVIO chunk session may retain an idle keep-alive socket.
            // Completion of the actual cancelled transfer is the ownership contract.
            try await waitFor { finished.value }
        }

        @Test("Declared sequential origins retain their forward-only request contract",
              arguments: ["application/x-iso9660-image", "application/octet-stream"])
        func sequentialMedia(contentType: String) throws {
            let origin = try #require(KeepAliveRangeOrigin(data: TinyTransportStreamFixture.data,
                                                         contentType: contentType))
            defer { origin.stop() }
            let demuxer = Demuxer()
            defer { demuxer.close() }
            try demuxer.open(url: url(origin),
                             profile: .playback.withSequentialOrigin(true, declaredDuration: 8))
            #expect(!demuxer.isDiscSource)
            #expect(!origin.requests.contains { $0.lowercased().contains("range:") })
        }
    }
}
