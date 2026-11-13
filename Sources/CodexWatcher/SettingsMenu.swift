import SwiftUI

struct SettingsMenu: View {
    let store: SessionStore

    var body: some View {
        Menu {
            Menu("Refresh interval: \(store.refreshIntervalSeconds.formatted())s") {
                ForEach(store.configuration.refreshOptions.sorted(), id: \.self) { seconds in
                    Button {
                        store.setRefreshInterval(seconds)
                    } label: {
                        if store.refreshIntervalSeconds == seconds {
                            Label(intervalLabel(seconds), systemImage: "checkmark")
                        } else {
                            Text(intervalLabel(seconds))
                        }
                    }
                }
                Divider()
                Button("Use config default (\(store.configuration.refreshIntervalSeconds.formatted())s)") {
                    store.resetRefreshInterval()
                }
            }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Settings").accessibilityLabel("Settings")
    }

    private func intervalLabel(_ seconds: Double) -> String {
        seconds == 1 ? "1 second" : "\(seconds.formatted()) seconds"
    }
}
