import AetherEngine
import AVFoundation
import Combine
import Foundation

/// Retains the engine's already admitted pictures, without copying pixels or pacing its decoder.
/// Pruning follows the renderer clock, so paused playback retains its bounded renderer lookahead.
final class HybridSoftwareVideoFrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [SoftwareVideoFrame] = []
    private var minimumGeneration: UInt64 = 0
    private var currentGeneration: UInt64?
    private var currentRevision: UInt64 = 0
    private var active = true

    var revision: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return currentRevision
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    func receive(_ frame: SoftwareVideoFrame, clock: CMTime) {
        lock.lock(); defer { lock.unlock() }
        guard active, frame.presentation.isNumeric, frame.generation >= minimumGeneration else { return }
        if let currentGeneration, frame.generation < currentGeneration { return }
        if currentGeneration != frame.generation {
            frames.removeAll()
            currentGeneration = frame.generation
            currentRevision &+= 1
        }
        if let last = frames.last, CMTimeCompare(frame.presentation, last.presentation) <= 0 { return }
        frames.append(frame)
        prune(before: clock)
    }

    func picture(at time: CMTime, clock: CMTime) -> SoftwareVideoFrame? {
        lock.lock(); defer { lock.unlock() }
        guard active, time.isNumeric else { return nil }
        prune(before: clock)
        return frames.last { CMTimeCompare($0.presentation, time) <= 0 }
    }

    private func prune(before time: CMTime) {
        guard time.isNumeric,
              let index = frames.lastIndex(where: { CMTimeCompare($0.presentation, time) <= 0 }),
              index > 0 else { return }
        // Retain the picture covering the clock plus every picture still queued ahead of it.
        frames.removeFirst(index)
    }

    func awaitNextGeneration() {
        lock.lock(); defer { lock.unlock() }
        if let currentGeneration { minimumGeneration = max(minimumGeneration, currentGeneration &+ 1) }
        frames.removeAll()
        currentRevision &+= 1
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        active = false
        frames.removeAll()
        currentRevision &+= 1
    }
}

/// A passive source for host picture processing. Its timebase is the source-axis audio/video
/// synchronizer, never the silent AVKit transport item. Only one capture belongs to a session.
@MainActor
public final class HybridSoftwareVideoFrameSource {
    let id = UUID()
    private weak var engine: AetherEngine?
    private let sourceGeneration: UUID
    private let frames = HybridSoftwareVideoFrameBuffer()
    private var observations = Set<AnyCancellable>()
    private var onStop: ((UUID) -> Void)?
    private var stopped = false

    init(engine: AetherEngine, onStop: @escaping (UUID) -> Void) {
        self.engine = engine
        sourceGeneration = engine.scrubPreviewSourceGeneration
        self.onStop = onStop
        let frames = self.frames
        let timebase = engine.softwarePresentationTimebase
        engine.setSoftwareVideoFrameObserver { frame in
            frames.receive(frame, clock: timebase.map(CMTimebaseGetTime) ?? .invalid)
        }
        engine.$isSeeking.removeDuplicates().sink { seeking in
            if seeking { frames.awaitNextGeneration() }
        }.store(in: &observations)
    }

    public var isCurrent: Bool {
        !stopped && engine?.videoRoute == .software
            && engine?.scrubPreviewSourceGeneration == sourceGeneration
            && engine?.softwarePresentationTimebase != nil
    }
    public var revision: UInt64 { frames.revision }
    public var retainedFrameCount: Int { frames.count }
    public var isSeeking: Bool { engine?.isSeeking == true }
    public var timebase: CMTimebase? { isCurrent ? engine?.softwarePresentationTimebase : nil }
    public var rate: Float { timebase.map { Float(CMTimebaseGetRate($0)) } ?? 0 }
    public var isPlaying: Bool { isCurrent && !isSeeking && engine?.state == .playing && rate > 0 }
    public var currentTime: CMTime { timebase.map(CMTimebaseGetTime) ?? .invalid }
    public var presentationSize: CGSize { engine?.softwareDisplaySize ?? .zero }

    public func time(atHostTime seconds: Double) -> CMTime {
        guard let timebase else { return .invalid }
        return CMSyncConvertTime(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
                                 from: CMClockGetHostTimeClock(), to: timebase)
    }

    public func picture(at time: CMTime) -> SoftwareVideoFrame? {
        guard isCurrent, !isSeeking else { return nil }
        return frames.picture(at: time, clock: currentTime)
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        frames.stop()
        observations.removeAll()
        onStop?(id)
        onStop = nil
    }
}
