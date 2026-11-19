import SwiftUI

struct SettingsView: View {
    let store: SessionStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Popups") {
                    Toggle("Show automatic popups", isOn: Binding(
                        get: { store.popupsEnabled }, set: { store.setPopupsEnabled($0) }))
                    VStack(alignment: .leading, spacing: 14) {
                        preference("Permission requests", detail: "Commands, file changes, and access approvals.",
                            value: store.approvalPopupsEnabled, set: { store.setApprovalPopupsEnabled($0) })
                        preference("Questions that pause Codex", detail: "Questions Codex needs answered before continuing.",
                            value: store.questionPopupsEnabled, set: { store.setQuestionPopupsEnabled($0) })
                        preference("Questions while Codex works", detail: "Questions to review while Codex continues working.",
                            value: store.backgroundQuestionPopupsEnabled, set: { store.setBackgroundQuestionPopupsEnabled($0) })
                    }
                    .disabled(!store.popupsEnabled)
                    Text("Pending requests are always available in Review requests. Popup choices do not affect sounds.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("Sounds") {
                    Toggle("Action required", isOn: Binding(
                        get: { store.actionSoundEnabled }, set: { store.setActionSoundEnabled($0) }))
                    Toggle("Turn completed", isOn: Binding(
                        get: { store.completionSoundEnabled }, set: { store.setCompletionSoundEnabled($0) }))
                    Picker("Volume", selection: Binding(get: { store.soundVolume }, set: { store.setSoundVolume($0) })) {
                        ForEach(store.configuration.soundSettings.volumeOptions.sorted(), id: \.self) { volume in
                            Text(volume == 0 ? "Muted" : "\(Int((volume * 100).rounded()))%").tag(volume)
                        }
                    }
                    HStack {
                        Button("Preview action") {
                            store.notificationSounds.play(.actionRequired, volume: store.soundVolume)
                        }
                        Button("Preview completion") {
                            store.notificationSounds.play(.turnFinished, volume: store.soundVolume)
                        }
                    }
                    .controlSize(.small)
                }

                section("Refresh") {
                    Picker("Interval", selection: Binding(get: { store.refreshIntervalSeconds }, set: { store.setRefreshInterval($0) })) {
                        ForEach(Array(Set(store.configuration.refreshOptions + [store.refreshIntervalSeconds])).sorted(), id: \.self) { seconds in
                            Text(seconds == 1 ? "1 second" : "\(seconds.formatted()) seconds").tag(seconds)
                        }
                    }
                    Button("Use config default (\(store.configuration.refreshIntervalSeconds.formatted())s)") {
                        store.resetRefreshInterval()
                    }
                    .controlSize(.small)
                }

                section("Codex home") {
                    Text(store.home.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Choose folder…") { store.chooseHome() }.disabled(store.refreshing)
                }
                if let warning = store.configurationWarning {
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .toggleStyle(.switch)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func preference(_ title: String, detail: String, value: Bool, set: @escaping @MainActor @Sendable (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { value }, set: { set($0) })) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
