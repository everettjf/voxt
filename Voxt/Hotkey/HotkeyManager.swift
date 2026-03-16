import Foundation
import Carbon
import AppKit
import ApplicationServices

/// Monitors a global hotkey via a CGEvent tap.
/// - Press and hold hotkey key  → calls `onKeyDown`
/// - Release hotkey key         → calls `onKeyUp`
@MainActor
class HotkeyManager {
    // Hotkey state machine notes:
    // 1) Translation shortcut has higher priority than transcription.
    // 2) For modifier-only tap mode (fn / fn+shift), we emit "down" as toggle signal.
    // 3) We intentionally delay transcription tap by 80ms when translation combo is a superset
    //    (e.g. fn vs fn+shift), so quick combo presses do not accidentally fire fn.
    // 4) We keep a short cooldown after translation transitions to suppress stray fn tap events.
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onTranslationKeyDown: (() -> Void)?
    var onTranslationKeyUp: (() -> Void)?
    var onRewriteKeyDown: (() -> Void)?
    var onRewriteKeyUp: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isKeyDown = false
    private var activeKeyCode: UInt16?
    private var isTranslationKeyDown = false
    private var activeTranslationKeyCode: UInt16?
    private var isRewriteKeyDown = false
    private var activeRewriteKeyCode: UInt16?
    private var currentSidedModifiers: SidedModifierFlags = []
    private var suppressTranscriptionTapUntil = Date.distantPast
    private var pendingTranscriptionTapTask: Task<Void, Never>?
    private var pendingTranscriptionLongPressReleaseTask: Task<Void, Never>?
    private var pendingTranslationLongPressReleaseTask: Task<Void, Never>?
    private var pendingRewriteLongPressReleaseTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var didPromptAccessibility = false
    private var didPromptInputMonitoring = false

    func start() {
        if eventTap != nil {
            return
        }
        let transcriptionHotkey = HotkeyPreference.load()
        let translationHotkey = HotkeyPreference.loadTranslation()
        let rewriteHotkey = HotkeyPreference.loadRewrite()
        let distinguishModifierSides = HotkeyPreference.loadDistinguishModifierSides()
        VoxtLog.info("Starting hotkey manager.")
        VoxtLog.hotkey(
            "Hotkey bindings. transcription=\(HotkeyPreference.displayString(for: transcriptionHotkey, distinguishModifierSides: distinguishModifierSides)), translation=\(HotkeyPreference.displayString(for: translationHotkey, distinguishModifierSides: distinguishModifierSides)), rewrite=\(HotkeyPreference.displayString(for: rewriteHotkey, distinguishModifierSides: distinguishModifierSides)), trigger=\(HotkeyPreference.loadTriggerMode().rawValue)"
        )
        guard preflightAndPromptPermissionsIfNeeded() else {
            scheduleRetry()
            return
        }
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        guard let (tap, tapLocation) = createEventTap(eventMask: eventMask) else {
            VoxtLog.error("Failed to create event tap. \(permissionStatusText())")
            scheduleRetry()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        retryTask?.cancel()
        retryTask = nil
        VoxtLog.hotkey("Hotkey event tap started successfully. location=\(tapLocation.debugName)")
    }

    func stop() {
        VoxtLog.info("Stopping hotkey manager.")
        retryTask?.cancel()
        retryTask = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isKeyDown = false
        activeKeyCode = nil
        isTranslationKeyDown = false
        activeTranslationKeyCode = nil
        isRewriteKeyDown = false
        activeRewriteKeyCode = nil
        currentSidedModifiers = []
        pendingTranscriptionTapTask?.cancel()
        pendingTranscriptionTapTask = nil
        pendingTranscriptionLongPressReleaseTask?.cancel()
        pendingTranscriptionLongPressReleaseTask = nil
        pendingTranslationLongPressReleaseTask?.cancel()
        pendingTranslationLongPressReleaseTask = nil
        pendingRewriteLongPressReleaseTask?.cancel()
        pendingRewriteLongPressReleaseTask = nil
        VoxtLog.hotkey("Hotkey manager stopped.")
    }

    private func preflightAndPromptPermissionsIfNeeded() -> Bool {
        let currentStatus = EventListeningPermissionManager.status()
        let accessibilityGranted = currentStatus.accessibilityGranted
        let inputMonitoringGranted = currentStatus.inputMonitoringGranted

        guard accessibilityGranted, inputMonitoringGranted else {
            if !accessibilityGranted, !didPromptAccessibility {
                didPromptAccessibility = true
                _ = AccessibilityPermissionManager.request(prompt: true)
            }
            if !inputMonitoringGranted, !didPromptInputMonitoring {
                didPromptInputMonitoring = true
                _ = EventListeningPermissionManager.requestInputMonitoring(prompt: true)
            }
            VoxtLog.hotkey("Hotkey preflight blocked. \(permissionStatusText())")
            return false
        }

        return true
    }

    private func permissionStatusText() -> String {
        EventListeningPermissionManager.status().description
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.eventTap == nil {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self.start()
            }
        }
    }

