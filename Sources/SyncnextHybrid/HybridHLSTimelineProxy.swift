import Foundation

enum HybridHLSProxySupplyPhase: Equatable {
    case flowing
    case waiting
    case ended
    case failed(String)
}

struct HybridHLSProxyMaterial: Equatable {
    let phase: HybridHLSProxySupplyPhase
    let bufferedThrough: Double
}

enum HybridHLSProxyPlaylist {
    static let segmentDuration: Double = 1

    static func make(duration: Double) throws -> String {
        guard duration.isFinite, duration > 0 else {
            throw HybridPlaybackError.proxyDurationUnavailable
        }
        let segmentCount = Int(ceil(duration / segmentDuration))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:1",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        lines.reserveCapacity(7 + segmentCount * 2)
        for index in 0..<segmentCount {
            let start = Double(index) * segmentDuration
            let remaining = duration - start
            lines.append(
                String(
                    format: "#EXTINF:%.6f,",
                    min(segmentDuration, remaining)
                )
            )
            lines.append("segment-\(index).ts")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Pure release policy for Aether material entering the authoritative HLS
/// timeline. The Proxy chooses the demand window; Aether only bounds which
/// requested segments have enough backing material to be released.
enum HybridHLSProxyReleasePolicy {
    static func canRelease(
        segmentStart: Double,
        authoritativePlayhead: Double,
        bufferedThrough: Double,
        duration: Double,
        lead: Double
    ) -> Bool {
        segmentStart < min(bufferedThrough, authoritativePlayhead + lead)
            || segmentStart >= duration - 0.001
    }
}

struct HybridHLSTimelineState: Equatable {
    let phase: HybridPlaybackPhase
    let currentTime: Double
    let duration: Double
    let rate: Float
    let seekGeneration: UInt64
    let resolvedSegmentIndices: [Int]
}

enum HybridHLSTimelineEvent: Equatable {
    case stateChanged(HybridHLSTimelineState)
    case transportRateChanged(
        Float,
        origin: HybridHLSTransportInputOrigin
    )
    case seekRequested(generation: UInt64, target: Double)
}

enum HybridHLSTransportInputOrigin: Equatable {
    case command
    case clientObservation
}

/// The HLS Proxy Server clock. AVPlayer is a client and may submit control
/// input, but its currentTime/timeControlStatus never replace this state.
struct HybridHLSTimelineAuthority {
    private let duration: Double
    private(set) var currentTime: Double
    private(set) var rate: Float = 0
    private(set) var seekGeneration: UInt64 = 0
    private var resolvedSegmentIndices: [Int] = []
    private var pendingSeekGeneration: UInt64?
    private var materialPhase: HybridHLSProxySupplyPhase = .flowing
    private var ready = false
    private var lastUptime: TimeInterval

    init(
        duration: Double,
        initialPosition: Double,
        uptime: TimeInterval
    ) {
        self.duration = duration
        currentTime = min(duration, max(0, initialPosition))
        lastUptime = uptime
    }

    mutating func markReady(uptime: TimeInterval) {
        advance(to: uptime)
        ready = true
    }

    mutating func setRate(
        _ newRate: Float,
        uptime: TimeInterval
    ) {
        advance(to: uptime)
        rate = max(0, newRate)
    }

    mutating func seek(
        to seconds: Double,
        uptime: TimeInterval
    ) -> UInt64 {
        advance(to: uptime)
        seekGeneration &+= 1
        pendingSeekGeneration = seekGeneration
        resolvedSegmentIndices.removeAll(keepingCapacity: true)
        currentTime = min(duration, max(0, seconds))
        lastUptime = uptime
        return seekGeneration
    }

    mutating func recordResolvedSegment(
        _ index: Int,
        requestGeneration: UInt64,
        uptime: TimeInterval
    ) -> Bool {
        advance(to: uptime)
        guard requestGeneration == seekGeneration else {
            return false
        }
        pendingSeekGeneration = nil
        resolvedSegmentIndices.removeAll { $0 == index }
        resolvedSegmentIndices.append(index)
        if resolvedSegmentIndices.count > 16 {
            resolvedSegmentIndices.removeFirst(
                resolvedSegmentIndices.count - 16
            )
        }
        return true
    }

    mutating func update(
        material: HybridHLSProxyMaterial,
        uptime: TimeInterval
    ) {
        advance(to: uptime)
        materialPhase = material.phase
    }

    mutating func snapshot(
        uptime: TimeInterval
    ) -> HybridHLSTimelineState {
        advance(to: uptime)
        return HybridHLSTimelineState(
            phase: phase,
            currentTime: currentTime,
            duration: duration,
            rate: rate,
            seekGeneration: seekGeneration,
            resolvedSegmentIndices: resolvedSegmentIndices
        )
    }

    private var phase: HybridPlaybackPhase {
        guard ready else {
            return .loading
        }
        if case .failed(let message) = materialPhase {
            return .failed(message)
        }
        if pendingSeekGeneration != nil {
            return rate == 0 ? .paused : .waitingToPlay
        }
        switch materialPhase {
        case .failed:
            preconditionFailure("handled above")
        case .ended:
            return .ended
        case .waiting:
            return rate == 0 ? .paused : .waitingToPlay
        case .flowing:
            return rate == 0 ? .paused : .playing
        }
    }

    private mutating func advance(to uptime: TimeInterval) {
        defer { lastUptime = uptime }
        guard uptime >= lastUptime,
              phase == .playing else {
            return
        }
        currentTime = min(
            duration,
            currentTime + (uptime - lastUptime) * Double(rate)
        )
        if currentTime >= duration {
            materialPhase = .ended
            rate = 0
        }
    }
}

/// Produces a continuous MPEG-TS epoch from the tiny bundled fixture.
///
/// HLS seeks are resolved against media timestamps, not only EXTINF values.
/// Re-serving byte-identical one-second segments leaves every segment around
/// PTS 1.4s, so AVPlayer cannot land on a distant playlist position. Shift
/// timestamp-bearing fields and continuity counters by the requested segment
/// index while keeping the encoded H.264/AAC payload untouched.
enum HybridMPEGTSProxySegment {
    private static let packetSize = 188
    private static let timestampModulo: UInt64 = 1 << 33
    private static let ticksPerSegment: UInt64 = 90_000

    static func shifted(_ source: Data, segmentIndex: Int) -> Data? {
        guard segmentIndex >= 0,
              !source.isEmpty,
              source.count.isMultiple(of: packetSize) else {
            return nil
        }
        var bytes = Array(source)
        var payloadPacketCounts = [UInt16: Int]()
        for packetStart in stride(
            from: 0,
            to: bytes.count,
            by: packetSize
        ) {
            guard bytes[packetStart] == 0x47 else {
                return nil
            }
            let control = (bytes[packetStart + 3] >> 4) & 0x03
            guard control != 0 else {
                return nil
            }
            if control == 1 || control == 3 {
                let pid = packetPID(bytes, at: packetStart)
                payloadPacketCounts[pid, default: 0] += 1
            }
        }

        let timestampOffset = (
            UInt64(segmentIndex) * ticksPerSegment
        ) % timestampModulo
        for packetStart in stride(
            from: 0,
            to: bytes.count,
            by: packetSize
        ) {
            let control = (bytes[packetStart + 3] >> 4) & 0x03
            let hasAdaptation = control == 2 || control == 3
            let hasPayload = control == 1 || control == 3
            let pid = packetPID(bytes, at: packetStart)
            if hasPayload, let count = payloadPacketCounts[pid] {
                let original = Int(bytes[packetStart + 3] & 0x0f)
                let shifted = (
                    original + segmentIndex * count
                ) & 0x0f
                bytes[packetStart + 3] =
                    (bytes[packetStart + 3] & 0xf0) | UInt8(shifted)
            }

            var payloadStart = packetStart + 4
            if hasAdaptation {
                let adaptationLength = Int(bytes[packetStart + 4])
                guard packetStart + 5 + adaptationLength
                        <= packetStart + packetSize else {
                    return nil
                }
                if adaptationLength >= 7,
                   bytes[packetStart + 5] & 0x10 != 0 {
                    shiftPCR(
                        &bytes,
                        at: packetStart + 6,
                        by: timestampOffset
                    )
                }
                payloadStart = packetStart + 5 + adaptationLength
            }
            guard hasPayload,
                  bytes[packetStart + 1] & 0x40 != 0,
                  payloadStart + 14 <= packetStart + packetSize,
                  bytes[payloadStart] == 0,
                  bytes[payloadStart + 1] == 0,
                  bytes[payloadStart + 2] == 1 else {
                continue
            }
            let timestampFlags = (bytes[payloadStart + 7] >> 6) & 0x03
            if timestampFlags == 2 || timestampFlags == 3 {
                shiftPESStamp(
                    &bytes,
                    at: payloadStart + 9,
                    by: timestampOffset
                )
            }
            if timestampFlags == 3 {
                shiftPESStamp(
                    &bytes,
                    at: payloadStart + 14,
                    by: timestampOffset
                )
            }
        }
        return Data(bytes)
    }

    private static func packetPID(
        _ bytes: [UInt8],
        at packetStart: Int
    ) -> UInt16 {
        (UInt16(bytes[packetStart + 1] & 0x1f) << 8)
            | UInt16(bytes[packetStart + 2])
    }

    private static func shiftPCR(
        _ bytes: inout [UInt8],
        at offset: Int,
        by timestampOffset: UInt64
    ) {
        let base =
            (UInt64(bytes[offset]) << 25)
            | (UInt64(bytes[offset + 1]) << 17)
            | (UInt64(bytes[offset + 2]) << 9)
            | (UInt64(bytes[offset + 3]) << 1)
            | UInt64(bytes[offset + 4] >> 7)
        let shifted = (base + timestampOffset) % timestampModulo
        bytes[offset] = UInt8(truncatingIfNeeded: shifted >> 25)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: shifted >> 17)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: shifted >> 9)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: shifted >> 1)
        bytes[offset + 4] =
            UInt8(truncatingIfNeeded: (shifted & 1) << 7)
            | (bytes[offset + 4] & 0x7f)
    }

