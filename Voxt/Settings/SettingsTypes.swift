import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case history
    case model
    case hotkey
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .history: return "History"
        case .model: return "Model"
        case .hotkey: return "Hotkey"
        case .about: return "About"
        }
    }

    var iconName: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .history: return "clock.arrow.circlepath"
        case .model: return "waveform"
        case .hotkey: return "keyboard"
        case .about: return "info.circle"
        }
    }
}

struct SettingsSectionHeader: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title2.weight(.semibold))
            Divider()
        }
    }
}
