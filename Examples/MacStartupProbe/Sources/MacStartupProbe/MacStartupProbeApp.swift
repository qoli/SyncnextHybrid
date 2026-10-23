import AetherEngine
import AetherLibavutil
import AppKit
import AVFoundation
import Combine
import CoreVideo
import Darwin
import SwiftUI

@main
struct MacStartupProbeApp: App {
    @NSApplicationDelegateAdaptor(ProbeAppDelegate.self) private var delegate
    @StateObject private var model = StartupModel()

    var body: some Scene {
        Window("Syncnext Mac Startup Probe", id: "main") {
            ZStack(alignment: .topLeading) {
                Color.black
                if let engine = model.engine {
                    AetherPlayerSurface(engine: engine)
                }
                Text(model.status)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.65))
                    .padding(16)
            }
            .frame(minWidth: 960, minHeight: 540)
            .task { await model.run() }
        }
        .windowResizability(.contentMinSize)
    }
}

final class ProbeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class StartupModel: ObservableObject {
    @Published private(set) var engine: AetherEngine?
    @Published private(set) var status = "macOS 起播基線：等待私人 fixture"
    private let started = ProcessInfo.processInfo.systemUptime
    private var hasRun = false
    private var output: FileHandle?
    private var observation: AnyCancellable?
    private var engineLog: ProbeEngineLog?
    private var previousFFmpegLogLevel: Int32?

    private struct Fixture: Decodable {
        let url: URL
        let httpHeaders: [String: String]
        let probeBytes: Int64?
        let observationSeconds: Double
        let startupDeadlineSeconds: Double
        let outputDirectory: String
        let exitWhenFinished: Bool?
        let captureProbeDetails: Bool?
        let seekPlan: ProbeSeekMeasurement.Plan?
    }

    private enum Failure: Error { case invalidFixture, unsupportedRoute, playbackFailed, startupTimeout }