    private static func shiftPESStamp(
        _ bytes: inout [UInt8],
        at offset: Int,
        by timestampOffset: UInt64
    ) {
        let value =
            (UInt64((bytes[offset] >> 1) & 0x07) << 30)
            | (UInt64(bytes[offset + 1]) << 22)
            | (UInt64((bytes[offset + 2] >> 1) & 0x7f) << 15)
            | (UInt64(bytes[offset + 3]) << 7)
            | UInt64((bytes[offset + 4] >> 1) & 0x7f)
        let shifted = (value + timestampOffset) % timestampModulo
        let prefix = bytes[offset] & 0xf0
        bytes[offset] = prefix
            | UInt8(truncatingIfNeeded: ((shifted >> 30) & 0x07) << 1)
            | 1
        bytes[offset + 1] = UInt8(truncatingIfNeeded: shifted >> 22)
        bytes[offset + 2] =
            UInt8(truncatingIfNeeded: ((shifted >> 15) & 0x7f) << 1)
            | 1
        bytes[offset + 3] = UInt8(truncatingIfNeeded: shifted >> 7)
        bytes[offset + 4] =
            UInt8(truncatingIfNeeded: (shifted & 0x7f) << 1)
            | 1
    }
}

#if os(tvOS)
import AVFoundation
import CryptoKit
import Darwin