    private func createEventTap(eventMask: CGEventMask) -> (tap: CFMachPort, location: CGEventTapLocation)? {
        let callback: CGEventTapCallBack = { _, type, event, refcon -> Unmanaged<CGEvent>? in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            manager.handleEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        for tapLocation in [CGEventTapLocation.cghidEventTap, .cgSessionEventTap] {
            if let tap = CGEvent.tapCreate(
                tap: tapLocation,
                place: .tailAppendEventTap,
                options: .listenOnly,
                eventsOfInterest: eventMask,
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) {
                return (tap, tapLocation)
            }
        }

        return nil
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        guard !UserDefaults.standard.bool(forKey: AppPreferenceKey.hotkeyCaptureInProgress) else {
            return
        }
        let transcriptionHotkey = HotkeyPreference.load()
        let translationHotkey = HotkeyPreference.loadTranslation()
        let rewriteHotkey = HotkeyPreference.loadRewrite()
        let distinguishModifierSides = HotkeyPreference.loadDistinguishModifierSides()
        let triggerMode = HotkeyPreference.loadTriggerMode()
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if type == .flagsChanged {
            currentSidedModifiers = SidedModifierFlags.toggled(from: currentSidedModifiers, keyCode: keyCode)
        }
        let transcriptionFlags = HotkeyPreference.cgFlags(from: transcriptionHotkey.modifiers)
        let translationFlags = HotkeyPreference.cgFlags(from: translationHotkey.modifiers)
        let rewriteFlags = HotkeyPreference.cgFlags(from: rewriteHotkey.modifiers)
        let wasTranslationKeyDown = isTranslationKeyDown
        let wasRewriteKeyDown = isRewriteKeyDown

        if type == .flagsChanged,
           triggerMode == .tap,
           (HotkeyModifierInterpreter.isModifierOnly(transcriptionHotkey)
            || HotkeyModifierInterpreter.isModifierOnly(translationHotkey)
            || HotkeyModifierInterpreter.isModifierOnly(rewriteHotkey)) {
            VoxtLog.hotkey(
                "Hotkey flagsChanged(tap). keyCode=\(keyCode), flags=\(debugDescription(for: flags)), tHotkey=\(debugDescription(for: transcriptionFlags)), trHotkey=\(debugDescription(for: translationFlags)), rwHotkey=\(debugDescription(for: rewriteFlags)), isKeyDown=\(isKeyDown), isTranslationKeyDown=\(isTranslationKeyDown), isRewriteKeyDown=\(isRewriteKeyDown), suppressRemainingMs=\(max(Int(suppressTranscriptionTapUntil.timeIntervalSinceNow * 1000), 0))"
            )
        }

        // Translation path must be evaluated first. If this ordering changes,
        // fn-only transcription can steal fn+shift transitions and cause flicker/auto-close regressions.
        if HotkeyModifierInterpreter.isModifierOnly(translationHotkey) {
            if handleModifierOnlyTranslationEvent(
                type: type,
                keyCode: keyCode,
                flags: flags,
                currentSidedModifiers: currentSidedModifiers,
                translationHotkey: translationHotkey,
                distinguishModifierSides: distinguishModifierSides,
                triggerMode: triggerMode,
                translationFlags: translationFlags,
                wasTranslationKeyDown: wasTranslationKeyDown
            ) {
                return
            }
        } else {
            let translationFlagsMatch = HotkeyPreference.hotkeyMatches(
                translationHotkey,
                eventFlags: flags,
                sidedModifiers: currentSidedModifiers,
                distinguishModifierSides: distinguishModifierSides
            )
            switch type {
            case .keyDown:
                if keyCode == translationHotkey.keyCode, translationFlagsMatch, !isAutoRepeat {
                    if triggerMode == .tap {
                        emitTranslationKeyDown()
                    } else if !isTranslationKeyDown {
                        isTranslationKeyDown = true
                        activeTranslationKeyCode = keyCode
                        emitTranslationKeyDown()
                    }
                    return
                }
            case .keyUp:
                if triggerMode == .tap {
                    if activeTranslationKeyCode == keyCode {
                        activeTranslationKeyCode = nil
                    }
                    if keyCode == translationHotkey.keyCode {
                        emitTranslationKeyUp()
                        return
                    }
                } else if isTranslationKeyDown, activeTranslationKeyCode == keyCode {
                    isTranslationKeyDown = false
                    activeTranslationKeyCode = nil
                    emitTranslationKeyUp()
                    return
                }
            default:
                break
            }
        }

        if HotkeyModifierInterpreter.isModifierOnly(rewriteHotkey) {
            if handleModifierOnlyRewriteEvent(
                type: type,
                keyCode: keyCode,
                flags: flags,
                currentSidedModifiers: currentSidedModifiers,
                rewriteHotkey: rewriteHotkey,
                distinguishModifierSides: distinguishModifierSides,
                triggerMode: triggerMode,
                rewriteFlags: rewriteFlags,
                wasRewriteKeyDown: wasRewriteKeyDown
            ) {
                return
            }
        } else {
            let rewriteFlagsMatch = HotkeyPreference.hotkeyMatches(
                rewriteHotkey,
                eventFlags: flags,
                sidedModifiers: currentSidedModifiers,
                distinguishModifierSides: distinguishModifierSides
            )
            switch type {
            case .keyDown:
                if keyCode == rewriteHotkey.keyCode, rewriteFlagsMatch, !isAutoRepeat {
                    if triggerMode == .tap {
                        emitRewriteKeyDown()
                    } else if !isRewriteKeyDown {
                        isRewriteKeyDown = true
                        activeRewriteKeyCode = keyCode
                        emitRewriteKeyDown()
                    }
                    return
                }
            case .keyUp:
                if triggerMode == .tap {
                    if activeRewriteKeyCode == keyCode {
                        activeRewriteKeyCode = nil
                    }
                    if keyCode == rewriteHotkey.keyCode {
                        emitRewriteKeyUp()
                        return
                    }
                } else if isRewriteKeyDown, activeRewriteKeyCode == keyCode {
                    isRewriteKeyDown = false
                    activeRewriteKeyCode = nil
                    emitRewriteKeyUp()
                    return
                }
            default:
                break
            }
        }

        // Transcription path runs after translation handling.
        // This keeps fn+shift and fn responsibilities separated.
        if HotkeyModifierInterpreter.isModifierOnly(transcriptionHotkey) {
            if handleModifierOnlyTranscriptionEvent(
                type: type,
                keyCode: keyCode,
                flags: flags,
                triggerMode: triggerMode,
                transcriptionHotkey: transcriptionHotkey,
                translationHotkey: translationHotkey,
                rewriteHotkey: rewriteHotkey,
                currentSidedModifiers: currentSidedModifiers,
                distinguishModifierSides: distinguishModifierSides,
                transcriptionFlags: transcriptionFlags,
                translationFlags: translationFlags,
                rewriteFlags: rewriteFlags
            ) {
                return
            }
            return
        }

        let transcriptionFlagsMatch = HotkeyPreference.hotkeyMatches(
            transcriptionHotkey,
            eventFlags: flags,
            sidedModifiers: currentSidedModifiers,
            distinguishModifierSides: distinguishModifierSides
        )
        switch type {
        case .keyDown:
            guard keyCode == transcriptionHotkey.keyCode, transcriptionFlagsMatch, !isAutoRepeat else { return }
            if triggerMode == .tap {
                emitKeyDown()
            } else if !isKeyDown {
                isKeyDown = true
                activeKeyCode = keyCode
                emitKeyDown()
            }
        case .keyUp:
            if triggerMode == .tap {
                if activeKeyCode == keyCode {
                    activeKeyCode = nil
                }
                if keyCode == transcriptionHotkey.keyCode {
                    emitKeyUp()
                }
                return
            }
            if isKeyDown, activeKeyCode == keyCode {
                isKeyDown = false
                activeKeyCode = nil
                emitKeyUp()
            }
        default:
            break
        }
    }

    private func shouldDelayTranscriptionTap(
        transcriptionHotkey: HotkeyPreference.Hotkey,
        translationHotkey: HotkeyPreference.Hotkey,
        rewriteHotkey: HotkeyPreference.Hotkey,
        transcriptionFlags: CGEventFlags,
        translationFlags: CGEventFlags,
        rewriteFlags: CGEventFlags
    ) -> Bool {
        HotkeyModifierInterpreter.shouldDelayTranscriptionTap(
            transcriptionHotkey: transcriptionHotkey,
            prioritizedModifierHotkeys: [translationHotkey, rewriteHotkey],
            transcriptionFlags: transcriptionFlags,
            prioritizedFlags: [translationFlags, rewriteFlags]
        )
    }

    private func handleModifierOnlyTranslationEvent(
        type: CGEventType,
        keyCode: UInt16,
        flags: CGEventFlags,
        currentSidedModifiers: SidedModifierFlags,
        translationHotkey: HotkeyPreference.Hotkey,
        distinguishModifierSides: Bool,
        triggerMode: HotkeyPreference.TriggerMode,
        translationFlags: CGEventFlags,
        wasTranslationKeyDown: Bool
    ) -> Bool {
        guard type == .flagsChanged else { return false }

        let comboIsDown = HotkeyPreference.hotkeyMatches(
            translationHotkey,
            eventFlags: flags,
            sidedModifiers: currentSidedModifiers,
            distinguishModifierSides: distinguishModifierSides
        )
        let translationTriggerDown = HotkeyModifierInterpreter.translationTriggerDown(
            keyCode: keyCode,
            comboIsDown: comboIsDown,
            translationFlags: translationFlags
        )

        if triggerMode == .tap {
            // Tap semantics:
            // - Translation combo emits only "down" and acts as a start trigger.
            // - Stop action is centralized to transcription hotkey tap (fn) in AppDelegate.
            // - We still track combo-up to enter a short suppression window for fn stray events.
            if translationTriggerDown && !isTranslationKeyDown {
                VoxtLog.info("Hotkey detect translation modifier combo down (tap).", verbose: true)
                cancelPendingTranscriptionTap(resetKeyState: true)
                isTranslationKeyDown = true
                suppressTranscriptionTapUntil = Date().addingTimeInterval(0.35)
                emitTranslationKeyDown()
            }
            if !comboIsDown && isTranslationKeyDown {
                VoxtLog.info("Hotkey detect translation modifier combo up (tap).", verbose: true)
                isTranslationKeyDown = false
                // Small cooldown to absorb release-order jitter (shift up then fn up).
                suppressTranscriptionTapUntil = Date().addingTimeInterval(0.20)
            }
            // Consume translation combo transitions to avoid falling through
            // into transcription fn-only handling during release sequence.
            return wasTranslationKeyDown != isTranslationKeyDown || comboIsDown
        }

        if comboIsDown {
            cancelPendingTranslationLongPressRelease()
        }
        if comboIsDown && !isTranslationKeyDown {
            VoxtLog.info("Hotkey detect translation modifier combo down (longPress).", verbose: true)
            isTranslationKeyDown = true
            emitTranslationKeyDown()
        } else if !comboIsDown && isTranslationKeyDown {
            VoxtLog.info("Hotkey detect translation modifier combo up (longPress-pending).", verbose: true)
            scheduleTranslationLongPressRelease()
        } else if translationFlags == .maskSecondaryFn && HotkeyModifierInterpreter.isFunctionKeyEvent(keyCode) {
            if isTranslationKeyDown {
                isTranslationKeyDown = false
                emitTranslationKeyUp()
            } else {
                isTranslationKeyDown = true
                emitTranslationKeyDown()
            }
        }
        return false
    }

    private func handleModifierOnlyRewriteEvent(
        type: CGEventType,
        keyCode: UInt16,
        flags: CGEventFlags,
        currentSidedModifiers: SidedModifierFlags,
        rewriteHotkey: HotkeyPreference.Hotkey,
        distinguishModifierSides: Bool,
        triggerMode: HotkeyPreference.TriggerMode,
        rewriteFlags: CGEventFlags,
        wasRewriteKeyDown: Bool
    ) -> Bool {
        guard type == .flagsChanged else { return false }

        let comboIsDown = HotkeyPreference.hotkeyMatches(
            rewriteHotkey,
            eventFlags: flags,
            sidedModifiers: currentSidedModifiers,
            distinguishModifierSides: distinguishModifierSides
        )
        let rewriteTriggerDown = HotkeyModifierInterpreter.translationTriggerDown(
            keyCode: keyCode,
            comboIsDown: comboIsDown,
            translationFlags: rewriteFlags
        )

        if triggerMode == .tap {
            if rewriteTriggerDown && !isRewriteKeyDown {
                VoxtLog.hotkey("Hotkey detect rewrite modifier combo down (tap).")
                cancelPendingTranscriptionTap(resetKeyState: true)
                isRewriteKeyDown = true
                suppressTranscriptionTapUntil = Date().addingTimeInterval(0.35)
                emitRewriteKeyDown()
            }
            if !comboIsDown && isRewriteKeyDown {
                VoxtLog.hotkey("Hotkey detect rewrite modifier combo up (tap).")
                isRewriteKeyDown = false
                suppressTranscriptionTapUntil = Date().addingTimeInterval(0.20)
            }
            return wasRewriteKeyDown != isRewriteKeyDown || comboIsDown
        }

        if comboIsDown {
            cancelPendingRewriteLongPressRelease()
        }
        if comboIsDown && !isRewriteKeyDown {
            VoxtLog.hotkey("Hotkey detect rewrite modifier combo down (longPress).")
            isRewriteKeyDown = true
            emitRewriteKeyDown()
        } else if !comboIsDown && isRewriteKeyDown {
            VoxtLog.hotkey("Hotkey detect rewrite modifier combo up (longPress-pending).")
            scheduleRewriteLongPressRelease()
        } else if rewriteFlags == .maskSecondaryFn && HotkeyModifierInterpreter.isFunctionKeyEvent(keyCode) {
            if isRewriteKeyDown {
                isRewriteKeyDown = false
                emitRewriteKeyUp()
            } else {
                isRewriteKeyDown = true
                emitRewriteKeyDown()
            }
        }
        return false
    }

    private func handleModifierOnlyTranscriptionEvent(
        type: CGEventType,
        keyCode: UInt16,
        flags: CGEventFlags,
        triggerMode: HotkeyPreference.TriggerMode,
        transcriptionHotkey: HotkeyPreference.Hotkey,
        translationHotkey: HotkeyPreference.Hotkey,
        rewriteHotkey: HotkeyPreference.Hotkey,
        currentSidedModifiers: SidedModifierFlags,
        distinguishModifierSides: Bool,
        transcriptionFlags: CGEventFlags,
        translationFlags: CGEventFlags,
        rewriteFlags: CGEventFlags
    ) -> Bool {
        guard type == .flagsChanged else { return true }

        // If translation or rewrite modifier combo is active, suppress transcription trigger.
        if (HotkeyModifierInterpreter.isModifierOnly(translationHotkey) &&
            (HotkeyPreference.hotkeyMatches(
                translationHotkey,
                eventFlags: flags,
                sidedModifiers: currentSidedModifiers,
                distinguishModifierSides: distinguishModifierSides
            ) || isTranslationKeyDown)) ||
            (HotkeyModifierInterpreter.isModifierOnly(rewriteHotkey) &&
            (HotkeyPreference.hotkeyMatches(
                rewriteHotkey,
                eventFlags: flags,
                sidedModifiers: currentSidedModifiers,
                distinguishModifierSides: distinguishModifierSides
            ) || isRewriteKeyDown)) {
            VoxtLog.info("Hotkey suppress transcription modifier path because higher-priority combo is active.", verbose: true)
            cancelPendingTranscriptionTap(resetKeyState: true)
            return true
        }

        let comboIsDown = HotkeyPreference.hotkeyMatches(
            transcriptionHotkey,
            eventFlags: flags,
            sidedModifiers: currentSidedModifiers,
            distinguishModifierSides: distinguishModifierSides
        )
        let transcriptionTriggerDown = HotkeyModifierInterpreter.transcriptionTriggerDown(
            keyCode: keyCode,
            comboIsDown: comboIsDown,
            transcriptionFlags: transcriptionFlags
        )

        if triggerMode == .tap {
            // Tap semantics for modifier-only transcription hotkey:
            // emit only "down" as a toggle signal; release transitions are ignored.
            // Translation cooldown check is critical for fn/fn+shift coexistence.
            if Date() < suppressTranscriptionTapUntil {
                VoxtLog.info("Hotkey suppress transcription tap due to translation cooldown.", verbose: true)
                cancelPendingTranscriptionTap(resetKeyState: true)
                if !comboIsDown && isKeyDown {
                    isKeyDown = false
                }
                return true
            }
            let shouldDelayTap = shouldDelayTranscriptionTap(
                transcriptionHotkey: transcriptionHotkey,
                translationHotkey: translationHotkey,
                rewriteHotkey: rewriteHotkey,
                transcriptionFlags: transcriptionFlags,
                translationFlags: translationFlags,
                rewriteFlags: rewriteFlags
            )
            if shouldDelayTap {
                // 80ms "combo disambiguation window":
                // if shift arrives quickly, translation path takes over and fn tap is dropped.
                if transcriptionTriggerDown && !isKeyDown {
                    if flags.contains(translationFlags) || flags.contains(rewriteFlags) {
                        VoxtLog.hotkey("Hotkey delay transcription tap aborted because higher-priority flags are active.")
                        return true
                    }
                    isKeyDown = true
                    VoxtLog.hotkey("Hotkey scheduling delayed transcription tap.")
                    schedulePendingTranscriptionTap()
                }
                if !comboIsDown && isKeyDown {
                    // In tap mode we flush immediately so quick fn press still toggles reliably.
                    VoxtLog.hotkey("Hotkey releasing delayed transcription tap.")
                    flushPendingTranscriptionTapIfNeeded()
                    isKeyDown = false
                }
                return true
            }
            if transcriptionTriggerDown && !isKeyDown {
                if flags.contains(translationFlags) || flags.contains(rewriteFlags) {
                    VoxtLog.hotkey("Hotkey transcription tap ignored because higher-priority flags are active.")
                    return true
                }
                isKeyDown = true
                emitKeyDown()
            }
            if !comboIsDown && isKeyDown {
                isKeyDown = false
            }
            cancelPendingTranscriptionTap(resetKeyState: false)
            return true
        }

        if comboIsDown && !isKeyDown {
            cancelPendingTranscriptionLongPressRelease()
            isKeyDown = true
            emitKeyDown()
        } else if !comboIsDown && isKeyDown {
            // Long-press release is confirmed with a short delay to tolerate
            // transient flags jitter on fn/shift combinations.
            scheduleTranscriptionLongPressRelease()
        } else if transcriptionFlags == .maskSecondaryFn && HotkeyModifierInterpreter.isFunctionKeyEvent(keyCode) {
            if isKeyDown {
                isKeyDown = false
                emitKeyUp()
            } else {
                isKeyDown = true
                emitKeyDown()
            }
        }
        return true
    }

    private func schedulePendingTranscriptionTap() {
        pendingTranscriptionTapTask?.cancel()
        pendingTranscriptionTapTask = Task { [weak self] in
            do {
                // Keep this in sync with AppDelegate.transcriptionStartDebounceInterval (80ms).
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard self.isKeyDown, !self.isTranslationKeyDown else {
                VoxtLog.info("Hotkey delayed transcription tap dropped. isKeyDown=\(self.isKeyDown), isTranslationKeyDown=\(self.isTranslationKeyDown)", verbose: true)
                return
            }
            self.pendingTranscriptionTapTask = nil
            VoxtLog.hotkey("Hotkey delayed transcription tap fired.")
            self.emitKeyDown()
        }
    }

    private func flushPendingTranscriptionTapIfNeeded() {
        guard pendingTranscriptionTapTask != nil else { return }
        pendingTranscriptionTapTask?.cancel()
        pendingTranscriptionTapTask = nil
        if isKeyDown, !isTranslationKeyDown {
            VoxtLog.hotkey("Hotkey delayed transcription tap flushed immediately.")
            emitKeyDown()
        }
    }

    private func cancelPendingTranscriptionTap(resetKeyState: Bool) {
        pendingTranscriptionTapTask?.cancel()
        pendingTranscriptionTapTask = nil
        if resetKeyState {
            VoxtLog.hotkey("Hotkey delayed transcription tap canceled and key state reset.")
            isKeyDown = false
        }
    }

    private func scheduleTranslationLongPressRelease() {
        pendingTranslationLongPressReleaseTask?.cancel()
        pendingTranslationLongPressReleaseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard self.isTranslationKeyDown else { return }
            self.pendingTranslationLongPressReleaseTask = nil
            self.isTranslationKeyDown = false
            self.emitTranslationKeyUp()
        }
    }

    private func cancelPendingTranslationLongPressRelease() {
        pendingTranslationLongPressReleaseTask?.cancel()
        pendingTranslationLongPressReleaseTask = nil
    }

    private func scheduleRewriteLongPressRelease() {
        pendingRewriteLongPressReleaseTask?.cancel()
        pendingRewriteLongPressReleaseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard self.isRewriteKeyDown else { return }
            self.pendingRewriteLongPressReleaseTask = nil
            self.isRewriteKeyDown = false
            self.emitRewriteKeyUp()
        }
    }

