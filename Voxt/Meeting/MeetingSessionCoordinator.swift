import Foundation
import AVFoundation
import WhisperKit

@MainActor
final class MeetingSessionCoordinator {
    let overlayState = MeetingOverlayState()

    var onSessionFinished: ((MeetingSessionResult) -> Void)?

    private let whisperModelManager: WhisperKitModelManager
    private let microphoneCapture = MeetingMicrophoneCapture()
    private let systemAudioCapture = MeetingSystemAudioCapture()
    private let micAccumulator = MeetingChunkAccumulator(speaker: .me, speechThreshold: 0.012)
    private let systemAccumulator = MeetingChunkAccumulator(speaker: .them, speechThreshold: 0.025)
    private var whisper: WhisperKit?
    private var transcriber: MeetingWhisperSegmentTranscriber?
    private var activeUseHeld = false
    private var isStopping = false
    private var recordingStartedAt: Date?
    private var accumulatedRecordingDuration: TimeInterval = 0
    private var preferredInputDeviceIDProvider: () -> AudioDeviceID?
    private var pendingTasks: [Task<Void, Never>] = []
    private var translationTasks: [UUID: Task<Void, Never>] = [:]
    private var micLevel: Float = 0
    private var systemLevel: Float = 0
    private var loggedInitialBufferSpeakers = Set<MeetingSpeaker>()
    private var loggedChunkSpeakers = Set<MeetingSpeaker>()
    private var loggedSampleExtractionFailureSpeakers = Set<MeetingSpeaker>()
    private let audioArchive = MeetingAudioArchive()
    private let realtimeTranslationTargetLanguageProvider: @MainActor () -> TranslationTargetLanguage?
    private let realtimeTranslationHandler: @MainActor (String, TranslationTargetLanguage) async throws -> String

    init(
        whisperModelManager: WhisperKitModelManager,
        preferredInputDeviceIDProvider: @escaping () -> AudioDeviceID?,
        realtimeTranslationTargetLanguageProvider: @escaping @MainActor () -> TranslationTargetLanguage?,
        realtimeTranslationHandler: @escaping @MainActor (String, TranslationTargetLanguage) async throws -> String
    ) {
        self.whisperModelManager = whisperModelManager
        self.preferredInputDeviceIDProvider = preferredInputDeviceIDProvider
        self.realtimeTranslationTargetLanguageProvider = realtimeTranslationTargetLanguageProvider
        self.realtimeTranslationHandler = realtimeTranslationHandler
    }

    var isActive: Bool {
        overlayState.isPresented || overlayState.isRecording || overlayState.isPaused || activeUseHeld || isStopping
    }

    func start() async -> String? {
        guard !overlayState.isPresented else { return nil }

        cleanupSessionState(shouldLogCaptureStop: false)
        overlayState.reset()
        overlayState.isPresented = true
        overlayState.isCollapsed = UserDefaults.standard.object(forKey: AppPreferenceKey.meetingOverlayCollapsed) as? Bool ?? false
        overlayState.realtimeTranslateEnabled = UserDefaults.standard.object(forKey: AppPreferenceKey.meetingRealtimeTranslateEnabled) as? Bool ?? false

        do {
            whisperModelManager.beginActiveUse()
            activeUseHeld = true
            let whisper = try await whisperModelManager.loadWhisper()
            self.whisper = whisper
            let hintSettings = ASRHintSettingsStore.resolvedSettings(
                for: .whisperKit,
                rawValue: UserDefaults.standard.string(forKey: AppPreferenceKey.asrHintSettings)
            )
            let hintPayload = resolvedMeetingHintPayload(settings: hintSettings)
            self.transcriber = MeetingWhisperSegmentTranscriber(
                whisper: whisper,
                mainLanguage: resolvedMeetingMainLanguage(),
                temperature: Float(UserDefaults.standard.double(forKey: AppPreferenceKey.whisperTemperature)),
                hintPayload: hintPayload
            )
            try startCaptures()
        } catch {
            cleanupSessionState()
            overlayState.reset()
            return error.localizedDescription
        }

        recordingStartedAt = Date()
        overlayState.isRecording = true
        overlayState.isPaused = false
        overlayState.waveformState.reset()
        overlayState.waveformState.setActive(true)
        return nil
    }

    func pause() async {
        guard overlayState.isPresented, overlayState.isRecording, !isStopping else { return }
        overlayState.isRecording = false
        overlayState.isPaused = true
        overlayState.audioLevel = 0
        overlayState.waveformState.setActive(false)
        finalizeCurrentRecordingSlice()
        stopCaptures()
        await flushPendingAudio()
    }

