import SwiftUI

private let sessionDetailBottomID = "session-detail-bottom"

private func sessionMessageScrollID(_ message: SessionMessageDisplay) -> String {
    "session-message-\(message.id)"
}

private func pendingTurnScrollID(_ turn: PendingSessionTurn) -> String {
    "pending-turn-\(turn.id.uuidString)"
}

private enum SessionScrollReason {
    case sessionChanged
    case messagesLoaded
    case pendingTurnChanged
    case messagesChangedWhilePending

    var delay: DispatchTimeInterval {
        switch self {
        case .sessionChanged:
            return .milliseconds(120)
        case .messagesLoaded:
            return .milliseconds(60)
        case .pendingTurnChanged, .messagesChangedWhilePending:
            return .milliseconds(40)
        }
    }

    var followUpDelay: DispatchTimeInterval? {
        switch self {
        case .sessionChanged:
            return .milliseconds(360)
        case .messagesLoaded:
            return .milliseconds(220)
        case .pendingTurnChanged, .messagesChangedWhilePending:
            return .milliseconds(140)
        }
    }

    var animated: Bool {
        switch self {
        case .sessionChanged, .messagesLoaded:
            return false
        case .pendingTurnChanged, .messagesChangedWhilePending:
            return true
        }
    }
}

private struct SessionScrollRequest: Equatable {
    let id = UUID()
    let reason: SessionScrollReason?

    init(reason: SessionScrollReason? = nil) {
        self.reason = reason
    }

    var isPending: Bool {
        reason != nil
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var appState: AppState

    let session: SessionSummary?
    let messages: [SessionMessageDisplay]
    let errorMessage: String?
    let conversationError: String?
    let isSendingMessage: Bool
    let pendingTurn: PendingSessionTurn?
    let onResumeInTerminal: (SessionSummary) -> Void
    let onStartSession: (String, Bool) async -> Bool
    let onSendMessage: (String, Bool) async -> Bool

    @State private var showDeleteConfirmation = false
    @State private var scrollRequest = SessionScrollRequest()

    private var latestMessageScrollKey: String {
        "\(messages.count):\(messages.last?.id ?? "none")"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        scrollContent

                        Color.clear
                            .frame(height: 1)
                            .id(sessionDetailBottomID)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }
                .onChange(of: session?.id) { _, _ in
                    requestScrollToLatest(proxy, reason: .sessionChanged)
                }
                .onChange(of: latestMessageScrollKey) { _, _ in
                    guard session != nil, !messages.isEmpty else { return }
                    requestScrollToLatest(
                        proxy,
                        reason: pendingTurn == nil ? .messagesLoaded : .messagesChangedWhilePending
                    )
                }
                .onChange(of: pendingTurn?.id) { _, _ in
                    requestScrollToLatest(proxy, reason: .pendingTurnChanged)
                }
                .task(id: session?.id) {
                    requestScrollToLatest(proxy, reason: .sessionChanged)
                }
            }

            Divider()
                .opacity(0.6)

