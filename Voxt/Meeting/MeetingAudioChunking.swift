import Foundation
import AVFoundation
import WhisperKit

struct BufferedMeetingChunk {
    let speaker: MeetingSpeaker
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let sampleRate: Double
    let samples: [Float]
}

actor MeetingChunkAccumulator {
    private let speaker: MeetingSpeaker
    private let speechThreshold: Float
    private let silenceFlushSeconds: TimeInterval = 0.7
    private let minSpeechSeconds: TimeInterval = 0.6
    private let maxChunkSeconds: TimeInterval = 6.0

    private var totalSamples: Int = 0
    private var currentSamples: [Float] = []
    private var currentStartSeconds: TimeInterval?
    private var currentSampleRate: Double = Double(WhisperKit.sampleRate)
    private var accumulatedSilenceSeconds: TimeInterval = 0

    init(speaker: MeetingSpeaker, speechThreshold: Float) {
        self.speaker = speaker
        self.speechThreshold = speechThreshold
    }

    func append(samples: [Float], sampleRate: Double, level: Float) -> BufferedMeetingChunk? {
        guard !samples.isEmpty, sampleRate > 0 else { return nil }
        let bufferStartSeconds = Double(totalSamples) / sampleRate
        let bufferDuration = Double(samples.count) / sampleRate
        totalSamples += samples.count

        if currentStartSeconds == nil {
            if level < speechThreshold {
                return nil
            }
            currentStartSeconds = bufferStartSeconds
            currentSampleRate = sampleRate
            currentSamples.removeAll(keepingCapacity: true)
        }

        if abs(currentSampleRate - sampleRate) > 1 {
            if let flushed = flushCurrent(endSeconds: bufferStartSeconds) {
                currentStartSeconds = bufferStartSeconds
                currentSampleRate = sampleRate
                currentSamples = samples
                accumulatedSilenceSeconds = level >= speechThreshold ? 0 : bufferDuration
                return flushed
            }
            currentStartSeconds = bufferStartSeconds
            currentSampleRate = sampleRate
            currentSamples.removeAll(keepingCapacity: true)
        }

        currentSamples.append(contentsOf: samples)

        if level >= speechThreshold {
            accumulatedSilenceSeconds = 0
        } else {
            accumulatedSilenceSeconds += bufferDuration
        }

        let currentDuration = Double(currentSamples.count) / currentSampleRate
        let bufferEndSeconds = bufferStartSeconds + bufferDuration

        if currentDuration >= maxChunkSeconds {
            return flushCurrent(endSeconds: bufferEndSeconds)
        }

        if accumulatedSilenceSeconds >= silenceFlushSeconds {
            return flushCurrent(endSeconds: bufferEndSeconds)
        }

        return nil
    }

    func finish() -> BufferedMeetingChunk? {
        flushCurrent(endSeconds: Double(totalSamples) / max(currentSampleRate, 1))
    }

    private func flushCurrent(endSeconds: TimeInterval) -> BufferedMeetingChunk? {
        guard let currentStartSeconds else { return nil }
        let duration = Double(currentSamples.count) / max(currentSampleRate, 1)
        defer {
            self.currentStartSeconds = nil
            self.currentSamples.removeAll(keepingCapacity: false)
            self.accumulatedSilenceSeconds = 0
        }
        guard duration >= minSpeechSeconds else {
            return nil
        }
        return BufferedMeetingChunk(
            speaker: speaker,
            startSeconds: currentStartSeconds,
            endSeconds: max(endSeconds, currentStartSeconds),
            sampleRate: currentSampleRate,
            samples: currentSamples
        )
    }
}

actor MeetingWhisperSegmentTranscriber {
    private static let minimumChunkRMS: Float = 0.003

    private let whisper: WhisperKit
    private let mainLanguage: UserMainLanguageOption
    private let temperature: Float
    private let hintPayload: ResolvedASRHintPayload
    private let targetSampleRate = Double(WhisperKit.sampleRate)

    init(
        whisper: WhisperKit,
        mainLanguage: UserMainLanguageOption,
        temperature: Float,
        hintPayload: ResolvedASRHintPayload
    ) {
        self.whisper = whisper
        self.mainLanguage = mainLanguage
        self.temperature = temperature
        self.hintPayload = hintPayload
    }

    func transcribe(chunk: BufferedMeetingChunk) async -> MeetingTranscriptSegment? {
        let preparedSamples = Self.resample(samples: chunk.samples, from: chunk.sampleRate, to: targetSampleRate)
        guard !preparedSamples.isEmpty else { return nil }
        guard Self.rootMeanSquare(preparedSamples) >= Self.minimumChunkRMS else {
            return nil
        }

        do {
            let detectLanguage = hintPayload.language == nil
            let promptTokens: [Int]?
            if let prompt = hintPayload.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty,
               let tokenizer = whisper.tokenizer {
                promptTokens = tokenizer.encode(text: " " + prompt)
                    .filter { token in token < tokenizer.specialTokens.specialTokenBegin }
            } else {
                promptTokens = nil
            }

            let results = try await whisper.transcribe(
                audioArray: preparedSamples,
                decodeOptions: DecodingOptions(
                    verbose: false,
                    task: .transcribe,
                    language: hintPayload.language,
                    temperature: temperature,
                    temperatureFallbackCount: 0,
                    usePrefillPrompt: true,
                    detectLanguage: detectLanguage,
                    skipSpecialTokens: true,
                    withoutTimestamps: true,
                    wordTimestamps: false,
                    promptTokens: promptTokens,
                    chunkingStrategy: nil
                )
            )
            let rawText = results.map(\.text).joined(separator: " ")
            let text = await MainActor.run {
                WhisperTextPostProcessor.normalize(
                    rawText,
                    preferredMainLanguage: mainLanguage,
                    outputMode: .transcription,
                    usesBuiltInTranslationTask: false
                )
            }
            guard !text.isEmpty else { return nil }
            return await MainActor.run {
                MeetingTranscriptSegment(
                    speaker: chunk.speaker,
                    startSeconds: chunk.startSeconds,
                    endSeconds: chunk.endSeconds,
                    text: text
                )
            }
        } catch {
            await MainActor.run {
                VoxtLog.error("Meeting Whisper transcription failed: \(error)")
            }
            return nil
        }
    }

    private static func resample(samples: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        guard !samples.isEmpty, inputRate > 0, outputRate > 0 else { return samples }
        if abs(inputRate - outputRate) <= 1 {
            return samples
        }

        let ratio = outputRate / inputRate
        let outputCount = max(Int(Double(samples.count) * ratio), 1)
        var output = [Float](repeating: 0, count: outputCount)

        for index in 0..<outputCount {
            let position = Double(index) / ratio
            let lowerIndex = Int(position)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(position - Double(lowerIndex))
            let lower = samples[min(lowerIndex, samples.count - 1)]
            let upper = samples[upperIndex]
            output[index] = lower + (upper - lower) * fraction
        }

        return output
    }

    private static func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var energy: Float = 0
        for sample in samples {
            energy += sample * sample
        }
        return sqrt(energy / Float(samples.count))
    }
}
