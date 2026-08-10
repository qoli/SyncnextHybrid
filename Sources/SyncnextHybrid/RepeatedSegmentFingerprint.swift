import Accelerate
import AVFAudio
import Foundation

private final class AudioConverterInputState: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}

public struct RepeatedSegmentFingerprintConfiguration: Codable, Sendable, Equatable {
    public var sampleRate = 16_000
    public var windowSamples = 2_048
    public var hopSamples = 1_600
    public var bandCount = 33
    public var minimumFrequency = 150.0
    public var maximumFrequency = 7_000.0
    public var minimumRMS = 1e-4
    public var minimumSpectralEntropy = 0.25

    public init() {}

    public var hopSeconds: Double {
        Double(hopSamples) / Double(sampleRate)
    }

    public static let v1 = Self()
}

public struct RepeatedSegmentFingerprintArtifact: Codable, Sendable, Equatable {
    public let formatVersion: Int
    public let label: String
    public let sourceStartSeconds: Double
    public let fingerprints: [UInt64]
    public let validity: [Bool]
    public let configuration: RepeatedSegmentFingerprintConfiguration

    public init(
        label: String,
        sourceStartSeconds: Double,
        fingerprints: [UInt64],
        validity: [Bool],
        configuration: RepeatedSegmentFingerprintConfiguration = .v1
    ) {
        self.formatVersion = 1
        self.label = label
        self.sourceStartSeconds = sourceStartSeconds
        self.fingerprints = fingerprints
        self.validity = validity
        self.configuration = configuration
    }
}

public struct RepeatedSegmentMatch: Sendable, Equatable {
    public let score: Double
    public let nullThreshold: Double
    public let leftRange: Range<Double>
    public let rightRange: Range<Double>
    public let seedDuration: Double
    public let validFraction: Double
}

public enum RepeatedSegmentFingerprintError: Error, Sendable, Equatable {
    case invalidAudio
    case audioDecodeFailed
    case discontinuousAudio
    case incompatibleArtifacts
    case insufficientValidFrames
}