            composerDock
        }
        .alert("Delete this session?", isPresented: $showDeleteConfirmation, presenting: session) { session in
            Button("Delete", role: .destructive) {
                Task {
                    await appState.deleteSession(session)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text(L10n.string(
                "“%@” will be removed from Hermes Desktop and deleted on the remote Hermes host as well. This action cannot be undone.",
                session.resolvedTitle
            ))
        }
    }

    @ViewBuilder
    private var scrollContent: some View {
        if let session {
            SessionSummaryPanel(
                session: session,
                isDeleting: appState.isDeletingSession && appState.selectedSessionID == session.id,
                onDelete: { showDeleteConfirmation = true }
            )

            if let errorMessage {
                HermesSurfacePanel {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            transcriptContent(for: session)
        } else if let pendingTurn, pendingTurn.sessionID == nil {
            HermesSurfacePanel(
                title: "Starting Session"
            ) {
                PendingSessionTurnView(turn: pendingTurn, showPrompt: true)
                    .id(pendingTurnScrollID(pendingTurn))
            }
        } else {
            HermesSurfacePanel {
                ContentUnavailableView(
                    "Start or select a session",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Write below to begin a new Hermes conversation, or choose an existing session from the list.")
                )
                .frame(maxWidth: .infinity, minHeight: 320)
            }
        }
    }

    @ViewBuilder
    private func transcriptContent(for session: SessionSummary) -> some View {
        let matchingPendingTurn = pendingTurn?.sessionID == session.id ? pendingTurn : nil

        if messages.isEmpty && matchingPendingTurn == nil {
            HermesSurfacePanel {
                ContentUnavailableView(
                    "No transcript entries",
                    systemImage: "text.bubble",
                    description: Text("This session has no readable message rows yet.")
                )
                .frame(maxWidth: .infinity, minHeight: 280)
            }
        } else {
            HermesSurfacePanel(
                title: "Transcript",
                subtitle: "Messages are shown in the order Hermes stored them for this session."
            ) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageCard(message: message)
                            .id(sessionMessageScrollID(message))
                    }

                    if let matchingPendingTurn {
                        PendingSessionTurnView(
                            turn: matchingPendingTurn,
                            showPrompt: !messages.containsUserPrompt(matchingPendingTurn.prompt)
                        )
                        .id(pendingTurnScrollID(matchingPendingTurn))
                    }
                }
            }
        }
    }

    private var composerDock: some View {
        SessionComposerPanel(
            title: session == nil ? "New Session" : "Continue Session",
            placeholder: session == nil ? "Start a new Hermes session…" : "Write a reply to continue this session…",
            errorMessage: conversationError,
            isSending: isSendingMessage,
            onResumeInTerminal: session.map { selectedSession in
                { onResumeInTerminal(selectedSession) }
            },
            onSend: session == nil ? onStartSession : onSendMessage
        )
        .id(session?.id ?? "new-session")
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }

    private func requestScrollToLatest(_ proxy: ScrollViewProxy, reason: SessionScrollReason) {
        let request = SessionScrollRequest(reason: reason)
        scrollRequest = request

        scheduleScrollToLatest(
            proxy,
            request: request,
            reason: reason,
            delay: reason.delay,
            completesRequest: reason.followUpDelay == nil
        )

        if let followUpDelay = reason.followUpDelay {
            scheduleScrollToLatest(
                proxy,
                request: request,
                reason: reason,
                delay: followUpDelay,
                completesRequest: true
            )
        }
    }

    private func scheduleScrollToLatest(
        _ proxy: ScrollViewProxy,
        request: SessionScrollRequest,
        reason: SessionScrollReason,
        delay: DispatchTimeInterval,
        completesRequest: Bool
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard scrollRequest == request else { return }
            let target = latestScrollTarget

            if reason.animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(target.id, anchor: target.anchor)
                }
            } else {
                proxy.scrollTo(target.id, anchor: target.anchor)
            }

            guard completesRequest else { return }
            scrollRequest = SessionScrollRequest()
        }
    }

    private var latestScrollTarget: (id: String, anchor: UnitPoint) {
        if let pendingTurn,
           pendingTurn.sessionID == nil || pendingTurn.sessionID == session?.id {
            return (pendingTurnScrollID(pendingTurn), .bottom)
        }

        if let lastMessage = messages.last {
            return (sessionMessageScrollID(lastMessage), .top)
        }

        return (sessionDetailBottomID, .bottom)
    }
}

private struct SessionSummaryPanel: View {
    let session: SessionSummary
    let isDeleting: Bool
    let onDelete: () -> Void