    func resume() async -> String? {
        guard overlayState.isPresented, overlayState.isPaused, !overlayState.isRecording, !isStopping else {
            return nil
        }
        do {
            try startCaptures()
            recordingStartedAt = Date()
            overlayState.isPaused = false
            overlayState.isRecording = true
            overlayState.waveformState.reset()
            overlayState.waveformState.setActive(true)
            return nil
        } catch {
            overlayState.audioLevel = 0
            overlayState.waveformState.setActive(false)
            return error.localizedDescription
        }
    }

    func stop() {
        guard isActive, !isStopping else { return }
        isStopping = true
        let visibleSnapshotSegments = finalizedSegments(from: overlayState.segments)
        overlayState.isRecording = false
        overlayState.isPaused = false
        overlayState.audioLevel = 0
        overlayState.waveformState.setActive(false)

        finalizeCurrentRecordingSlice()
        stopCaptures()

        Task { [weak self] in
            guard let self else { return }
            await self.flushPendingAudio()
            await MainActor.run {
                self.cancelTranslationTasks()
                self.clearPendingTranslationState()
            }

            let duration = max(self.accumulatedRecordingDuration, 0)
            let archivedAudioURL = try? await self.persistMeetingAudioArchive()
            let finalSegments = await MainActor.run {
                self.finalizedSegments(from: self.overlayState.segments)
            }
            let result = MeetingSessionResult(
                segments: finalSegments.sorted { lhs, rhs in
                    if lhs.startSeconds == rhs.startSeconds {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.startSeconds < rhs.startSeconds
                },
                visibleSnapshotSegments: visibleSnapshotSegments.sorted { lhs, rhs in
                    if lhs.startSeconds == rhs.startSeconds {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.startSeconds < rhs.startSeconds
                },
                audioDurationSeconds: duration,
                archivedAudioURL: archivedAudioURL
            )

            await MainActor.run {
                VoxtLog.info(
                    "Meeting session finished. visibleSegments=\(visibleSnapshotSegments.count), persistedSegments=\(result.persistedSegments.count), duration=\(String(format: "%.2f", duration))s"
                )
            }
            self.cleanupSessionState()
            self.overlayState.reset()
            self.onSessionFinished?(result)
        }
    }

    func setCollapsed(_ isCollapsed: Bool) {
        overlayState.isCollapsed = isCollapsed
        UserDefaults.standard.set(isCollapsed, forKey: AppPreferenceKey.meetingOverlayCollapsed)
    }

    func setRealtimeTranslateEnabled(_ isEnabled: Bool) {
        overlayState.realtimeTranslateEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: AppPreferenceKey.meetingRealtimeTranslateEnabled)
        if isEnabled {
            translateEligibleSegmentsIfNeeded()
        } else {
            cancelTranslationTasks()
            clearPendingTranslationState()
        }
    }

    var canExport: Bool {
        overlayState.isPaused && !overlayState.segments.isEmpty
    }

    private func handleBuffer(_ buffer: AVAudioPCMBuffer, level: Float, speaker: MeetingSpeaker) {
        guard overlayState.isRecording else { return }
        if speaker == .me {
            micLevel = level
        } else {
            systemLevel = level
        }
        let displayLevel = min(
            1,
            (micLevel * 0.76) +
            (systemLevel * 0.42) +
            max(micLevel * 0.16, systemLevel * 0.1)
        )
        overlayState.audioLevel = displayLevel
        overlayState.waveformState.ingest(level: displayLevel)

        if !loggedInitialBufferSpeakers.contains(speaker) {
            loggedInitialBufferSpeakers.insert(speaker)
            VoxtLog.info(
                "Meeting audio buffer received. speaker=\(speaker.rawValue), level=\(String(format: "%.3f", level)), sampleRate=\(Int(buffer.format.sampleRate)), channels=\(buffer.format.channelCount), format=\(buffer.format.commonFormat.rawValue)"
            )
        }

        guard let samples = Self.extractMonoSamples(from: buffer) else {
            if !loggedSampleExtractionFailureSpeakers.contains(speaker) {
                loggedSampleExtractionFailureSpeakers.insert(speaker)
                VoxtLog.warning(
                    "Meeting audio sample extraction failed. speaker=\(speaker.rawValue), interleaved=\(buffer.format.isInterleaved), sampleRate=\(Int(buffer.format.sampleRate)), channels=\(buffer.format.channelCount), format=\(buffer.format.commonFormat.rawValue)"
                )
            }
            return
        }
        let sampleRate = buffer.format.sampleRate

        let task = Task { [weak self] in
            guard let self else { return }
            await self.audioArchive.append(samples: samples, sampleRate: sampleRate, speaker: speaker)
            let chunk: BufferedMeetingChunk?
            if speaker == .me {
                chunk = await self.micAccumulator.append(samples: samples, sampleRate: sampleRate, level: level)
            } else {
                chunk = await self.systemAccumulator.append(samples: samples, sampleRate: sampleRate, level: level)
            }
            guard let chunk else { return }
            await MainActor.run {
                if !self.loggedChunkSpeakers.contains(speaker) {
                    self.loggedChunkSpeakers.insert(speaker)
                    VoxtLog.info(
                        "Meeting audio chunk ready. speaker=\(speaker.rawValue), duration=\(String(format: "%.2f", chunk.endSeconds - chunk.startSeconds))s, sampleCount=\(chunk.samples.count)"
                    )
                }
            }
            await self.enqueue(chunk: chunk)
        }
        pendingTasks.append(task)
        pruneCompletedTasks()
    }

    private func enqueue(chunk: BufferedMeetingChunk) async {
        guard let transcriber else { return }
        if let segment = await transcriber.transcribe(chunk: chunk) {
            await MainActor.run { [weak self] in
                guard let self, self.overlayState.isPresented else { return }
                let shouldTranslate = self.shouldTranslate(segment: segment)
                let storedSegment = shouldTranslate
                    ? segment.updatingTranslation(translatedText: nil, isTranslationPending: true)
                    : segment
                self.overlayState.segments.append(storedSegment)
                self.overlayState.segments.sort { lhs, rhs in
                    if lhs.startSeconds == rhs.startSeconds {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.startSeconds < rhs.startSeconds
                }
                if shouldTranslate {
                    self.queueRealtimeTranslation(for: storedSegment)
                }
            }
        }
    }

    private func pruneCompletedTasks() {
        pendingTasks.removeAll { $0.isCancelled }
    }

    private func cleanupSessionState(shouldLogCaptureStop: Bool = true) {
        stopCaptures(shouldLog: shouldLogCaptureStop)
        cancelTranslationTasks()
        micLevel = 0
        systemLevel = 0
        loggedInitialBufferSpeakers.removeAll()
        loggedChunkSpeakers.removeAll()
        loggedSampleExtractionFailureSpeakers.removeAll()
        recordingStartedAt = nil
        accumulatedRecordingDuration = 0
        isStopping = false
        if activeUseHeld {
            whisperModelManager.endActiveUse()
            activeUseHeld = false
        }
        whisper = nil
        transcriber = nil
        Task {
            await audioArchive.reset()
        }
    }

    private func startCaptures() throws {
        let availableDevices = AudioInputDeviceManager.snapshotAvailableInputDevices()
        let resolvedInputDeviceID = AudioInputDeviceManager.resolvedInputDeviceID(
            from: availableDevices,
            preferredID: preferredInputDeviceIDProvider()
        )
        if let preferredInputDeviceID = preferredInputDeviceIDProvider(),
           preferredInputDeviceID != resolvedInputDeviceID {
            VoxtLog.info(
                "Meeting microphone input device fallback applied. preferred=\(preferredInputDeviceID), resolved=\(resolvedInputDeviceID.map(String.init(describing:)) ?? "default")"
            )
        }
        microphoneCapture.setPreferredInputDevice(resolvedInputDeviceID)
        try microphoneCapture.start { [weak self] buffer, level in
            Task { @MainActor [weak self] in
                self?.handleBuffer(buffer, level: level, speaker: .me)
            }
        }
        do {
            try systemAudioCapture.start { [weak self] buffer, level in
                Task { @MainActor [weak self] in
                    self?.handleBuffer(buffer, level: level, speaker: .them)
                }
            }
        } catch {
            microphoneCapture.stop()
            throw error
        }
    }

    private func stopCaptures(shouldLog: Bool = true) {
        if shouldLog {
            VoxtLog.info("Meeting capture stop requested.")
        }
        microphoneCapture.stop()
        systemAudioCapture.stop()
    }

    private func finalizeCurrentRecordingSlice() {
        if let recordingStartedAt {
            accumulatedRecordingDuration += max(Date().timeIntervalSince(recordingStartedAt), 0)
        }
        recordingStartedAt = nil
    }

    private func flushPendingAudio() async {
        if let micChunk = await micAccumulator.finish() {
            await enqueue(chunk: micChunk)
        }
        if let systemChunk = await systemAccumulator.finish() {
            await enqueue(chunk: systemChunk)
        }

        let activeTasks = pendingTasks
        pendingTasks.removeAll()
        for task in activeTasks {
            await task.value
        }
    }

    private func flushPendingTranslations() async {
        let activeTasks = Array(translationTasks.values)
        for task in activeTasks {
            await task.value
        }
    }

    private func persistMeetingAudioArchive() async throws -> URL? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Voxt-Meeting-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        let didExport = try await audioArchive.exportWAV(to: tempURL)
        return didExport ? tempURL : nil
    }

    private func shouldTranslate(segment: MeetingTranscriptSegment) -> Bool {
        overlayState.realtimeTranslateEnabled &&
        segment.speaker == .them &&
        realtimeTranslationTargetLanguageProvider() != nil
    }

    private func translateEligibleSegmentsIfNeeded() {
        for segment in overlayState.segments where segment.speaker == .them {
            let alreadyHasTranslation = !(segment.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            guard !alreadyHasTranslation else { continue }
            queueRealtimeTranslation(
                for: segment.isTranslationPending
                    ? segment
                    : segment.updatingTranslation(translatedText: nil, isTranslationPending: true)
            )
        }
        overlayState.segments = overlayState.segments.map { segment in
            guard overlayState.realtimeTranslateEnabled,
                  segment.speaker == .them,
                  (segment.translatedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            else {
                return segment
            }
            return segment.updatingTranslation(translatedText: segment.translatedText, isTranslationPending: true)
        }
    }

    private func queueRealtimeTranslation(for segment: MeetingTranscriptSegment) {
        guard overlayState.realtimeTranslateEnabled,
              segment.speaker == .them,
              translationTasks[segment.id] == nil,
              let targetLanguage = realtimeTranslationTargetLanguageProvider()
        else {
            return
        }

        updateSegment(segment.id) { current in
            current.updatingTranslation(
                translatedText: current.translatedText,
                isTranslationPending: true
            )
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.translationTasks[segment.id] = nil }

            do {
                let translatedText = try await self.realtimeTranslationHandler(segment.text, targetLanguage)
                let trimmed = translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                self.updateSegment(segment.id) { current in
                    current.updatingTranslation(
                        translatedText: trimmed.isEmpty ? nil : trimmed,
                        isTranslationPending: false
                    )
                }
            } catch {
                VoxtLog.warning("Meeting realtime translation failed: \(error)")
                self.updateSegment(segment.id) { current in
                    current.updatingTranslation(
                        translatedText: current.translatedText,
                        isTranslationPending: false
                    )
                }
            }
        }
        translationTasks[segment.id] = task
    }

    private func cancelTranslationTasks() {
        for task in translationTasks.values {
            task.cancel()
        }
        translationTasks.removeAll()
    }

    private func clearPendingTranslationState() {
        overlayState.segments = overlayState.segments.map { segment in
            guard segment.isTranslationPending else { return segment }
            return segment.updatingTranslation(
                translatedText: segment.translatedText,
                isTranslationPending: false
            )
        }
    }

    private func finalizedSegments(from segments: [MeetingTranscriptSegment]) -> [MeetingTranscriptSegment] {
        segments.map { segment in
            guard segment.isTranslationPending else { return segment }
            return segment.updatingTranslation(
                translatedText: segment.translatedText,
                isTranslationPending: false
            )
        }
    }

    private func updateSegment(
        _ segmentID: UUID,
        transform: (MeetingTranscriptSegment) -> MeetingTranscriptSegment
    ) {
        guard let index = overlayState.segments.firstIndex(where: { $0.id == segmentID }) else { return }
        overlayState.segments[index] = transform(overlayState.segments[index])
    }

    private func resolvedMeetingMainLanguage() -> UserMainLanguageOption {
        let storedCodes = UserDefaults.standard.string(forKey: AppPreferenceKey.userMainLanguageCodes)
        let selectedOptions = UserMainLanguageOption.storedSelection(from: storedCodes)
        if let firstCode = selectedOptions.first,
           let option = UserMainLanguageOption.option(for: firstCode) {
            return option
        }
        return UserMainLanguageOption.fallbackOption()
    }

    private func resolvedMeetingHintPayload(settings: ASRHintSettings) -> ResolvedASRHintPayload {
        let storedCodes = UserDefaults.standard.string(forKey: AppPreferenceKey.userMainLanguageCodes)
        let userLanguageCodes = UserMainLanguageOption.storedSelection(from: storedCodes)
        return ASRHintResolver.resolve(
            target: .whisperKit,
            settings: settings,
            userLanguageCodes: userLanguageCodes
        )
    }

    private static func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        AudioLevelMeter.monoSamples(from: buffer)
    }
}