/// Production port of AudioFingerprintExplorer's format-v1 fingerprint and
/// pairwise diagonal matcher. A match always has exactly two inputs; cycle
/// consistency from the research harness is deliberately not part of this API.
public enum RepeatedSegmentFingerprint {
    public static func compute(
        audioFileURL: URL,
        label: String,
        sourceStartSeconds: Double,
        configuration: RepeatedSegmentFingerprintConfiguration = .v1
    ) throws -> RepeatedSegmentFingerprintArtifact {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: audioFileURL)
        } catch {
            throw RepeatedSegmentFingerprintError.audioDecodeFailed
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(configuration.sampleRate),
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(
            from: file.processingFormat,
            to: outputFormat
        ) else {
            throw RepeatedSegmentFingerprintError.audioDecodeFailed
        }

        let inputCapacity: AVAudioFrameCount = 8_192
        guard let input = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: inputCapacity
        ) else {
            throw RepeatedSegmentFingerprintError.audioDecodeFailed
        }
        var samples: [Float] = []
        let ratio = outputFormat.sampleRate / file.processingFormat.sampleRate
        samples.reserveCapacity(Int(ceil(Double(file.length) * ratio)))
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(inputCapacity) * ratio) + 32
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw RepeatedSegmentFingerprintError.audioDecodeFailed
        }
        while file.framePosition < file.length {
            input.frameLength = 0
            do {
                try file.read(into: input, frameCount: inputCapacity)
            } catch {
                throw RepeatedSegmentFingerprintError.audioDecodeFailed
            }
            guard input.frameLength > 0 else { break }
            output.frameLength = 0
            let inputState = AudioConverterInputState(buffer: input)
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError
            ) { _, inputStatus in
                guard !inputState.supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputState.supplied = true
                inputStatus.pointee = .haveData
                return inputState.buffer
            }
            guard conversionError == nil,
                  status != .error,
                  let channel = output.floatChannelData?[0] else {
                throw RepeatedSegmentFingerprintError.audioDecodeFailed
            }
            samples.append(
                contentsOf: UnsafeBufferPointer(
                    start: channel,
                    count: Int(output.frameLength)
                )
            )
        }
        return try compute(
            monoSamples: samples,
            label: label,
            sourceStartSeconds: sourceStartSeconds,
            configuration: configuration
        )
    }

    public static func compute(
        monoSamples: [Float],
        label: String,
        sourceStartSeconds: Double,
        configuration: RepeatedSegmentFingerprintConfiguration = .v1
    ) throws -> RepeatedSegmentFingerprintArtifact {
        guard configuration.sampleRate == 16_000,
              configuration.windowSamples == 2_048,
              configuration.hopSamples == 1_600,
              configuration.bandCount == 33,
              monoSamples.count >= configuration.windowSamples else {
            throw RepeatedSegmentFingerprintError.invalidAudio
        }

        let frameCount = 1 + (
            monoSamples.count - configuration.windowSamples
        ) / configuration.hopSamples
        let window = (0..<configuration.windowSamples).map { index in
            Float(
                0.5 - 0.5 * cos(
                    2 * Double.pi * Double(index)
                        / Double(configuration.windowSamples - 1)
                )
            )
        }
        let bandRanges = makeBandRanges(configuration)
        let logBandCount = configuration.bandCount - 1
        let logEntropyDenominator = log(Double(configuration.bandCount))
        let log2N = vDSP_Length(log2(Double(configuration.windowSamples)))
        guard let fftSetup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2)) else {
            throw RepeatedSegmentFingerprintError.invalidAudio
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var previousContrast = [Float](repeating: 0, count: logBandCount)
        var twoBackContrast = previousContrast
        var fingerprints = [UInt64](repeating: 0, count: frameCount)
        var validity = [Bool](repeating: false, count: frameCount)
        var frame = [Float](repeating: 0, count: configuration.windowSamples)
        var real = [Float](repeating: 0, count: configuration.windowSamples / 2)
        var imaginary = real
        var bandPower = [Double](repeating: 0, count: configuration.bandCount)
        var contrast = [Float](repeating: 0, count: logBandCount)

        for frameIndex in 0..<frameCount {
            let start = frameIndex * configuration.hopSamples
            var squaredSum = 0.0
            for sampleIndex in 0..<configuration.windowSamples {
                let sample = monoSamples[start + sampleIndex]
                squaredSum += Double(sample * sample)
                frame[sampleIndex] = sample * window[sampleIndex]
            }

            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    var split = DSPSplitComplex(
                        realp: realBuffer.baseAddress!,
                        imagp: imaginaryBuffer.baseAddress!
                    )
                    frame.withUnsafeBufferPointer { frameBuffer in
                        frameBuffer.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self,
                            capacity: configuration.windowSamples / 2
                        ) { complex in
                            vDSP_ctoz(
                                complex,
                                2,
                                &split,
                                1,
                                vDSP_Length(configuration.windowSamples / 2)
                            )
                        }
                    }
                    vDSP_fft_zrip(
                        fftSetup,
                        &split,
                        1,
                        log2N,
                        FFTDirection(FFT_FORWARD)
                    )
                }
            }

            for (bandIndex, range) in bandRanges.enumerated() {
                var total = 0.0
                for bin in range {
                    let realValue = Double(real[bin])
                    let imaginaryValue = bin == 0 ? 0 : Double(imaginary[bin])
                    total += realValue * realValue + imaginaryValue * imaginaryValue
                }
                bandPower[bandIndex] = total
            }
            let totalPower = max(bandPower.reduce(0, +), 1e-20)
            var entropy = 0.0
            for power in bandPower {
                let normalized = power / totalPower
                entropy -= normalized * log(max(normalized, 1e-20))
            }
            entropy /= logEntropyDenominator

            for index in 0..<logBandCount {
                contrast[index] = Float(
                    log(max(bandPower[index], 1e-20))
                        - log(max(bandPower[index + 1], 1e-20))
                )
            }
            if frameIndex >= 1 {
                for bit in 0..<logBandCount where contrast[bit] >= previousContrast[bit] {
                    fingerprints[frameIndex] |= UInt64(1) << UInt64(bit)
                }
            }
            if frameIndex >= 2 {
                for bit in 0..<logBandCount where contrast[bit] >= twoBackContrast[bit] {
                    fingerprints[frameIndex] |= UInt64(1) << UInt64(bit + 32)
                }
            }
            validity[frameIndex] = frameIndex >= 2
                && sqrt(squaredSum / Double(configuration.windowSamples))
                    >= configuration.minimumRMS
                && entropy >= configuration.minimumSpectralEntropy
            swap(&twoBackContrast, &previousContrast)
            swap(&previousContrast, &contrast)
        }

        return RepeatedSegmentFingerprintArtifact(
            label: label,
            sourceStartSeconds: sourceStartSeconds,
            fingerprints: fingerprints,
            validity: validity,
            configuration: configuration
        )
    }

    /// Build the same format-v1 artifact directly from Aether's cache-backed
    /// PCM batch. This removes the intermediate AAC/WAV artifact and preserves
    /// the requested source-time range exactly.
    public static func compute(
        audioBatch: HybridFingerprintAudioBatch,
        label: String,
        configuration: RepeatedSegmentFingerprintConfiguration = .v1
    ) throws -> RepeatedSegmentFingerprintArtifact {
        guard let first = audioBatch.buffers.first,
              let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(configuration.sampleRate),
                channels: 1,
                interleaved: false
              ),
              let converter = AVAudioConverter(
                from: first.buffer.format,
                to: outputFormat
              ) else {
            throw RepeatedSegmentFingerprintError.audioDecodeFailed
        }

        let sourceRange = audioBatch.sourceRange
        let tolerance = 0.05
        var coveredThrough = sourceRange.lowerBound
        var relevantBufferCount = 0
        var samples: [Float] = []
        samples.reserveCapacity(
            Int((sourceRange.upperBound - sourceRange.lowerBound)
                * Double(configuration.sampleRate))
        )

        for timedBuffer in audioBatch.buffers {
            let input = timedBuffer.buffer
            let format = input.format
            guard format.commonFormat == .pcmFormatFloat32,
                  !format.isInterleaved,
                  format.channelCount == 1,
                  format.sampleRate == first.buffer.format.sampleRate,
                  let channel = input.floatChannelData?[0] else {
                throw RepeatedSegmentFingerprintError.invalidAudio
            }
            let rate = format.sampleRate
            let start = timedBuffer.sourceTime
            let end = start + Double(input.frameLength) / rate
            guard end > sourceRange.lowerBound,
                  start < sourceRange.upperBound else {
                continue
            }
            if relevantBufferCount > 0, timedBuffer.discontinuity {
                throw RepeatedSegmentFingerprintError.discontinuousAudio
            }
            let clippedStart = max(start, sourceRange.lowerBound)
            if clippedStart > coveredThrough + tolerance {
                throw RepeatedSegmentFingerprintError.discontinuousAudio
            }
            let firstFrame = max(
                0,
                Int(ceil((clippedStart - start) * rate))
            )
            let clippedEnd = min(end, sourceRange.upperBound)
            let endFrame = min(
                Int(input.frameLength),
                Int(floor((clippedEnd - start) * rate))
            )
            let frameCount = endFrame - firstFrame
            guard frameCount > 0,
                  let clipped = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(frameCount)
                  ) else {
                continue
            }
            clipped.frameLength = AVAudioFrameCount(frameCount)
            clipped.floatChannelData![0].update(
                from: channel + firstFrame,
                count: frameCount
            )

            let ratio = outputFormat.sampleRate / format.sampleRate
            let outputCapacity = AVAudioFrameCount(
                ceil(Double(frameCount) * ratio) + 32
            )
            guard let output = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw RepeatedSegmentFingerprintError.audioDecodeFailed
            }
            let inputState = AudioConverterInputState(buffer: clipped)
            var conversionError: NSError?
            let status = converter.convert(
                to: output,
                error: &conversionError
            ) { _, inputStatus in
                guard !inputState.supplied else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputState.supplied = true
                inputStatus.pointee = .haveData
                return inputState.buffer
            }
            guard conversionError == nil,
                  status != .error,
                  let outputChannel = output.floatChannelData?[0] else {
                throw RepeatedSegmentFingerprintError.audioDecodeFailed
            }
            samples.append(
                contentsOf: UnsafeBufferPointer(
                    start: outputChannel,
                    count: Int(output.frameLength)
                )
            )
            coveredThrough = max(coveredThrough, clippedEnd)
            relevantBufferCount += 1
            if coveredThrough >= sourceRange.upperBound - tolerance {
                break
            }
        }
        guard coveredThrough >= sourceRange.upperBound - tolerance else {
            throw RepeatedSegmentFingerprintError.discontinuousAudio
        }
        return try compute(
            monoSamples: samples,
            label: label,
            sourceStartSeconds: sourceRange.lowerBound,
            configuration: configuration
        )
    }

    public static func findBestPairwiseMatch(
        previous: RepeatedSegmentFingerprintArtifact,
        current: RepeatedSegmentFingerprintArtifact,
        minimumDurationSeconds: Double = 10
    ) throws -> RepeatedSegmentMatch? {
        guard previous.formatVersion == 1,
              current.formatVersion == 1,
              previous.configuration == current.configuration,
              previous.fingerprints.count == previous.validity.count,
              current.fingerprints.count == current.validity.count else {
            throw RepeatedSegmentFingerprintError.incompatibleArtifacts
        }
        let hop = current.configuration.hopSeconds
        let windowFrames = max(2, Int((minimumDurationSeconds / hop).rounded()))
        guard previous.fingerprints.count >= windowFrames,
              current.fingerprints.count >= windowFrames else {
            return nil
        }

        let estimatedTestCount = max(
            1,
            (previous.fingerprints.count - windowFrames + 1)
                * (current.fingerprints.count - windowFrames + 1)
        )
        let null = try estimateNull(
            previous: previous,
            current: current,
            windowFrames: windowFrames,
            estimatedTestCount: estimatedTestCount
        )
        var bestSeed: SeedCandidate?
        let minimumOffset = -(previous.fingerprints.count - windowFrames)
        let maximumOffset = current.fingerprints.count - windowFrames
        let minimumValid = Int(ceil(Double(windowFrames) * 0.8))
        let maximumLength = min(
            previous.fingerprints.count,
            current.fingerprints.count
        )
        var similarities = [Double](repeating: 0, count: maximumLength)
        var validity = [Bool](repeating: false, count: maximumLength)
        var prefixSums = [Double](repeating: 0, count: maximumLength + 1)
        var prefixCounts = [Int](repeating: 0, count: maximumLength + 1)

        for offset in minimumOffset...maximumOffset {
            let leftStart = max(0, -offset)
            let rightStart = max(0, offset)
            let length = min(
                previous.fingerprints.count - leftStart,
                current.fingerprints.count - rightStart
            )
            guard length >= windowFrames else { continue }
            prefixSums[0] = 0
            prefixCounts[0] = 0
            for index in 0..<length {
                let valid = previous.validity[leftStart + index]
                    && current.validity[rightStart + index]
                validity[index] = valid
                if valid {
                    similarities[index] = 1 - Double(
                        (previous.fingerprints[leftStart + index]
                            ^ current.fingerprints[rightStart + index])
                            .nonzeroBitCount
                    ) / 64
                } else {
                    similarities[index] = 0
                }
                prefixSums[index + 1] = prefixSums[index]
                    + (valid ? similarities[index] : 0)
                prefixCounts[index + 1] = prefixCounts[index] + (valid ? 1 : 0)
            }
            let resultCount = length - windowFrames + 1
            for local in 0..<resultCount {
                let validCount = prefixCounts[local + windowFrames]
                    - prefixCounts[local]
                guard validCount >= minimumValid else { continue }
                let score = (
                    prefixSums[local + windowFrames] - prefixSums[local]
                ) / Double(validCount)
                guard score >= null.threshold,
                      bestSeed == nil || score > bestSeed!.score else { continue }
                bestSeed = SeedCandidate(
                    score: score,
                    leftStart: leftStart,
                    rightStart: rightStart,
                    length: length,
                    localStart: local,
                    validCount: validCount
                )
            }
        }
        guard let bestSeed else { return nil }
        for index in 0..<bestSeed.length {
            let valid = previous.validity[bestSeed.leftStart + index]
                && current.validity[bestSeed.rightStart + index]
            validity[index] = valid
            similarities[index] = valid
                ? 1 - Double(
                    (previous.fingerprints[bestSeed.leftStart + index]
                        ^ current.fingerprints[bestSeed.rightStart + index])
                        .nonzeroBitCount
                ) / 64
                : 0
        }
        let expansion = expand(
            similarities: Array(similarities.prefix(bestSeed.length)),
            validity: Array(validity.prefix(bestSeed.length)),
            seedStart: bestSeed.localStart,
            seedWindowFrames: windowFrames,
            seedScore: bestSeed.score,
            hop: hop,
            null: null
        )
        let best = Candidate(
            score: bestSeed.score,
            leftStart: bestSeed.leftStart + expansion.start,
            rightStart: bestSeed.rightStart + expansion.start,
            frameCount: expansion.end - expansion.start,
            validFraction: Double(bestSeed.validCount) / Double(windowFrames)
        )
        return RepeatedSegmentMatch(
            score: best.score,
            nullThreshold: null.threshold,
            leftRange: (
                previous.sourceStartSeconds + Double(best.leftStart) * hop
            )..<(
                previous.sourceStartSeconds
                    + Double(best.leftStart + best.frameCount) * hop
            ),
            rightRange: (
                current.sourceStartSeconds + Double(best.rightStart) * hop
            )..<(
                current.sourceStartSeconds
                    + Double(best.rightStart + best.frameCount) * hop
            ),
            seedDuration: Double(windowFrames) * hop,
            validFraction: best.validFraction
        )
    }

    private struct SeedCandidate {
        let score: Double
        let leftStart: Int
        let rightStart: Int
        let length: Int
        let localStart: Int
        let validCount: Int
    }

    private struct Candidate {
        let score: Double
        let leftStart: Int
        let rightStart: Int
        let frameCount: Int
        let validFraction: Double
    }

    private struct NullDistribution {
        let mean: Double
        let standardDeviation: Double
        let threshold: Double
    }

    private static func makeBandRanges(
        _ configuration: RepeatedSegmentFingerprintConfiguration
    ) -> [Range<Int>] {
        let nyquistBinCount = configuration.windowSamples / 2 + 1
        let binWidth = Double(configuration.sampleRate)
            / Double(configuration.windowSamples)
        let ratio = pow(
            configuration.maximumFrequency / configuration.minimumFrequency,
            1 / Double(configuration.bandCount)
        )
        return (0..<configuration.bandCount).map { band in
            let lower = configuration.minimumFrequency * pow(ratio, Double(band))
            let upper = lower * ratio
            let start = max(0, Int(ceil(lower / binWidth)))
            let end = min(
                nyquistBinCount,
                max(start + 1, Int(ceil(upper / binWidth)))
            )
            return start..<end
        }
    }

    private static func rollingWeightedMean(
        _ values: [Double],
        validity: [Bool],
        window: Int
    ) -> (means: [Double], counts: [Int]) {
        guard values.count >= window else { return ([], []) }
        var sums = [Double](repeating: 0, count: values.count + 1)
        var counts = [Int](repeating: 0, count: values.count + 1)
        for index in values.indices {
            sums[index + 1] = sums[index] + (validity[index] ? values[index] : 0)
            counts[index + 1] = counts[index] + (validity[index] ? 1 : 0)
        }
        let resultCount = values.count - window + 1
        var means = [Double](repeating: 0, count: resultCount)
        var validCounts = [Int](repeating: 0, count: resultCount)
        for index in 0..<resultCount {
            validCounts[index] = counts[index + window] - counts[index]
            means[index] = (sums[index + window] - sums[index])
                / Double(max(validCounts[index], 1))
        }
        return (means, validCounts)
    }

    private static func estimateNull(
        previous: RepeatedSegmentFingerprintArtifact,
        current: RepeatedSegmentFingerprintArtifact,
        windowFrames: Int,
        estimatedTestCount: Int
    ) throws -> NullDistribution {
        let left = previous.validity.indices.filter { previous.validity[$0] }
        let right = current.validity.indices.filter { current.validity[$0] }
        guard left.count >= windowFrames, right.count >= windowFrames else {
            throw RepeatedSegmentFingerprintError.insufficientValidFrames
        }
        let drawCount = max(windowFrames * 1_000, 200_000)
        var generator = StableGenerator(seed: stableSeed(previous.label + "\u{0}" + current.label))
        let blockCount = drawCount / windowFrames
        var blockScores = [Double](repeating: 0, count: blockCount)
        for block in 0..<blockCount {
            var total = 0.0
            for _ in 0..<windowFrames {
                let leftIndex = left[Int(generator.next() % UInt64(left.count))]
                let rightIndex = right[Int(generator.next() % UInt64(right.count))]
                total += 1 - Double(
                    (previous.fingerprints[leftIndex] ^ current.fingerprints[rightIndex])
                        .nonzeroBitCount
                ) / 64
            }
            blockScores[block] = total / Double(windowFrames)
        }
        let mean = blockScores.reduce(0, +) / Double(blockScores.count)
        let variance = blockScores.reduce(0) { partial, score in
            partial + (score - mean) * (score - mean)
        } / Double(blockScores.count)
        let standardDeviation = sqrt(variance)
        let sorted = blockScores.sorted()
        let empiricalIndex = min(
            sorted.count - 1,
            Int((0.999 * Double(sorted.count - 1)).rounded(.up))
        )
        let empirical = sorted[empiricalIndex]
        let perTestTail = 0.01 / Double(max(1, estimatedTestCount))
        let familyWise = mean
            + inverseStandardNormalCDF(1 - perTestTail) * standardDeviation
        return NullDistribution(
            mean: mean,
            standardDeviation: standardDeviation,
            threshold: min(1, max(empirical, familyWise))
        )
    }

    private static func expand(
        similarities: [Double],
        validity: [Bool],
        seedStart: Int,
        seedWindowFrames: Int,
        seedScore: Double,
        hop: Double,
        null: NullDistribution
    ) -> (start: Int, end: Int) {
        let extensionFrames = max(2, Int((1 / hop).rounded()))
        let maximumGapFrames = max(0, Int((3 / hop).rounded()))
        let rolling = rollingWeightedMean(
            similarities,
            validity: validity,
            window: extensionFrames
        )
        let minimumValid = Int(ceil(Double(extensionFrames) * 0.6))
        let scaledDeviation = null.standardDeviation
            * sqrt(Double(seedWindowFrames) / Double(extensionFrames))
        let supportThreshold = min(1, null.mean + 4 * scaledDeviation)
        let support = rolling.means.indices.map {
            rolling.counts[$0] >= minimumValid
                && rolling.means[$0] >= supportThreshold
        }

        var expandedStart = seedStart
        var unsupported = 0
        if !support.isEmpty {
            for index in stride(
                from: min(seedStart, support.count - 1),
                through: 0,
                by: -1
            ) {
                if support[index] {
                    expandedStart = index
                    unsupported = 0
                } else {
                    unsupported += 1
                    if unsupported > maximumGapFrames { break }
                }
            }
        }

        var expandedEnd = seedStart + seedWindowFrames
        var lastSupportedEnd = expandedEnd
        unsupported = 0
        let rightStart = max(0, seedStart + seedWindowFrames - extensionFrames)
        if rightStart < support.count {
            for index in rightStart..<support.count {
                if support[index] {
                    lastSupportedEnd = max(lastSupportedEnd, index + extensionFrames)
                    unsupported = 0
                } else {
                    unsupported += 1
                    if unsupported > maximumGapFrames { break }
                }
            }
        }
        expandedEnd = min(similarities.count, lastSupportedEnd)

        let frameThreshold = min(1, null.mean + 0.5 * (seedScore - null.mean))
        let frameSupport = similarities.indices.map {
            validity[$0] && similarities[$0] >= frameThreshold
        }
        let refinementFrames = max(2, Int((0.3 / hop).rounded()))
        var runStarts: [Int] = []
        if frameSupport.count >= refinementFrames {
            var run = frameSupport.prefix(refinementFrames).filter { $0 }.count
            if run == refinementFrames { runStarts.append(0) }
            if frameSupport.count > refinementFrames {
                for index in 1...(frameSupport.count - refinementFrames) {
                    if frameSupport[index - 1] { run -= 1 }
                    if frameSupport[index + refinementFrames - 1] { run += 1 }
                    if run == refinementFrames { runStarts.append(index) }
                }
            }
        }
        if let leading = runStarts.first(where: {
            $0 >= expandedStart && $0 <= seedStart
        }) {
            expandedStart = leading
        }
        if let trailing = runStarts.last(where: {
            $0 + refinementFrames >= seedStart + seedWindowFrames
                && $0 + refinementFrames <= expandedEnd
        }) {
            expandedEnd = trailing + refinementFrames
        }
        return (expandedStart, expandedEnd)
    }

    private static func stableSeed(_ value: String) -> UInt64 {
        value.utf8.reduce(14_695_981_039_346_656_037) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
    }

    private struct StableGenerator {
        var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
        }

        mutating func next() -> UInt64 {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            return state &* 2_685_821_657_736_338_717
        }
    }

    /// Acklam's approximation, sufficient for the family-wise threshold tail.
    private static func inverseStandardNormalCDF(_ probability: Double) -> Double {
        let p = min(max(probability, 1e-15), 1 - 1e-15)
        let a = [-39.6968302866538, 220.946098424521, -275.928510446969,
                 138.357751867269, -30.6647980661472, 2.50662827745924]
        let b = [-54.4760987982241, 161.585836858041, -155.698979859887,
                 66.8013118877197, -13.2806815528857]
        let c = [-0.00778489400243029, -0.322396458041136,
                 -2.40075827716184, -2.54973253934373,
                 4.37466414146497, 2.93816398269878]
        let d = [0.00778469570904146, 0.32246712907004,
                 2.445134137143, 3.75440866190742]
        if p < 0.02425 {
            let q = sqrt(-2 * log(p))
            return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q
                + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        if p > 0.97575 {
            let q = sqrt(-2 * log(1 - p))
            return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q
                + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        let q = p - 0.5
        let r = q * q
        return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r
            + a[4]) * r + a[5]) * q
            / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r
                + b[4]) * r + 1)
    }
}