@MainActor
final class HybridHLSTimelineProxy {
    let player: AVPlayer

    private let server: HybridHLSProxyServer
    private var stateTimer: Timer?
    private var eventHandler: (@MainActor (HybridHLSTimelineEvent) -> Void)?
    private var lastEmittedState: HybridHLSTimelineState?

    init(
        duration: Double,
        initialPosition: Double,
        initialBufferedThrough: Double
    ) async throws {
        guard let segmentURL = Bundle.module.url(
            forResource: "black-proxy",
            withExtension: "ts"
        ), let segmentData = try? Data(contentsOf: segmentURL) else {
            throw HybridPlaybackError.proxyAssetUnavailable
        }
        let digest = SHA256.hash(data: segmentData)
            .map { String(format: "%02x", $0) }
            .joined()
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_PROXY_ASSET "
                + "name=black-proxy.ts sha256=\(digest)"
        )
        guard HybridMPEGTSProxySegment.shifted(
            segmentData,
            segmentIndex: 0
        ) != nil else {
            throw HybridPlaybackError.proxyAssetInvalid
        }

        let playlist = try HybridHLSProxyPlaylist.make(
            duration: duration
        )
        let server = HybridHLSProxyServer(
            playlist: Data(playlist.utf8),
            segment: segmentData,
            duration: duration,
            initialPlayhead: initialPosition,
            initialBufferedThrough: max(
                initialBufferedThrough,
                // AVPlayer inspects more than one MPEG-TS epoch before it
                // declares an HLS item ready. This bounded bootstrap is
                // Proxy metadata, not an Aether buffer claim; subsequent
                // segment release is governed by Aether material.
                initialPosition + 3
            )
        )
        do {
            try server.start()
        } catch {
            throw HybridPlaybackError.proxyServerUnavailable(
                String(describing: error)
            )
        }
        self.server = server