    func run() async {
        guard !hasRun else { return }
        hasRun = true
        var exitWhenFinished = false
        defer {
            observation?.cancel()
            restoreFFmpegLogLevel()
            engine?.stop()
            MediaRequestDiagnostics.handler = nil
            EngineLog.handler = nil
            engineLog?.close()
            fflush(stdout)
            fflush(stderr)
            try? output?.close()
            if exitWhenFinished { NSApp.terminate(nil) }
        }
        do {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "--fixture"), index + 1 < arguments.count else {
                throw Failure.invalidFixture
            }
            let fixture = try JSONDecoder().decode(
                Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
            )
            guard fixture.observationSeconds.isFinite, fixture.observationSeconds > 0,
                  fixture.startupDeadlineSeconds.isFinite, fixture.startupDeadlineSeconds > 0,
                  fixture.probeBytes.map({ $0 >= 32 }) ?? true else { throw Failure.invalidFixture }
            exitWhenFinished = fixture.exitWhenFinished ?? false
            let directory = URL(fileURLWithPath: fixture.outputDirectory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let file = directory.appendingPathComponent("events.jsonl")
            guard !FileManager.default.fileExists(atPath: file.path), FileManager.default.createFile(
                atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]
            ) else { throw Failure.invalidFixture }
            output = try FileHandle(forWritingTo: file)
            // LaunchServices output redirection can reject this local bundle.
            // Capture the engine's console in this run's private directory.
            for (name, stream) in [("engine.stdout.private.log", stdout), ("engine.stderr.private.log", stderr)] {
                let log = directory.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: log.path), FileManager.default.createFile(
                    atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]
                ), freopen(log.path, "a", stream) != nil else { throw Failure.invalidFixture }
            }
            emit("started", ["probe_bytes": fixture.probeBytes.map { $0 as Any } ?? NSNull(),
                             "forward_buffer_preference": 4, "muted": true,
                             "pid": ProcessInfo.processInfo.processIdentifier,
                             "capture_probe_details": fixture.captureProbeDetails ?? false])
            let log = try ProbeEngineLog(directory: directory)
            engineLog = log
            EngineLog.handler = { line in log.append(line) }
            MediaRequestDiagnostics.handler = { line in
                log.append("MEDIA_REQUEST " + line)
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
            let active = try AetherEngine()
            engine = active
            if fixture.captureProbeDetails == true {
                previousFFmpegLogLevel = av_log_get_level()
                av_log_set_level(AV_LOG_DEBUG)
            }
            observation = active.$startupProgress.removeDuplicates().sink { [weak self] progress in
                guard let self, let progress else { return }
                self.emit("engine_checkpoint", ["checkpoint": String(describing: progress.checkpoint),
                                                "generation": progress.generation])
                if progress.checkpoint == .streamsProbed { self.restoreFFmpegLogLevel() }
            }
            // The representable mounts the engine surface before the source opens.
            await Task.yield()
            var options = LoadOptions(httpHeaders: fixture.httpHeaders, heldSourceConnection: true,
                                      probesize: fixture.probeBytes,
                                      autoplay: false)
            options.progressiveSegmentDelivery = true
            emit("renderer_load_begin")
            try await active.load(url: fixture.url, options: options)
            emit("renderer_load_completed")
            guard let player = active.currentAVPlayer else { throw Failure.unsupportedRoute }
            player.isMuted = true
            if !active.isLive, active.videoRoute == .loopback {
                player.currentItem?.preferredForwardBufferDuration = 4
            }
            let context = PlayerReadContext(player: player)
            await Task.detached { context.installFrameOutput() }.value
            emit("configured", [
                "video_route": active.videoRoute.rawValue,
                "backend": String(describing: active.playbackBackend),
                "video_width": active.sourceVideoWidth, "video_height": active.sourceVideoHeight,
                "video_frame_rate": active.sourceVideoFrameRate.map { $0 as Any } ?? NSNull(),
                "video_codec": active.sourceVideoCodecName.map { $0 as Any } ?? NSNull(),
                "audio_tracks": active.audioTracks.map { ["id": $0.id, "codec": $0.codec,
                                                          "language": $0.language.map { $0 as Any } ?? NSNull(),
                                                          "channels": $0.channels] as [String: Any] },
                "subtitle_tracks": active.subtitleTracks.map { ["id": $0.id, "codec": $0.codec,
                                                                "language": $0.language.map { $0 as Any } ?? NSNull()] as [String: Any] },
                "subtitle_descriptors": active.subtitleTracks.map { ["id": $0.id, "name": $0.name,
                                                                      "forced": $0.isForced] as [String: Any] },
                "active_subtitle_at_load": active.activeSubtitleTrackIndex.map { $0 as Any } ?? NSNull(),
                "window_id": NSApp.windows.first(where: \.isVisible).map { $0.windowNumber as Any } ?? NSNull()
            ])
            emit("play_requested")
            active.play()
            var previous: PlayerReadContext.Sample?
            var previousAt = ProcessInfo.processInfo.systemUptime
            var movingAt: Double?
            var firstPlaying = false
            var firstDecodedFrame = false
            var provedTwoSeconds = false
            var waiting = 0.0
            var moving = 0.0
            var lastSampleAt = 0.0
            while true {
                try Task.checkCancellation()
                let sample = await Task.detached { context.read() }.value
                let now = ProcessInfo.processInfo.systemUptime
                let step = now - previousAt
                if sample.failed { throw Failure.playbackFailed }
                if case .error = active.playbackPhase { throw Failure.playbackFailed }
                if sample.decodedFrame, !firstDecodedFrame {
                    firstDecodedFrame = true
                    emit("first_decoded_frame")
                }
                if sample.playing, sample.time > 0, !firstPlaying {
                    firstPlaying = true
                    emit("first_playing")
                }
                if let previous {
                    if movingAt != nil, previous.waiting { waiting += step }
                    let delta = sample.time - previous.time
                    if sample.playing, previous.playing, delta > 0, delta <= step + 0.5 {
                        if movingAt == nil {
                            movingAt = now
                            emit("first_verified_progress")
                        } else { moving += delta }
                    }
                }
                if moving >= 2, !provedTwoSeconds {
                    provedTwoSeconds = true
                    emit("two_seconds_progress")
                }
                if now - lastSampleAt >= 1 {
                    emit("sample", ["media_time": sample.time, "buffer_seconds": sample.ahead,
                                    "duration_seconds": sample.duration.map { $0 as Any } ?? NSNull(),
                                    "playing": sample.playing, "waiting": sample.waiting,
                                    "source_time": active.sourceTime,
                                    "active_subtitle": active.activeSubtitleTrackIndex.map { $0 as Any } ?? NSNull(),
                                    "subtitle_cue_count": active.subtitleCues.count,
                                    "forward_buffer_preference": sample.preference])
                    status = String(format: "macOS 靜音基線  t=%.1fs  buffer=%.1fs", sample.time, sample.ahead)
                    lastSampleAt = now
                }
                if let movingAt, now - movingAt >= fixture.observationSeconds {
                    guard firstDecodedFrame else { throw Failure.playbackFailed }
                    if let plan = fixture.seekPlan {
                        try await ProbeSeekMeasurement.run(plan: plan, engine: active, context: context) { [weak self] event, fields in
                            self?.emit(event, fields)
                            if let label = fields["seek_label"] as? String {
                                if event == "seek_requested" {
                                    self?.status = "macOS seek：\(label)（等待目標畫面與進度）"
                                } else if event == "seek_resumed",
                                          let time = fields["media_time"] as? Double,
                                          let ahead = fields["buffer_seconds"] as? Double {
                                    self?.status = String(format: "macOS seek %@ 已恢復  t=%.1fs  buffer=%.1fs", label, time, ahead)
                                }
                            }
                        }
                    }
                    emit("finished", ["outcome": "completed", "observation_seconds": now - movingAt,
                                      "moving_media_seconds": moving, "waiting_seconds": waiting])
                    status = "macOS 基線測量完成"
                    return
                }
                if movingAt == nil, now - started > fixture.startupDeadlineSeconds {
                    throw Failure.startupTimeout
                }
                previous = sample
                previousAt = now
                try await Task.sleep(for: .milliseconds(provedTwoSeconds ? 1000 : 100))
            }
        } catch {
            let failure = error as NSError
            emit("finished", ["outcome": "failed", "error_domain": failure.domain, "error_code": failure.code])
            status = "基線失敗：\(failure.domain)/\(failure.code)"
        }
    }

    private func emit(_ event: String, _ fields: [String: Any] = [:]) {
        let now = ProcessInfo.processInfo.systemUptime
        var row = fields.merging(["event": event, "uptime_seconds": now, "elapsed_seconds": now - started,
                                 "epoch_seconds": Date().timeIntervalSince1970]) { _, new in new }
        if let cpu = ProbeCPUUsage.read() {
            row["process_cpu_user_seconds"] = cpu.user
            row["process_cpu_system_seconds"] = cpu.system
        }
        do {
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(0x0A)
            if let output { try output.write(contentsOf: data) }
            else { FileHandle.standardError.write(data) }
        } catch {
            FileHandle.standardError.write(Data("MAC_STARTUP_PROBE event-write-failed\n".utf8))
        }
    }

    private func restoreFFmpegLogLevel() {
        if let previousFFmpegLogLevel {
            av_log_set_level(previousFFmpegLogLevel)
            self.previousFFmpegLogLevel = nil
        }
    }
}