    private func cancelPendingRewriteLongPressRelease() {
        pendingRewriteLongPressReleaseTask?.cancel()
        pendingRewriteLongPressReleaseTask = nil
    }

    private func scheduleTranscriptionLongPressRelease() {
        pendingTranscriptionLongPressReleaseTask?.cancel()
        pendingTranscriptionLongPressReleaseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
            } catch {
                return
            }
            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard self.isKeyDown else { return }
            self.pendingTranscriptionLongPressReleaseTask = nil
            self.isKeyDown = false
            self.emitKeyUp()
        }
    }

    private func cancelPendingTranscriptionLongPressRelease() {
        pendingTranscriptionLongPressReleaseTask?.cancel()
        pendingTranscriptionLongPressReleaseTask = nil
    }

    private func emitKeyDown() {
        Task { @MainActor in
            onKeyDown?()
        }
    }

    private func emitKeyUp() {
        Task { @MainActor in
            onKeyUp?()
        }
    }

    private func emitTranslationKeyDown() {
        Task { @MainActor in
            onTranslationKeyDown?()
        }
    }

    private func emitTranslationKeyUp() {
        Task { @MainActor in
            onTranslationKeyUp?()
        }
    }

    private func emitRewriteKeyDown() {
        Task { @MainActor in
            onRewriteKeyDown?()
        }
    }

    private func emitRewriteKeyUp() {
        Task { @MainActor in
            onRewriteKeyUp?()
        }
    }

    private func debugDescription(for flags: CGEventFlags) -> String {
        var values: [String] = []
        if flags.contains(.maskSecondaryFn) { values.append("fn") }
        if flags.contains(.maskShift) { values.append("shift") }
        if flags.contains(.maskControl) { values.append("ctrl") }
        if flags.contains(.maskAlternate) { values.append("opt") }
        if flags.contains(.maskCommand) { values.append("cmd") }
        return values.isEmpty ? "none" : values.joined(separator: "+")
    }
}
