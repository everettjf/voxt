import SwiftUI

struct MeetingDetailSummarySidebar: View {
    @ObservedObject var viewModel: MeetingDetailViewModel

    var body: some View {
        VStack(spacing: 12) {
            summaryHeader
            summaryBodyPane
            summaryComposerPane
        }
    }

    private var summaryHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Meeting Summary"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(
                    viewModel.summaryState == .loading
                        ? AppLocalization.localizedString("Generating meeting summary…")
                        : viewModel.summary != nil
                        ? AppLocalization.localizedString("Saved summary")
                        : AppLocalization.localizedString("Generated after the detail view loads")
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(String(localized: "Settings")) {
                viewModel.presentSummarySettings()
            }
            .buttonStyle(MeetingToolbarButtonStyle())
        }
    }

    private var summaryBodyPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let summary = viewModel.summary {
                    if viewModel.summaryState == .loading {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)

                            Text(String(localized: "Generating meeting summary…"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.accentColor.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 1)
                        )
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(summary.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(summary.generatedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if !summary.body.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(String(localized: "Summary"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ForEach(summaryParagraphs(summary.body), id: \.self) { paragraph in
                                Text(paragraph)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.primary.opacity(0.92))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    if !summary.todoItems.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(String(localized: "TODO"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ForEach(Array(summary.todoItems.enumerated()), id: \.offset) { index, item in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(String(index + 1))
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18, height: 18)
                                        .background(
                                            Circle()
                                                .fill(Color.black.opacity(0.06))
                                        )

                                    Text(item)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary.opacity(0.92))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }

                    if !viewModel.summaryChatMessages.isEmpty || viewModel.isSummaryChatLoading || viewModel.summaryChatErrorMessage != nil {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(String(localized: "Follow-up"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            ForEach(viewModel.summaryChatMessages) { message in
                                SummaryChatMessageRow(message: message)
                            }

                            if viewModel.isSummaryChatLoading {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)

                                    Text(String(localized: "Thinking…"))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            if let errorMessage = viewModel.summaryChatErrorMessage,
                               !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(errorMessage)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.red.opacity(0.9))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                } else {
                    summaryStateView
                }
            }
            .padding(16)
        }
        .background(panelBackground(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var summaryStateView: some View {
        switch viewModel.summaryState {
        case .loading:
            VStack(alignment: .leading, spacing: 14) {
                ProgressView()
                    .controlSize(.small)

                Text(String(localized: "Generating meeting summary…"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(viewModel.summaryProviderMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)

        case .unavailable(let message):
            summaryEmptyState(
                icon: "sparkles",
                title: String(localized: "Summary Unavailable"),
                message: message
            )

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                summaryEmptyState(
                    icon: "exclamationmark.triangle",
                    title: String(localized: "Summary Failed"),
                    message: message
                )

                if viewModel.canRegenerateSummary {
                    Button(String(localized: "Try Again")) {
                        viewModel.regenerateSummary()
                    }
                    .buttonStyle(MeetingPillButtonStyle())
                }
            }

        case .idle:
            if viewModel.mode == .live {
                summaryEmptyState(
                    icon: "clock.arrow.circlepath",
                    title: String(localized: "Waiting For Saved Record"),
                    message: AppLocalization.localizedString("Summary generation starts after this meeting is saved to history.")
                )
            } else if !viewModel.summaryAutoGenerate {
                summaryEmptyState(
                    icon: "sparkles",
                    title: String(localized: "Auto Summary Disabled"),
                    message: AppLocalization.localizedString("Enable automatic summary generation or use the settings dialog to regenerate manually.")
                )
            } else {
                summaryEmptyState(
                    icon: "doc.text.magnifyingglass",
                    title: String(localized: "No Summary Yet"),
                    message: AppLocalization.localizedString("Open the settings dialog to trigger a manual summary generation.")
                )
            }
        }
    }

    private func summaryEmptyState(icon: String, title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
    }

    private var summaryComposerPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Follow-up Input"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                TextField(String(localized: "Ask a follow-up about this meeting"), text: $viewModel.summaryChatDraft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                    )
                    .disabled(viewModel.mode != .history || viewModel.summary == nil || !viewModel.hasSummaryModelOptions || viewModel.segments.isEmpty || viewModel.isSummaryChatLoading)
                    .onSubmit {
                        viewModel.sendSummaryChat()
                    }

                MeetingDetailFollowUpSendButton(
                    action: { viewModel.sendSummaryChat() },
                    isDisabled: !viewModel.canSendSummaryChat
                )
            }

        }
        .padding(14)
        .background(panelBackground(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private func summaryParagraphs(_ body: String) -> [String] {
        body
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func panelBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.74))
    }
}

struct MeetingDetailSummarySettingsDialog: View {
    @ObservedObject var viewModel: MeetingDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Summary Settings"))
                        .font(.system(size: 17, weight: .semibold))

                    Text(viewModel.summaryProviderMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(String(localized: "Close")) {
                    viewModel.isSummarySettingsPresented = false
                }
                .buttonStyle(MeetingPillButtonStyle())
            }

            Toggle(
                String(localized: "Allow Auto Summary"),
                isOn: Binding(
                    get: { viewModel.summaryAutoGenerate },
                    set: { viewModel.setSummaryAutoGenerate($0) }
                )
            )
            .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Summary Model"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                if viewModel.hasSummaryModelOptions {
                    Picker(
                        String(localized: "Summary Model"),
                        selection: Binding(
                            get: { viewModel.resolvedSummaryModelSelectionID },
                            set: { viewModel.setSummaryModelSelectionID($0) }
                        )
                    ) {
                        ForEach(viewModel.summaryModelOptions) { option in
                            Text("\(option.title) · \(option.subtitle)").tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                } else {
                    Text(String(localized: "No summary model is available right now."))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    Text(String(localized: "Summary Prompt"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Button(String(localized: "Reset")) {
                        viewModel.resetSummaryPromptTemplate()
                    }
                    .buttonStyle(MeetingPillButtonStyle())
                }

                TextEditor(
                    text: Binding(
                        get: { viewModel.summaryPromptTemplate },
                        set: { viewModel.setSummaryPromptTemplate($0) }
                    )
                )
                .font(.system(size: 12, weight: .medium))
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 140)
                .background(panelBackground(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.06), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text(String(localized: "Available variables: {{USER_MAIN_LANGUAGE}}, {{MEETING_RECORD}}"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(String(localized: "Expected result: return valid JSON with meeting_summary.title, meeting_summary.content, and todo_list. Use \\n for line breaks inside content."))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)

                Text(String(localized: "Add custom summary instructions, tone constraints, or output emphasis here."))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Spacer(minLength: 8)

                Button(String(localized: "Regenerate Summary")) {
                    viewModel.isSummarySettingsPresented = false
                    viewModel.regenerateSummary()
                }
                .buttonStyle(MeetingPrimaryButtonStyle())
                .disabled(!viewModel.canRegenerateSummary || !viewModel.hasSummaryModelOptions)
            }
        }
        .padding(20)
        .frame(width: 460)
        .frame(maxHeight: 620)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }

    private func panelBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.74))
    }
}

struct SummaryChatMessageRow: View {
    let message: MeetingSummaryChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? String(localized: "You") : String(localized: "Assistant"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(message.content)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.94))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(message.role == .user ? Color.accentColor.opacity(0.08) : Color.black.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    message.role == .user ? Color.accentColor.opacity(0.18) : Color.black.opacity(0.05),
                    lineWidth: 1
                )
        )
    }
}
