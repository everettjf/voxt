import Foundation
import AppKit
import ApplicationServices
import AVFoundation
import Speech

extension AppDelegate {
    func beginRecording(outputMode: SessionOutputMode) {
        guard !isSessionActive else { return }
        guard preflightPermissionsForRecording() else { return }

        pendingSessionFinishTask?.cancel()
        pendingSessionFinishTask = nil
        stopRecordingFallbackTask?.cancel()
        stopRecordingFallbackTask = nil
        overlayState.isCompleting = false
        setEnhancingState(false)
        recordingStartedAt = Date()
        recordingStoppedAt = nil
        transcriptionProcessingStartedAt = nil
        transcriptionResultReceivedAt = nil
        didCommitSessionOutput = false
        isSessionCancellationRequested = false
        activeRecordingSessionID = UUID()
        sessionOutputMode = outputMode
        enhancementContextSnapshot = nil

        VoxtLog.info(
            "Recording started. output=\(outputMode == .translation ? "translation" : "transcription"), engine=\(transcriptionEngine.rawValue)"
        )

        applyPreferredInputDevice()
        overlayState.statusMessage = ""

        if transcriptionEngine == .mlxAudio {
            switch mlxModelManager.state {
            case .notDownloaded:
                VoxtLog.warning("MLX Audio model not downloaded, falling back to Direct Dictation")
                showOverlayStatus(
                    String(localized: "MLX model is not downloaded. Open Settings > Model to install it."),
                    clearAfter: 2.5
                )
            case .error:
                VoxtLog.warning("MLX Audio model error, falling back to Direct Dictation")
                showOverlayStatus(
                    String(localized: "MLX model is unavailable. Open Settings > Model to fix it."),
                    clearAfter: 2.5
                )
            default:
                break
            }
        }

        isSessionActive = true
        if interactionSoundsEnabled {
            interactionSoundPlayer.playStart()
        }

        if transcriptionEngine == .mlxAudio, isMLXReady {
            startMLXRecordingSession()
        } else if transcriptionEngine == .remote {
            startRemoteRecordingSession()
        } else {
            startSpeechRecordingSession()
        }

        startSilenceMonitoringIfNeeded()
    }

    func endRecording() {
        guard isSessionActive else { return }
        VoxtLog.info("Recording stop requested.")

        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil
        pauseLLMTask?.cancel()
        pauseLLMTask = nil
        stopRecordingFallbackTask?.cancel()
        stopRecordingFallbackTask = nil
        recordingStoppedAt = Date()
        if transcriptionProcessingStartedAt == nil {
            transcriptionProcessingStartedAt = recordingStoppedAt
        }
        enhancementContextSnapshot = captureEnhancementContextSnapshot()

        if transcriptionEngine == .mlxAudio, isMLXReady {
            mlxTranscriber?.stopRecording()
        } else if transcriptionEngine == .remote {
            remoteASRTranscriber.stopRecording()
        } else {
            speechTranscriber.stopRecording()
        }

        // Safety fallback: some engine/device combinations may occasionally fail to
        // report completion. Ensure the session/UI can always recover.
        let fallbackTimeoutSeconds = stopRecordingFallbackTimeoutSeconds()
        stopRecordingFallbackTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(fallbackTimeoutSeconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard self.isSessionActive else { return }
            VoxtLog.warning("Stop recording fallback triggered; forcing session finish.")
            self.finishSession(after: 0)
        }
    }

    func cancelActiveRecordingSession() {
        guard isSessionActive else { return }
        VoxtLog.info("Recording cancelled by Escape key.")

        let cancelledSessionID = activeRecordingSessionID
        activeRecordingSessionID = UUID()
        isSessionCancellationRequested = true
        didCommitSessionOutput = true

        pendingSessionFinishTask?.cancel()
        pendingSessionFinishTask = nil
        stopRecordingFallbackTask?.cancel()
        stopRecordingFallbackTask = nil
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil
        pauseLLMTask?.cancel()
        pauseLLMTask = nil
        recordingStoppedAt = Date()
        overlayState.isCompleting = false
        overlayState.statusMessage = ""
        setEnhancingState(false)

        if transcriptionEngine == .mlxAudio, isMLXReady {
            mlxTranscriber?.stopRecording()
        } else if transcriptionEngine == .remote {
            remoteASRTranscriber.stopRecording()
        } else {
            speechTranscriber.stopRecording()
        }

        VoxtLog.info("Cancelled session invalidated. sessionID=\(cancelledSessionID.uuidString)", verbose: true)
        executeSessionEndPipeline()
    }

    func processTranscription(_ rawText: String) {
        processTranscription(rawText, sessionID: activeRecordingSessionID)
    }

