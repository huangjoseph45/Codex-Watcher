import SwiftUI
import AppKit
import SessionMonitor

struct AttentionBubbleView: View {
    let store: SessionStore
    let sessionID: String
    let onOpenSession: (CodexSession) -> Void
    let onDismiss: () -> Void
    var showDetails = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let session = store.sessions.first(where: { $0.id == sessionID }) {
                VStack(alignment: .leading, spacing: 7) {
                    Label(session.activity == .unknown ? "Checking request…" :
                            (session.activity == .waitingForApproval ? "Approval required" : "Input required"),
                          systemImage: "exclamationmark.bubble")
                        .fontWeight(.semibold).foregroundStyle(.orange)
                    Text(session.title).fontWeight(.semibold).lineLimit(1).help(session.title)
                    if let path = session.workingDirectory {
                        Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                            .foregroundStyle(.secondary).lineLimit(1).help(path)
                    }
                }
                .padding(16)
                Divider()
                VStack(alignment: .leading, spacing: 14) {
                        if let prompt = session.pendingPrompt, showDetails {
                            PromptForm(store: store, prompt: prompt, onDismiss: onDismiss,
                                       onOpenSession: { onOpenSession(session) }).id(prompt.id)
                        } else {
                            Text(showDetails ? (session.reviewQuestion?.text ?? session.promptNotice ?? "Open this session to review and respond to its request.")
                                 : "This request is too large to fit on screen. Open the session to review it in full.")
                                .foregroundStyle(.secondary)
                            if session.reviewQuestion != nil {
                                Text("Review the options and answer in the session.").foregroundStyle(.secondary)
                            }
                            HStack {
                                Button("Later", action: onDismiss).keyboardShortcut(.cancelAction)
                                Spacer()
                                Button("Open session") { onOpenSession(session) }
                            }
                        }
                        if let error = store.promptError, store.promptMessageID == session.pendingPrompt?.id {
                            Text(error).foregroundStyle(.orange)
                        }
                        if let error = store.navigationError {
                            Text(error).foregroundStyle(.orange)
                        }
                        if let feedback = store.promptFeedback, store.promptMessageID == session.pendingPrompt?.id {
                            Text(feedback).foregroundStyle(.secondary)
                        }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            } else {
                Text("This session is no longer active.").padding()
                Button("Close", action: onDismiss).padding()
            }
        }
        .buttonStyle(PromptActionButtonStyle())
        .font(.system(size: store.configuration.textSize - 1))
        .tint(.primary).background(.background)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PromptForm: View {
    let store: SessionStore
    let prompt: PendingPrompt
    let onDismiss: () -> Void
    let onOpenSession: () -> Void
    @State private var answers: [String: String] = [:]

    private var disabled: Bool {
        store.submittingPromptID != nil || store.submittedPromptIDs.contains(prompt.id)
            || store.error != nil || store.sessions.first(where: { $0.id == prompt.threadID })?.activity.needsAttention != true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let reason = prompt.reason, !reason.isEmpty { Text(reason).textSelection(.enabled) }
            if let command = prompt.command, !command.isEmpty {
                Text(command).font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            }
            if let path = prompt.workingDirectory {
                Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            switch prompt.kind {
            case .commandApproval, .fileApproval, .permissionsApproval:
                PermissionApprovalForm(prompt: prompt, disabled: disabled, submit: submit)
            case .userInput:
                ForEach(prompt.questions) { question in
                    VStack(alignment: .leading, spacing: 9) {
                        Text(question.header).fontWeight(.semibold)
                        Text(question.text).textSelection(.enabled)
                        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                            Button {
                                answers[question.id] = option.label
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: answers[question.id] == option.label ? "largecircle.fill.circle" : "circle")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(option.label).fontWeight(.medium)
                                        if !option.description.isEmpty {
                                            Text(option.description).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                        }
                        if question.options.isEmpty || question.allowsOther {
                            if question.isSecret {
                                SecureField("Your response", text: answerBinding(question.id))
                            } else {
                                TextField("Your response", text: answerBinding(question.id), axis: .vertical)
                                    .lineLimit(2...5)
                            }
                        }
                    }
                    .disabled(disabled)
                }
                Button("Send response") { submit(.answers(answers)) }
                    .disabled(disabled || !prompt.accepts(answers))
            case .unsupported:
                Text("This request needs its original interface. Open the session to respond.").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Later", action: onDismiss).keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("Open session", action: onOpenSession)
            }
            if store.submittingPromptID == prompt.id { ProgressView("Sending response…").controlSize(.small) }
            if store.submittedPromptIDs.contains(prompt.id) {
                Text("Response sent. Checking the session…").foregroundStyle(.secondary)
            }
        }
    }

    private func answerBinding(_ id: String) -> Binding<String> {
        Binding(get: { answers[id] ?? "" }, set: { answers[id] = $0 })
    }

    private func submit(_ resolution: PromptResolution) {
        Task { await store.resolve(prompt, with: resolution) }
    }
}

/// Show every available permission choice with its exact scope.
private struct PermissionApprovalForm: View {
    let prompt: PendingPrompt
    let disabled: Bool
    let submit: (PromptResolution) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let details = prompt.permissionDetails {
                Text(details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            if let changes = prompt.fileChanges {
                Text(changes).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } else if prompt.kind == .fileApproval {
                Text("The file changes are unavailable. Open the session to review them before allowing.")
                    .foregroundStyle(.secondary)
            }
            if prompt.approvalChoices.isEmpty {
                Text("Open the session to review this permission request.").foregroundStyle(.secondary)
            }
            ForEach(prompt.approvalChoices) { choice in
                VStack(alignment: .leading, spacing: 4) {
                    Button(choice.label) { submit(.approvalChoice(choice.id)) }.disabled(disabled)
                    if let detail = choice.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

/// Explicit neutral colors keep the fill stable when text selection makes the
/// popover key. Native prominent buttons inherit the popup's adaptive primary tint.
struct PromptActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlColor))
                    .overlay {
                        if configuration.isPressed {
                            RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.08))
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.5)
            .buttonHoverFeedback()
    }
}