        let asset = AVURLAsset(url: server.playlistURL)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player

        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while item.status == .unknown,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard item.status == .readyToPlay else {
            HybridDiagnosticEmitter.emit(
                "SYNCNEXT_HYBRID_PROXY_HLS_START_FAILED "
                    + "status=\(item.status.rawValue) "
                    + "error=\(String(describing: item.error))"
            )
            server.stop()
            throw HybridPlaybackError.proxyAssetInvalid
        }
        server.markTimelineReady()

        let videoTracks = item.tracks.filter {
            $0.assetTrack?.mediaType == .video
        }
        guard !videoTracks.isEmpty else {
            server.stop()
            throw HybridPlaybackError.proxyAssetInvalid
        }
        for track in videoTracks {
            track.isEnabled = false
        }
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_PROXY_HLS "
                + "url=\(server.playlistURL.absoluteString) "
                + "duration=\(duration) "
                + "segments=\(Int(ceil(duration)))"
        )
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_PROXY_VIDEO_TRACK "
                + "count=\(videoTracks.count) "
                + "enabled=\(videoTracks.contains { $0.isEnabled })"
        )

        stateTimer = Timer.scheduledTimer(
            withTimeInterval: 0.25,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emitStateIfChanged()
            }
        }
    }

    func update(material: HybridHLSProxyMaterial) {
        server.update(material: material)
        emitStateIfChanged()
    }

    func setEventHandler(
        _ handler: @escaping @MainActor (
            HybridHLSTimelineEvent
        ) -> Void
    ) {
        eventHandler = handler
        emitStateIfChanged(force: true)
    }

    var state: HybridHLSTimelineState {
        server.timelineState()
    }

    func commandRate(_ rate: Float) {
        setRate(rate, origin: .command)
    }

    func acceptClientRate(_ rate: Float) {
        setRate(rate, origin: .clientObservation)
    }

    private func setRate(
        _ rate: Float,
        origin: HybridHLSTransportInputOrigin
    ) {
        let previousRate = server.timelineState().rate
        server.setTimelineRate(rate)
        guard abs(previousRate - rate) > 0.0001 else {
            return
        }
        eventHandler?(.transportRateChanged(rate, origin: origin))
        emitStateIfChanged()
    }

    /// Moves the authoritative HLS demand window before AVPlayer asks for
    /// the destination segment. Aether still decides whether that material
    /// is available through `bufferedThrough`; it does not choose the time.
    @discardableResult
    func prepareSeek(to seconds: Double) -> UInt64 {
        let target = min(state.duration, max(0, seconds))
        let generation = server.seekTimeline(to: target)
        server.updatePlayhead(target)
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_PROXY_DEMAND "
                + "event=seek-prepared generation=\(generation) "
                + "target=\(target)"
        )
        eventHandler?(
            .seekRequested(generation: generation, target: target)
        )
        emitStateIfChanged()
        return generation
    }

    /// Allows destination material to leave the Server only when Aether
    /// answers the same operation. The authoritative clock stays waiting
    /// until the Server resolves that generation's first segment.
    @discardableResult
    func acknowledgeSeekResponse(generation: UInt64) -> Bool {
        let acknowledged = server.acknowledgeSeekResponse(
            generation: generation
        )
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_PROXY_DEMAND "
                + "event=seek-response generation=\(generation) "
                + "acknowledged=\(acknowledged)"
        )
        emitStateIfChanged()
        return acknowledged
    }

    private func emitStateIfChanged(force: Bool = false) {
        let state = server.timelineState()
        server.updatePlayhead(state.currentTime)
        guard force || state != lastEmittedState else {
            return
        }
        lastEmittedState = state
        eventHandler?(.stateChanged(state))
    }

    func stop() {
        stateTimer?.invalidate()
        stateTimer = nil
        server.stop()
    }

    deinit {
        server.stop()
    }
}

