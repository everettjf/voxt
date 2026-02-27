import SwiftUI
import AppKit
import Carbon

private struct HotkeyConflictRule {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let message: String
}

private let hotkeyConflictRules: [HotkeyConflictRule] = [
    HotkeyConflictRule(keyCode: UInt16(kVK_Space), modifiers: [.command], message: "Conflicts with Spotlight (⌘Space)."),
    HotkeyConflictRule(keyCode: UInt16(kVK_Space), modifiers: [.command, .option], message: "Conflicts with Finder search (⌥⌘Space)."),
    HotkeyConflictRule(keyCode: UInt16(kVK_Tab), modifiers: [.command], message: "Conflicts with App Switcher (⌘Tab)."),
    HotkeyConflictRule(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [.command], message: "Conflicts with window switcher (⌘`)."),
    HotkeyConflictRule(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command], message: "Conflicts with Quit (⌘Q)."),
    HotkeyConflictRule(keyCode: UInt16(kVK_ANSI_H), modifiers: [.command], message: "Conflicts with Hide (⌘H)."),
    HotkeyConflictRule(keyCode: UInt16(kVK_ANSI_M), modifiers: [.command], message: "Conflicts with Minimise (⌘M)."),
    HotkeyConflictRule(keyCode: UInt16(kVK_ANSI_W), modifiers: [.command], message: "Conflicts with Close (⌘W).")
]

struct HotkeySettingsView: View {
    @AppStorage(AppPreferenceKey.hotkeyKeyCode) private var hotkeyKeyCode = Int(HotkeyPreference.defaultKeyCode)
    @AppStorage(AppPreferenceKey.hotkeyModifiers) private var hotkeyModifiers = Int(HotkeyPreference.defaultModifiers.rawValue)
    @AppStorage(AppPreferenceKey.hotkeyTriggerMode) private var hotkeyTriggerMode = HotkeyPreference.defaultTriggerMode.rawValue

    @State private var isRecordingHotkey = false

    private var hotkeyBinding: Binding<UInt16> {
        Binding(
            get: { UInt16(hotkeyKeyCode) },
            set: { hotkeyKeyCode = Int($0) }
        )
    }

    private var modifierBinding: Binding<NSEvent.ModifierFlags> {
        Binding(
            get: { NSEvent.ModifierFlags(rawValue: UInt(hotkeyModifiers)).intersection(.hotkeyRelevant) },
            set: { hotkeyModifiers = Int($0.rawValue) }
        )
    }

    private var currentHotkey: HotkeyPreference.Hotkey {
        HotkeyPreference.Hotkey(
            keyCode: hotkeyBinding.wrappedValue,
            modifiers: modifierBinding.wrappedValue
        )
    }

    private var triggerModeBinding: Binding<HotkeyPreference.TriggerMode> {
        Binding(
            get: { HotkeyPreference.TriggerMode(rawValue: hotkeyTriggerMode) ?? .longPress },
            set: { hotkeyTriggerMode = $0.rawValue }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Shortcut")
                        .font(.headline)

                    HStack {
                        Text("Current")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(HotkeyPreference.displayString(for: currentHotkey))
                            .font(.system(.body, design: .rounded))
                    }

                    Button(isRecordingHotkey ? "Press keys…" : "Record Shortcut") {
                        isRecordingHotkey = true
                    }
                    .disabled(isRecordingHotkey)

                    if isRecordingHotkey {
                        Text("Press a key combination. Esc cancels.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HotkeyRecorderView(
                            keyCode: hotkeyBinding,
                            modifiers: modifierBinding,
                            isRecording: $isRecordingHotkey
                        )
                        .frame(width: 0, height: 0)
                    }

                    if let conflict = hotkeyConflictMessage(for: currentHotkey) {
                        Text(conflict)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    HStack(alignment: .center, spacing: 12) {
                        Text("Trigger")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Trigger", selection: triggerModeBinding) {
                            ForEach(HotkeyPreference.TriggerMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tips")
                        .font(.headline)
                    Text("Choose a shortcut that you can comfortably hold while speaking.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }

    private func hotkeyConflictMessage(for hotkey: HotkeyPreference.Hotkey) -> String? {
        if hotkey.modifiers.isEmpty {
            return "Shortcut should include at least one modifier key."
        }

        return hotkeyConflictRules.first {
            hotkey.keyCode == $0.keyCode && hotkey.modifiers == $0.modifiers
        }?.message
    }
}
