import AetherEngine
import AVFoundation
import Foundation

/// Opt-in native macOS observation. It never changes engine seek, recovery or buffering policy.
@MainActor
enum ProbeSeekMeasurement {
    struct Plan: Decodable {
        enum Input: String, Decodable {
            case aetherPublicSeek
            case nativeAVPlayerSeek
        }
        struct Step: Decodable {
            let label: String
            let targetSeconds: Double?
            let relativeSeconds: Double?
        }
        let steps: [Step]
        let recoveryDeadlineSeconds: Double
        let minimumProgressSeconds: Double
        let settleProgressSeconds: Double
        let sampleIntervalSeconds: Double
        let input: Input?
    }

    private enum Failure: Error {
        case invalidPlan, playbackFailed, changedBufferPreference, settleTimeout, seekTimeout, seekInterrupted
    }

    static func run(
        plan: Plan, engine: AetherEngine, context: PlayerReadContext,
        emit: @escaping (String, [String: Any]) -> Void
    ) async throws {
        guard !plan.steps.isEmpty,
              [plan.recoveryDeadlineSeconds, plan.minimumProgressSeconds,
               plan.settleProgressSeconds, plan.sampleIntervalSeconds].allSatisfy({ $0.isFinite && $0 > 0 }),
              plan.steps.allSatisfy({ step in
                  (step.targetSeconds == nil) != (step.relativeSeconds == nil)
                      && (step.targetSeconds ?? step.relativeSeconds ?? .nan).isFinite
              }) else { throw Failure.invalidPlan }
        for (index, step) in plan.steps.enumerated() {
            let settleAt = ProcessInfo.processInfo.systemUptime
            var previous = await Task.detached { context.read() }.value
            var previousAt = settleAt
            var settledProgress = 0.0
            while settledProgress < plan.settleProgressSeconds {
                try await Task.sleep(for: .seconds(plan.sampleIntervalSeconds))
                let sample = await Task.detached { context.read() }.value
                let now = ProcessInfo.processInfo.systemUptime
                try requireHealth(sample, engine: engine)
                if sample.playing, previous.playing, sample.time > previous.time,
                   sample.time - previous.time <= now - previousAt + 0.5 {
                    settledProgress += sample.time - previous.time
                } else { settledProgress = 0 }
                guard now - settleAt < plan.recoveryDeadlineSeconds else { throw Failure.settleTimeout }
                previous = sample
                previousAt = now
            }
            let target = step.targetSeconds ?? (previous.time + (step.relativeSeconds ?? 0))
            guard target >= 0, let duration = previous.duration, target < duration else { throw Failure.invalidPlan }
            await Task.detached { context.prepareSeekFrameWitness(target: target) }.value
            let seekAt = ProcessInfo.processInfo.systemUptime
            let base: [String: Any] = ["seek_index": index, "seek_label": step.label,
                                       "target_seconds": target]
            func mark(_ event: String, _ fields: [String: Any] = [:]) {
                emit(event, base.merging(fields) { _, new in new })
            }
            mark("seek_requested", ["from_seconds": previous.time, "buffer_seconds": previous.ahead,
                                    "input": (plan.input ?? .aetherPublicSeek).rawValue,
                                    "item_identity": previous.itemIdentity ?? "unavailable"])
            var apiReturnedAt: Double?
            var apiInterrupted = false
            let operation = Task { @MainActor in
                mark("seek_api_dispatched")
                switch plan.input ?? .aetherPublicSeek {
                case .aetherPublicSeek:
                    await engine.seek(to: target)
                case .nativeAVPlayerSeek:
                    guard let player = engine.currentAVPlayer else {
                        apiInterrupted = true
                        return
                    }
                    let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                    toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                            continuation.resume(returning: finished)
                        }
                    }
                    apiInterrupted = !completed
                }
                apiReturnedAt = ProcessInfo.processInfo.systemUptime
                mark("seek_api_returned", ["api_seconds": apiReturnedAt! - seekAt,
                                           "engine_time": engine.currentTime, "source_time": engine.sourceTime,
                                           "engine_seeking": engine.isSeeking, "interrupted": apiInterrupted])
            }
            defer { operation.cancel() }
            var firstFrameAt: Double?
            var firstProgressAt: Double?
            var progress = 0.0
            var waiting = 0.0
            var lastLogAt = 0.0
            previousAt = seekAt
            while true {
                try Task.checkCancellation()
                let sample = await Task.detached { context.read() }.value
                let now = ProcessInfo.processInfo.systemUptime
                try requireHealth(sample, engine: engine)
                guard !apiInterrupted else { throw Failure.seekInterrupted }
                if previous.waiting { waiting += now - previousAt }
                if sample.itemIdentity != previous.itemIdentity {
                    mark("seek_item_replaced", ["item_identity": sample.itemIdentity ?? "unavailable"])
                }
                if sample.decodedFrame, firstFrameAt == nil, let frameTime = sample.frameTime {
                    firstFrameAt = now
                    mark("seek_first_decoded_frame", ["seconds": now - seekAt, "frame_time": frameTime])
                }
                let delta = sample.time - previous.time
                if sample.playing, previous.playing, previous.time >= target - 0.75,
                   sample.time <= target + now - seekAt + 1, delta > 0, delta <= now - previousAt + 0.5 {
                    progress += delta
                    if firstProgressAt == nil {
                        firstProgressAt = now
                        mark("seek_first_verified_progress", ["seconds": now - seekAt, "media_time": sample.time])
                    }
                } else { progress = 0 }
                if now - lastLogAt >= plan.sampleIntervalSeconds {
                    mark("seek_sample", ["seconds": now - seekAt, "media_time": sample.time,
                                         "source_time": engine.sourceTime, "buffer_seconds": sample.ahead,
                                         "playing": sample.playing, "waiting": sample.waiting,
                                         "forward_buffer_preference": sample.preference,
                                         "engine_seeking": engine.isSeeking,
                                         "phase": String(describing: engine.playbackPhase)])
                    lastLogAt = now
                }
                if let apiReturnedAt, let firstFrameAt, let firstProgressAt,
                   progress >= plan.minimumProgressSeconds {
                    mark("seek_resumed", ["api_seconds": apiReturnedAt - seekAt,
                                          "first_decoded_frame_seconds": firstFrameAt - seekAt,
                                          "first_progress_seconds": firstProgressAt - seekAt,
                                          "sustained_progress_seconds": now - seekAt,
                                          "proven_media_progress_seconds": progress,
                                          "waiting_seconds": waiting, "buffer_seconds": sample.ahead,
                                          "media_time": sample.time])
                    break
                }
                guard now - seekAt < plan.recoveryDeadlineSeconds else {
                    mark("seek_timeout", ["seconds": now - seekAt, "media_time": sample.time,
                                          "decoded_frame": firstFrameAt != nil,
                                          "api_returned": apiReturnedAt != nil])
                    throw Failure.seekTimeout
                }
                previous = sample
                previousAt = now
                try await Task.sleep(for: .seconds(plan.sampleIntervalSeconds))
            }
        }
    }

    private static func requireHealth(_ sample: PlayerReadContext.Sample, engine: AetherEngine) throws {
        guard !sample.failed else { throw Failure.playbackFailed }
        if case .error = engine.playbackPhase { throw Failure.playbackFailed }
        guard sample.preference == 12 else { throw Failure.changedBufferPreference }
    }
}