private final class HybridHLSProxySupply: @unchecked Sendable {
    enum Result {
        case data(Data)
        case failed(String)
        case stopped
    }

    private let condition = NSCondition()
    private let segment: Data
    private let duration: Double
    private let lead: Double = 3
    private var playhead: Double
    private var bufferedThrough: Double
    private var phase: HybridHLSProxySupplyPhase = .flowing
    private var pendingSeekGeneration: UInt64?
    private var stopped = false

    init(
        segment: Data,
        duration: Double,
        initialPlayhead: Double,
        initialBufferedThrough: Double
    ) {
        self.segment = segment
        self.duration = duration
        playhead = max(0, initialPlayhead)
        bufferedThrough = max(0, initialBufferedThrough)
    }

    func update(material: HybridHLSProxyMaterial) {
        condition.lock()
        phase = material.phase
        bufferedThrough = max(0, material.bufferedThrough)
        condition.broadcast()
        condition.unlock()
    }

    func updatePlayhead(_ value: Double) {
        guard value.isFinite else {
            return
        }
        condition.lock()
        playhead = max(0, value)
        condition.broadcast()
        condition.unlock()
    }

    func beginSeek(generation: UInt64) {
        condition.lock()
        pendingSeekGeneration = generation
        condition.broadcast()
        condition.unlock()
    }

    func acknowledgeSeekResponse(generation: UInt64) -> Bool {
        condition.lock()
        guard pendingSeekGeneration == generation else {
            condition.unlock()
            return false
        }
        pendingSeekGeneration = nil
        condition.broadcast()
        condition.unlock()
        return true
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    func waitForSegment(at index: Int) -> Result {
        let segmentStart = Double(index)
            * HybridHLSProxyPlaylist.segmentDuration
        condition.lock()
        defer { condition.unlock() }
        while true {
            if stopped {
                return .stopped
            }
            if pendingSeekGeneration != nil {
                condition.wait()
                continue
            }
            switch phase {
            case .failed(let message):
                return .failed(message)
            case .ended:
                return segmentResult(at: index)
            case .flowing:
                if HybridHLSProxyReleasePolicy.canRelease(
                    segmentStart: segmentStart,
                    authoritativePlayhead: playhead,
                    bufferedThrough: bufferedThrough,
                    duration: duration,
                    lead: lead
                ) {
                    return segmentResult(at: index)
                }
            case .waiting:
                break
            }
            condition.wait()
        }
    }

    private func segmentResult(at index: Int) -> Result {
        guard let shifted = HybridMPEGTSProxySegment.shifted(
            segment,
            segmentIndex: index
        ) else {
            return .failed("invalid MPEG-TS proxy fixture")
        }
        return .data(shifted)
    }
}

private final class HybridHLSTimelineAuthorityStore:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var authority: HybridHLSTimelineAuthority

    init(duration: Double, initialPosition: Double) {
        authority = HybridHLSTimelineAuthority(
            duration: duration,
            initialPosition: initialPosition,
            uptime: ProcessInfo.processInfo.systemUptime
        )
    }

    func markReady() {
        lock.lock()
        authority.markReady(
            uptime: ProcessInfo.processInfo.systemUptime
        )
        lock.unlock()
    }

