import SwiftUI
import SessionMonitor

struct AttentionPreviewView: View {
    let store: SessionStore
    let sessionID: String
    let onReview: () -> Void
    let onOpen: (CodexSession) -> Void
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void
    private var fontSize: Double { store.configuration.textSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let session = store.sessions.first(where: { $0.id == sessionID }) {
                HStack {
                    Label(session.activity == .waitingForApproval ? "Approval required" : "Input required",
                          systemImage: "circle.fill")
                        .font(.system(size: fontSize - 4, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onDismiss) { Image(systemName: "xmark") }
                        .foregroundStyle(.secondary)
                        .help("Dismiss for now").accessibilityLabel("Dismiss notification")
                }
                Text(session.title).font(.system(size: fontSize - 2, weight: .medium))
                    .lineLimit(1).help(session.title)
                if let path = session.workingDirectory {
                    Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "folder")
                        .font(.system(size: fontSize - 4)).foregroundStyle(.secondary)
                        .lineLimit(1).help(path)
                }
                HStack(spacing: 14) {
                    Button("Review", action: onReview)
                    Button("Open session") { onOpen(session) }
                }
                .font(.system(size: fontSize - 3))
            }
        }
        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background).tint(.primary)
        .buttonStyle(PromptActionButtonStyle())
        .onHover(perform: onHover)
    }
}