    var body: some View {
        HermesSurfacePanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(session.resolvedTitle)
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text(session.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        if let model = session.displayModel {
                            HermesBadge(text: model, tint: .orange)
                        }

                        if let count = session.messageCount {
                            HermesBadge(text: L10n.string("%@ messages", "\(count)"), tint: .accentColor)
                        }

                        Button(action: onDelete) {
                            Group {
                                if isDeleting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "trash")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .foregroundStyle(.red)
                            .frame(minWidth: 14, minHeight: 14)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.red.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.string("Delete session"))
                        .accessibilityLabel(L10n.string("Delete session"))
                        .disabled(isDeleting)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        sessionDates
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        sessionDates
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var sessionDates: some View {
        if let startedAt = session.startedAt?.dateValue {
            HermesLabeledValue(
                label: "Started",
                value: DateFormatters.shortDateTimeFormatter().string(from: startedAt)
            )
        }

        if let lastActive = session.lastActive?.dateValue {
            HermesLabeledValue(
                label: "Last active",
                value: DateFormatters.shortDateTimeFormatter().string(from: lastActive)
            )
        }
    }
}

private struct SessionComposerPanel: View {
    let title: String
    let placeholder: String
    let errorMessage: String?
    let isSending: Bool
    let onResumeInTerminal: (() -> Void)?
    let onSend: (String, Bool) async -> Bool

    @State private var draft = ""
    @State private var autoApproveCommands = false
    @State private var isExpanded = false
    @FocusState private var isEditorFocused: Bool

    private let compactPromptHeight: CGFloat = 24
    private let compactPromptLeadingInset: CGFloat = 5
    private let expandedPromptHeight: CGFloat = 96
    private let expandedPromptHorizontalInset: CGFloat = 12
    private let expandedPromptTopInset: CGFloat = 10

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !isSending && !trimmedDraft.isEmpty
    }

    private var shouldUseExpandedEditor: Bool {
        isExpanded || draft.contains("\n") || draft.count > 96
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(Color.accentColor)

                Text(L10n.string(title))
                    .font(.headline)

                Spacer()

                if let onResumeInTerminal {
                    Button(action: onResumeInTerminal) {
                        Label(L10n.string("Resume in Terminal"), systemImage: "terminal")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isSending)
                    .help(L10n.string("Open this Hermes session in a fresh Terminal tab"))
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                HermesInsetSurface {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            composerInput
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var composerInput: some View {
        if shouldUseExpandedEditor {
            VStack(alignment: .leading, spacing: 10) {
                promptEditor(
                    height: expandedPromptHeight,
                    placeholderPadding: EdgeInsets(
                        top: expandedPromptTopInset,
                        leading: expandedPromptHorizontalInset,
                        bottom: 0,
                        trailing: expandedPromptHorizontalInset
                    ),
                    editorPadding: EdgeInsets(
                        top: expandedPromptTopInset - 5,
                        leading: expandedPromptHorizontalInset - 5,
                        bottom: 0,
                        trailing: expandedPromptHorizontalInset - 5
                    ),
                    showsEditorBackground: true
                )
                    .frame(height: 108)

                HStack {
                    Spacer(minLength: 8)
                    controlCluster
                }
            }
        } else {
            HStack(alignment: .center, spacing: 10) {
                promptEditor(
                    height: compactPromptHeight,
                    placeholderPadding: EdgeInsets(
                        top: 0,
                        leading: compactPromptLeadingInset,
                        bottom: 0,
                        trailing: 0
                    ),
                    editorPadding: EdgeInsets(
                        top: 0,
                        leading: compactPromptLeadingInset - 5,
                        bottom: 0,
                        trailing: 0
                    ),
                    showsEditorBackground: false
                )
                    .frame(minWidth: 80)

                controlCluster
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 42)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .onTapGesture {
                expandEditor()
            }
        }
    }

    private func promptEditor(
        height: CGFloat,
        placeholderPadding: EdgeInsets,
        editorPadding: EdgeInsets,
        showsEditorBackground: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if showsEditorBackground {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            }

            if draft.isEmpty {
                Text(L10n.string(placeholder))
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(placeholderPadding)
                    .frame(height: height, alignment: .topLeading)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $draft)
                .font(.body)
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .focused($isEditorFocused)
                .padding(editorPadding)
                .frame(height: height)
                .disabled(isSending)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else {
                        return .ignored
                    }

                    submit()
                    return .handled
                }
        }
        .overlay {
            if showsEditorBackground {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private var controlCluster: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $autoApproveCommands) {
                Label(L10n.string("Auto-approve commands"), systemImage: "checkmark.shield")
            }
            .toggleStyle(.checkbox)
            .disabled(isSending)
            .help(L10n.string("Runs this turn with Hermes command approval bypassed."))

            Button {
                submit()
            } label: {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "paperplane.fill")

                        Text("⌘↩")
                            .font(.caption2.monospaced().weight(.semibold))
                    }
                    .frame(minWidth: 48)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help(L10n.string("Send with Command-Return"))
            .accessibilityLabel(L10n.string("Send"))
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func submit() {
        let prompt = trimmedDraft
        guard !isSending, !prompt.isEmpty else { return }
        let shouldAutoApprove = autoApproveCommands
        autoApproveCommands = false
        isExpanded = false
        isEditorFocused = false
        draft = ""

        Task {
            let didSend = await onSend(prompt, shouldAutoApprove)
            if !didSend && draft.isEmpty {
                draft = prompt
                isExpanded = prompt.contains("\n") || prompt.count > 96
            }
        }
    }

    private func expandEditor() {
        guard !isSending else { return }
        isExpanded = true
        DispatchQueue.main.async {
            isEditorFocused = true
        }
    }
}

private struct PendingSessionTurnView: View {
    let turn: PendingSessionTurn
    let showPrompt: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showPrompt {
                PendingBubble(
                    title: "You",
                    icon: "person.crop.circle.fill",
                    content: turn.prompt,
                    tint: .green
                )
            }

            HermesInsetSurface {
                HStack(alignment: .center, spacing: 12) {
                    ProgressView()
                        .controlSize(.small)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(L10n.string("Hermes is working"))
                                .font(.subheadline.weight(.semibold))

                            if turn.autoApproveCommands {
                                HermesBadge(text: "Auto-approve", tint: .orange)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct PendingBubble: View {
    let title: String
    let icon: String
    let content: String
    let tint: Color

    var body: some View {
        HermesInsetSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)

                    Text(L10n.string(title))
                        .font(.subheadline.weight(.semibold))

                    Spacer()
                }

                Text(content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct MessageCard: View {
    let message: SessionMessageDisplay

    var body: some View {
        if message.isToolMessage {
            ToolMessageCard(message: message)
        } else {
            ConversationMessageCard(message: message)
        }
    }
}

private struct ConversationMessageCard: View {
    let message: SessionMessageDisplay
    @State private var isShowingMetadata = false

    var body: some View {
        HermesInsetSurface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    HermesBadge(
                        text: displayRole,
                        tint: roleTint,
                        isMonospaced: false
                    )

                    Spacer()

                    if let timestampText = message.timestampText {
                        Text(timestampText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let content = message.content, !content.isEmpty {
                    Text(content)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(L10n.string("No text payload"))
                        .foregroundStyle(.secondary)
                        .italic()
                }

                if !message.metadataItems.isEmpty {
                    MetadataDisclosureView(
                        items: message.metadataItems,
                        isShowingMetadata: $isShowingMetadata
                    )
                }
            }
        }
    }

    private var displayRole: String {
        message.role.displayTitle
    }

    private var roleTint: Color {
        switch message.role {
        case .assistant:
            return .blue
        case .user:
            return .green
        case .system:
            return .orange
        case .event, .custom:
            return .secondary
        }
    }
}

private struct ToolMessageCard: View {
    let message: SessionMessageDisplay
    @State private var isExpanded = false
    @State private var isShowingMetadata = false

    private var summary: SessionToolMessageSummary? {
        message.toolSummary
    }

    var body: some View {
        HermesInsetSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    HermesBadge(text: "Tool", tint: .secondary, isMonospaced: false)

                    if let summary,
                       let statusText = summary.statusText {
                        HermesBadge(text: statusText, tint: statusTint, isMonospaced: false)
                    }

                    if let sizeText = summary?.sizeText {
                        Text(sizeText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 10)

                    if let timestampText = message.timestampText {
                        Text(timestampText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10, height: 20)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(summary?.title ?? L10n.string("Tool output"))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            if let preview = summary?.preview, !preview.isEmpty {
                                Text(preview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(isExpanded ? 3 : 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(L10n.string("No output preview"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer(minLength: 10)

                        Text(L10n.string(isExpanded ? "Hide details" : "Details"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if isExpanded {
                    ToolOutputView(content: message.content, summary: summary)

                    if !message.metadataItems.isEmpty {
                        MetadataDisclosureView(
                            items: message.metadataItems,
                            isShowingMetadata: $isShowingMetadata
                        )
                    }
                }
            }
        }
    }

    private var statusTint: Color {
        switch summary?.statusKind {
        case .success:
            return .green
        case .failure:
            return .red
        case .neutral, .none:
            return .secondary
        }
    }
}

private struct ToolOutputView: View {
    let content: String?
    let summary: SessionToolMessageSummary?
    @State private var isShowingFullOutput = false

    private var visibleContent: String? {
        guard isShowingFullOutput else {
            return summary?.detailPreview
        }

        return content
    }

    private var isTruncated: Bool {
        summary?.isDetailPreviewTruncated == true && !isShowingFullOutput
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let visibleContent, !visibleContent.isEmpty {
                ScrollView {
                    Text(visibleContent)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: isShowingFullOutput ? 280 : 180)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Text(L10n.string("No text payload"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }

            if isTruncated {
                Button {
                    isShowingFullOutput = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text(L10n.string("Show full output"))
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help(L10n.string("Render the full tool output on demand"))
            }
        }
    }
}

private struct MetadataDisclosureView: View {
    let items: [SessionMetadataDisplayItem]
    @Binding var isShowingMetadata: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    isShowingMetadata.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isShowingMetadata ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)

                    Text(L10n.string("Metadata"))
                        .font(.caption.weight(.semibold))

                    Text("(\(items.count))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if isShowingMetadata {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        MetadataItemView(item: item)
                    }
                }
            }
        }
    }
}

private struct MetadataItemView: View {
    let item: SessionMetadataDisplayItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(item.value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.07))
        )
    }
}

private extension Array where Element == SessionMessageDisplay {
    func containsUserPrompt(_ prompt: String) -> Bool {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPrompt.isEmpty else { return false }

        return contains { message in
            guard message.role == .user,
                  let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return false
            }
            return content == normalizedPrompt
        }
    }
}