    func setRate(_ rate: Float) {
        lock.lock()
        authority.setRate(
            rate,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        lock.unlock()
    }

    func seek(to seconds: Double) -> UInt64 {
        lock.lock()
        let generation = authority.seek(
            to: seconds,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        lock.unlock()
        return generation
    }

    func update(material: HybridHLSProxyMaterial) {
        lock.lock()
        authority.update(
            material: material,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        lock.unlock()
    }

    func recordResolvedSegment(
        _ index: Int,
        requestGeneration: UInt64
    ) -> Bool {
        lock.lock()
        let accepted = authority.recordResolvedSegment(
            index,
            requestGeneration: requestGeneration,
            uptime: ProcessInfo.processInfo.systemUptime
        )
        lock.unlock()
        return accepted
    }

    func snapshot() -> HybridHLSTimelineState {
        lock.lock()
        let state = authority.snapshot(
            uptime: ProcessInfo.processInfo.systemUptime
        )
        lock.unlock()
        return state
    }
}

private final class HybridHLSProxyServer: @unchecked Sendable {
    private let playlist: Data
    private let supply: HybridHLSProxySupply
    private let authority: HybridHLSTimelineAuthorityStore
    private let segmentCount: Int
    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(
        label: "com.qoli.syncnexthybrid.hls-proxy.accept",
        qos: .userInitiated
    )
    private let workQueue = DispatchQueue(
        label: "com.qoli.syncnexthybrid.hls-proxy.work",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var listenFD: Int32 = -1
    private var clientFDs = Set<Int32>()
    private var port: UInt16 = 0
    private var stopping = false

    var playlistURL: URL {
        URL(string: "http://127.0.0.1:\(port)/timeline.m3u8")!
    }

    init(
        playlist: Data,
        segment: Data,
        duration: Double,
        initialPlayhead: Double,
        initialBufferedThrough: Double
    ) {
        self.playlist = playlist
        segmentCount = Int(ceil(duration))
        supply = HybridHLSProxySupply(
            segment: segment,
            duration: duration,
            initialPlayhead: initialPlayhead,
            initialBufferedThrough: initialBufferedThrough
        )
        authority = HybridHLSTimelineAuthorityStore(
            duration: duration,
            initialPosition: initialPlayhead
        )
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            throw HybridHLSProxyServerError.socket(errno)
        }
        var enabled: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_REUSEADDR,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.bind(
                    fd,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard didBind == 0 else {
            let code = errno
            close(fd)
            throw HybridHLSProxyServerError.bind(code)
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw HybridHLSProxyServerError.listen(code)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didResolve = withUnsafeMutablePointer(to: &actual) {
            pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                getsockname(fd, $0, &length)
            }
        }
        guard didResolve == 0 else {
            let code = errno
            close(fd)
            throw HybridHLSProxyServerError.getsockname(code)
        }
        stateLock.lock()
        listenFD = fd
        port = UInt16(bigEndian: actual.sin_port)
        stopping = false
        stateLock.unlock()
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func update(material: HybridHLSProxyMaterial) {
        supply.update(material: material)
        authority.update(material: material)
    }

    func markTimelineReady() {
        authority.markReady()
    }

    func setTimelineRate(_ rate: Float) {
        authority.setRate(rate)
    }

    func seekTimeline(to seconds: Double) -> UInt64 {
        let generation = authority.seek(to: seconds)
        supply.beginSeek(generation: generation)
        return generation
    }

    func acknowledgeSeekResponse(generation: UInt64) -> Bool {
        // Aether's response makes the destination material eligible for
        // release. The authoritative clock remains waiting until this Server
        // actually resolves the first segment for the same generation.
        return supply.acknowledgeSeekResponse(generation: generation)
    }

    func timelineState() -> HybridHLSTimelineState {
        authority.snapshot()
    }

    func recordResolvedSegment(
        _ index: Int,
        requestGeneration: UInt64
    ) -> Bool {
        authority.recordResolvedSegment(
            index,
            requestGeneration: requestGeneration
        )
    }

    func updatePlayhead(_ value: Double) {
        supply.updatePlayhead(value)
    }

    func stop() {
        stateLock.lock()
        guard !stopping else {
            stateLock.unlock()
            return
        }
        stopping = true
        let listener = listenFD
        listenFD = -1
        let clients = clientFDs
        clientFDs.removeAll()
        stateLock.unlock()
        supply.stop()
        if listener >= 0 {
            shutdown(listener, SHUT_RDWR)
            close(listener)
        }
        for client in clients {
            shutdown(client, SHUT_RDWR)
        }
    }

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let listener = listenFD
            let shouldStop = stopping
            stateLock.unlock()
            guard !shouldStop, listener >= 0 else {
                return
            }
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EBADF || errno == EINVAL {
                    return
                }
                continue
            }
            var enabled: Int32 = 1
            _ = setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)
            )
            stateLock.lock()
            clientFDs.insert(client)
            stateLock.unlock()
            workQueue.async { [weak self] in
                self?.handle(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        defer {
            stateLock.lock()
            clientFDs.remove(client)
            stateLock.unlock()
            close(client)
        }
        guard let target = readTarget(client) else {
            return
        }
        if target == "/timeline.m3u8" {
            sendResponse(
                client,
                status: "200 OK",
                contentType: "application/vnd.apple.mpegurl",
                body: playlist
            )
            return
        }
        guard let index = Self.segmentIndex(from: target),
              index >= 0, index < segmentCount else {
            sendResponse(
                client,
                status: "404 Not Found",
                contentType: "text/plain",
                body: Data("not found".utf8)
            )
            return
        }
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_PROXY_HLS_REQUEST "
                + "event=received segment=\(index)"
        )
        let requestGeneration = authority.snapshot().seekGeneration
        let waitStarted = ProcessInfo.processInfo.systemUptime
        let result = supply.waitForSegment(at: index)
        let waited = ProcessInfo.processInfo.systemUptime - waitStarted
        let outcome: String
        switch result {
        case .data:
            outcome = "released"
        case .failed:
            outcome = "failed"
        case .stopped:
            outcome = "stopped"
        }
        let isAuthoritativeResolution: Bool
        if case .data = result {
            isAuthoritativeResolution = recordResolvedSegment(
                index,
                requestGeneration: requestGeneration
            )
        } else {
            isAuthoritativeResolution = false
        }
        HybridDiagnosticEmitter.emit(
            "SYNCNEXT_HYBRID_PROXY_HLS_REQUEST "
                + "event=resolved segment=\(index) "
                + "generation=\(requestGeneration) "
                + "authoritative=\(isAuthoritativeResolution) "
                + "outcome=\(outcome) "
                + "waited=\(String(format: "%.3f", waited))"
        )
        switch result {
        case .data(let data):
            sendResponse(
                client,
                status: "200 OK",
                contentType: "video/mp2t",
                body: data
            )
        case .failed(let message):
            sendResponse(
                client,
                status: "500 Internal Server Error",
                contentType: "text/plain",
                body: Data(message.utf8)
            )
        case .stopped:
            return
        }
    }

    private func readTarget(_ client: Int32) -> String? {
        var bytes = [UInt8](repeating: 0, count: 8192)
        let count = recv(client, &bytes, bytes.count, 0)
        guard count > 0,
              let request = String(
                bytes: bytes.prefix(count),
                encoding: .utf8
              ),
              let line = request.components(
                separatedBy: "\r\n"
              ).first else {
            return nil
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }
        return String(parts[1]).split(separator: "?").first.map(String.init)
    }

    private func sendResponse(
        _ client: Int32,
        status: String,
        contentType: String,
        body: Data
    ) {
        let header = Data(
            (
                "HTTP/1.1 \(status)\r\n"
                    + "Content-Type: \(contentType)\r\n"
                    + "Content-Length: \(body.count)\r\n"
                    + "Cache-Control: no-store\r\n"
                    + "Connection: close\r\n\r\n"
            ).utf8
        )
        guard sendAll(header, to: client) else {
            return
        }
        _ = sendAll(body, to: client)
    }

    private func sendAll(_ data: Data, to client: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                return true
            }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(
                    client,
                    base.advanced(by: sent),
                    raw.count - sent,
                    0
                )
                if count > 0 {
                    sent += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private static func segmentIndex(from path: String) -> Int? {
        guard path.hasPrefix("/segment-"), path.hasSuffix(".ts") else {
            return nil
        }
        return Int(path.dropFirst(9).dropLast(3))
    }
}

private enum HybridHLSProxyServerError: Error {
    case socket(Int32)
    case bind(Int32)
    case listen(Int32)
    case getsockname(Int32)
}
#endif