    func processTranscription(_ rawText: String, sessionID: UUID) {
        guard shouldHandleCallbacks(for: sessionID) else { return }
        if didCommitSessionOutput {
            VoxtLog.info("Ignoring transcription callback because current session output has already been committed.")
            return
        }

        stopRecordingFallbackTask?.cancel()
        stopRecordingFallbackTask = nil

        transcriptionResultReceivedAt = Date()
        let text = normalizedTranscriptionDisplayText(rawText)
        guard !text.isEmpty else {
            VoxtLog.info("Transcription result is empty; finishing session.")
            setEnhancingState(false)
            finishSession(after: 0)
            return
        }

        overlayState.transcribedText = text
        if transcriptionEngine == .remote {
            remoteASRTranscriber.transcribedText = text
        } else if transcriptionEngine == .mlxAudio {
            mlxTranscriber?.transcribedText = text
        } else {
            speechTranscriber.transcribedText = text
        }

        VoxtLog.info("Transcription result received. characters=\(text.count), output=\(sessionOutputMode == .translation ? "translation" : "transcription")")
        VoxtLog.info("Enhancement mode=\(enhancementMode.rawValue), appEnhancementEnabled=\(appEnhancementEnabled)")

        if sessionOutputMode == .translation {
            processTranslatedTranscription(text, sessionID: sessionID)
            return
        }

        processStandardTranscription(text, sessionID: sessionID)
    }

    func startPauseLLMIfNeeded() {
        runPauseEnhancementIfNeeded()
    }

    func finishSession(after delay: TimeInterval = 0) {
        pendingSessionFinishTask?.cancel()
        stopRecordingFallbackTask?.cancel()
        stopRecordingFallbackTask = nil
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil
        pauseLLMTask?.cancel()
        pauseLLMTask = nil

        let resolvedDelay = delay > 0 ? delay : sessionFinishDelay
        overlayState.isCompleting = resolvedDelay > 0
        pendingSessionFinishTask = Task { [weak self] in
            guard let self else { return }

            if resolvedDelay > 0 {
                do {
                    try await Task.sleep(for: .seconds(resolvedDelay))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            self.executeSessionEndPipeline()
        }
    }

    func showOverlayStatus(_ message: String, clearAfter seconds: TimeInterval = 2.4) {
        overlayStatusClearTask?.cancel()
        overlayState.statusMessage = message
        overlayStatusClearTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if self.overlayState.statusMessage == message {
                self.overlayState.statusMessage = ""
            }
            self.overlayStatusClearTask = nil
        }
    }

    func showOverlayReminder(_ message: String, autoHideAfter seconds: TimeInterval = 2.4) {
        overlayReminderTask?.cancel()
        overlayStatusClearTask?.cancel()
        overlayState.reset()
        overlayState.statusMessage = message
        overlayWindow.show(state: overlayState, position: overlayPosition)

        overlayReminderTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.overlayWindow.hide()
            self.overlayState.reset()
            self.overlayReminderTask = nil
        }
    }

    func setEnhancingState(_ isEnhancing: Bool) {
        overlayState.isEnhancing = isEnhancing
        if transcriptionEngine == .mlxAudio {
            mlxTranscriber?.isEnhancing = isEnhancing
        } else if transcriptionEngine == .remote {
            remoteASRTranscriber.isEnhancing = isEnhancing
        } else {
            speechTranscriber.isEnhancing = isEnhancing
        }
    }

    private var isMLXReady: Bool {
        switch mlxModelManager.state {
        case .downloaded, .ready, .loading:
            return true
        default:
            return false
        }
    }

    private func startMLXRecordingSession() {
        let mlx = mlxTranscriber ?? MLXTranscriber(modelManager: mlxModelManager)
        mlxTranscriber = mlx
        let sessionID = activeRecordingSessionID
        overlayState.statusMessage = ""
        mlx.setPreferredInputDevice(selectedInputDeviceID)
        mlx.onTranscriptionFinished = { [weak self] text in
            self?.processTranscription(text, sessionID: sessionID)
        }
        overlayState.bind(to: mlx)
        overlayWindow.show(
            state: overlayState,
            position: overlayPosition
        )
        mlx.startRecording()
    }