/// Reads AVFoundation off the main actor, including stalled IPC. The frame
/// witness is a decoded pixel buffer; it does not assert onscreen presentation.
final class PlayerReadContext: @unchecked Sendable {
    struct Sample: Sendable {
        let time: Double, ahead: Double, duration: Double?, preference: Double
        let playing: Bool, waiting: Bool, failed: Bool, decodedFrame: Bool
        let frameTime: Double?, itemIdentity: String?
    }
    private let player: AVPlayer
    private let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    private var decodedFrame = false
    private var frameTime: Double?
    private var seekFrameTarget: Double?
    private var seekFrameStartedAt = 0.0

    init(player: AVPlayer) { self.player = player }
    func installFrameOutput() { player.currentItem?.add(videoOutput) }

    func prepareSeekFrameWitness(target: Double) {
        decodedFrame = false
        frameTime = nil
        seekFrameTarget = target
        seekFrameStartedAt = ProcessInfo.processInfo.systemUptime
    }

    func read() -> Sample {
        let item = player.currentItem
        let clock = item?.currentTime() ?? .zero
        let time = clock.seconds.isFinite ? clock.seconds : 0
        let duration = item?.duration.seconds
        var end = time
        for range in (item?.loadedTimeRanges ?? []).map(\.timeRangeValue).sorted(by: { $0.start.seconds < $1.start.seconds }) {
            let lower = range.start.seconds, upper = (range.start + range.duration).seconds
            guard lower.isFinite, upper.isFinite else { continue }
            if lower > end + 0.001 { break }
            end = max(end, upper)
        }
        if !decodedFrame, videoOutput.hasNewPixelBuffer(forItemTime: clock) {
            var displayed = CMTime.invalid
            if videoOutput.copyPixelBuffer(forItemTime: clock, itemTimeForDisplay: &displayed) != nil,
               displayed.seconds.isFinite {
                let seconds = displayed.seconds
                let age = ProcessInfo.processInfo.systemUptime - seekFrameStartedAt
                if seekFrameTarget.map({ seconds >= $0 - 0.75 && seconds <= $0 + age + 1 }) ?? true {
                    decodedFrame = true
                    frameTime = seconds
                }
            }
        }
        return Sample(time: time, ahead: max(0, end - time),
                      duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                      preference: item?.preferredForwardBufferDuration ?? -1,
                      playing: player.timeControlStatus == .playing,
                      waiting: player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                      failed: item?.status == .failed, decodedFrame: decodedFrame,
                      frameTime: frameTime, itemIdentity: item.map { String(describing: ObjectIdentifier($0)) })
    }
}
