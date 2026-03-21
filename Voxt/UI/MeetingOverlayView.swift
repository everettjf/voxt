import SwiftUI

struct MeetingOverlayContainerView: View {
    @ObservedObject var state: MeetingOverlayState
    let onClose: () -> Void
    let onToggleCollapse: () -> Void
    let onTogglePause: () -> Void
    let onShowDetail: () -> Void
    let onRealtimeTranslateToggle: (Bool) -> Void
    let onConfirmRealtimeTranslationLanguage: () -> Void
    let onCancelRealtimeTranslationLanguage: () -> Void
    let onConfirmCancelMeeting: () -> Void
    let onConfirmFinishMeeting: () -> Void
    let onDismissCloseConfirmation: () -> Void
    let onCopySegment: (MeetingTranscriptSegment) -> Void

    var body: some View {
        MeetingOverlayCard(
            state: state,
            onClose: onClose,
            onToggleCollapse: onToggleCollapse,
            onTogglePause: onTogglePause,
            onShowDetail: onShowDetail,
            onRealtimeTranslateToggle: onRealtimeTranslateToggle,
            onConfirmRealtimeTranslationLanguage: onConfirmRealtimeTranslationLanguage,
            onCancelRealtimeTranslationLanguage: onCancelRealtimeTranslationLanguage,
            onConfirmCancelMeeting: onConfirmCancelMeeting,
            onConfirmFinishMeeting: onConfirmFinishMeeting,
            onDismissCloseConfirmation: onDismissCloseConfirmation,
            onCopySegment: onCopySegment
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
    }
}

private struct MeetingOverlayCard: View {
    @AppStorage(AppPreferenceKey.overlayCardOpacity) private var overlayCardOpacity = 82
    @AppStorage(AppPreferenceKey.overlayCardCornerRadius) private var overlayCardCornerRadius = 24

    @ObservedObject var state: MeetingOverlayState
    let onClose: () -> Void
    let onToggleCollapse: () -> Void
    let onTogglePause: () -> Void
    let onShowDetail: () -> Void
    let onRealtimeTranslateToggle: (Bool) -> Void
    let onConfirmRealtimeTranslationLanguage: () -> Void
    let onCancelRealtimeTranslationLanguage: () -> Void
    let onConfirmCancelMeeting: () -> Void
    let onConfirmFinishMeeting: () -> Void
    let onDismissCloseConfirmation: () -> Void
    let onCopySegment: (MeetingTranscriptSegment) -> Void

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                header

                if !state.isCollapsed {
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 1)

                    transcriptContent
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, state.isCollapsed ? 12 : 16)
            .background(cardBackground)
            .compositingGroup()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )

            if state.isCloseConfirmationPresented || state.isRealtimeTranslationLanguagePickerPresented {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture {
                        if state.isCloseConfirmationPresented {
                            onDismissCloseConfirmation()
                        }
                    }

                if state.isCloseConfirmationPresented {
                    meetingCloseConfirmationDialog
                } else {
                    realtimeTranslationLanguageDialog
                }
            }
        }
        .padding(.horizontal, 12)
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                TranscriptionModeIconView()
                    .frame(width: 18, height: 18)

                MeetingMiniWaveform(waveformState: state.waveformState)
                    .frame(width: state.isCollapsed ? 128 : 116, height: 28)
            }

            Spacer(minLength: 12)

            if !state.isCollapsed {
                HStack(spacing: 8) {
                    Text(String(localized: "实时翻译"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { state.realtimeTranslateEnabled },
                            set: { onRealtimeTranslateToggle($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .scaleEffect(0.82)
                }

                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 1, height: 18)

                AnswerHeaderActionButton(
                    accessibilityLabel: state.isPaused ? String(localized: "Resume") : String(localized: "Pause"),
                    action: onTogglePause
                ) {
                    Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }

                AnswerHeaderActionButton(
                    accessibilityLabel: String(localized: "Detail"),
                    action: onShowDetail
                ) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }

                AnswerHeaderActionButton(
                    accessibilityLabel: String(localized: "Collapse"),
                    action: onToggleCollapse
                ) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            } else {
                AnswerHeaderActionButton(
                    accessibilityLabel: state.isPaused ? String(localized: "Resume") : String(localized: "Pause"),
                    action: onTogglePause
                ) {
                    Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }

                AnswerHeaderActionButton(
                    accessibilityLabel: String(localized: "Expand"),
                    action: onToggleCollapse
                ) {
                    Image(systemName: "arrow.down.left.and.arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }

            AnswerHeaderActionButton(
                accessibilityLabel: String(localized: "Close"),
                action: onClose
            ) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private var transcriptContent: some View {
        MeetingTranscriptScrollView(
            segments: state.segments,
            onCopySegment: onCopySegment
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 14)
    }

    private var realtimeTranslationLanguageDialog: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "选择翻译语言"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            Text(String(localized: "实时翻译会只翻译 them 的内容。"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            Picker(
                "",
                selection: $state.realtimeTranslationDraftLanguageRaw
            ) {
                ForEach(TranslationTargetLanguage.allCases) { language in
                    Text(language.title).tag(language.rawValue)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            HStack(spacing: 10) {
                Button(String(localized: "取消")) {
                    onCancelRealtimeTranslationLanguage()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )

                Button(String(localized: "开始翻译")) {
                    onConfirmRealtimeTranslationLanguage()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 20, y: 12)
    }

    private var meetingCloseConfirmationDialog: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "结束这场会议转录？"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            Text(String(localized: "取消转录不会保存历史记录；结束转录会保存历史记录并打开会议详情。"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 10) {
                Button(String(localized: "取消转录")) {
                    onConfirmCancelMeeting()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.red.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.28), lineWidth: 1)
                )

                Button(String(localized: "结束转录")) {
                    onConfirmFinishMeeting()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(16)
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 20, y: 12)
    }

    private var cornerRadius: CGFloat {
        CGFloat(min(max(overlayCardCornerRadius, 0), 40))
    }

    private var cardOpacity: Double {
        Double(min(max(overlayCardOpacity, 0), 100)) / 100.0
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.black.opacity(cardOpacity))
    }
}