    private func startSpeechRecordingSession() {
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.speechTranscriber.requestPermissions()
            guard granted else {
                self.showOverlayReminder(
                    String(localized: "Please enable required permissions in Settings > Permissions.")
                )
                return
            }

            self.overlayState.statusMessage = ""
            let sessionID = self.activeRecordingSessionID
            self.speechTranscriber.onTranscriptionFinished = { [weak self] text in
                self?.processTranscription(text, sessionID: sessionID)
            }
            self.overlayState.bind(to: self.speechTranscriber)
            self.overlayWindow.show(
                state: self.overlayState,
                position: self.overlayPosition
            )
            self.speechTranscriber.startRecording()
        }
    }

    private func startRemoteRecordingSession() {
        Task { [weak self] in
            guard let self else { return }
            let granted = await self.remoteASRTranscriber.requestPermissions()
            guard granted else {
                self.showOverlayReminder(
                    String(localized: "Please enable required permissions in Settings > Permissions.")
                )
                return
            }

            self.overlayState.statusMessage = ""
            let sessionID = self.activeRecordingSessionID
            self.remoteASRTranscriber.onTranscriptionFinished = { [weak self] text in
                self?.processTranscription(text, sessionID: sessionID)
            }
            self.overlayState.bind(to: self.remoteASRTranscriber)
            self.overlayWindow.show(
                state: self.overlayState,
                position: self.overlayPosition
            )
            self.remoteASRTranscriber.startRecording()
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private func preflightPermissionsForRecording() -> Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            VoxtLog.warning("Recording blocked: microphone permission not granted.")
            showOverlayReminder(
                String(localized: "Microphone permission is required. Enable it in Settings > Permissions.")
            )
            return false
        }

        if transcriptionEngine == .dictation && SFSpeechRecognizer.authorizationStatus() != .authorized {
            VoxtLog.warning("Recording blocked: speech recognition permission not granted for Direct Dictation.")
            showOverlayReminder(
                String(localized: "Speech Recognition permission is required for Direct Dictation. Enable it in Settings > Permissions.")
            )
            return false
        }

        if !AXIsProcessTrusted() {
            showOverlayStatus(
                String(localized: "Please enable required permissions in Settings > Permissions."),
                clearAfter: 2.2
            )
        }

        return true
    }

    private func normalizedTranscriptionDisplayText(_ rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard transcriptionEngine == .remote, remoteASRSelectedProvider == .openAIWhisper else {
            return trimmed
        }

        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
              (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) else {
            return trimmed
        }

        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let extracted = extractTranscriptionTextValue(from: object),
              !extracted.isEmpty else {
            return trimmed
        }
        return extracted
    }

    private func stopRecordingFallbackTimeoutSeconds() -> TimeInterval {
        guard transcriptionEngine == .remote else { return 8 }
        switch remoteASRSelectedProvider {
        case .openAIWhisper, .glmASR:
            // File-upload ASR can legitimately take longer than realtime providers.
            return 60
        case .doubaoASR, .aliyunBailianASR:
            return 8
        }
    }

    private func extractTranscriptionTextValue(from object: Any) -> String? {
        if let text = object as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let dict = object as? [String: Any] {
            let preferredKeys = ["text", "transcript", "result_text", "utterance", "content", "data"]
            for key in preferredKeys {
                if let value = dict[key],
                   let extracted = extractTranscriptionTextValue(from: value),
                   !extracted.isEmpty {
                    return extracted
                }
            }

            for value in dict.values {
                if let extracted = extractTranscriptionTextValue(from: value),
                   !extracted.isEmpty {
                    return extracted
                }
            }
            return nil
        }

        if let array = object as? [Any] {
            for item in array {
                if let extracted = extractTranscriptionTextValue(from: item),
                   !extracted.isEmpty {
                    return extracted
                }
            }
        }

        return nil
    }

    private func applyPreferredInputDevice() {
        speechTranscriber.setPreferredInputDevice(selectedInputDeviceID)
        mlxTranscriber?.setPreferredInputDevice(selectedInputDeviceID)
    }

    private func startSilenceMonitoringIfNeeded() {
        silenceMonitorTask?.cancel()
        pauseLLMTask?.cancel()
        pauseLLMTask = nil

        guard transcriptionEngine == .mlxAudio else { return }

        lastSignificantAudioAt = Date()
        didTriggerPauseTranscription = false
        didTriggerPauseLLM = false

        silenceMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isSessionActive {
                guard self.overlayState.isRecording else {
                    do {
                        try await Task.sleep(for: .milliseconds(200))
                    } catch {
                        return
                    }
                    continue
                }

                let level = self.overlayState.audioLevel
                if level > self.silenceAudioLevelThreshold {
                    self.lastSignificantAudioAt = Date()
                    self.didTriggerPauseTranscription = false
                    self.didTriggerPauseLLM = false
                    self.pauseLLMTask?.cancel()
                    self.pauseLLMTask = nil
                    self.setEnhancingState(false)
                } else {
                    let silentDuration = Date().timeIntervalSince(self.lastSignificantAudioAt)

                    if silentDuration >= 2.0, !self.didTriggerPauseTranscription {
                        self.didTriggerPauseTranscription = true
                        self.mlxTranscriber?.forceIntermediateTranscription()
                    }

                    if silentDuration >= 4.0, !self.didTriggerPauseLLM {
                        self.didTriggerPauseLLM = true
                        self.startPauseLLMIfNeeded()
                    }
                }

                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
            }
        }
    }
}
