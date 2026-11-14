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
            SoundSettingsMenu(store: store)
        } label: {
            Image(systemName: "gearshape")
                .resizable()
                .scaledToFit()
                .frame(width: store.configuration.textSize + 4, height: store.configuration.textSize + 4)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.regular).fixedSize()
        .help("Settings").accessibilityLabel("Settings")
    }

    private func intervalLabel(_ seconds: Double) -> String {
        seconds == 1 ? "1 second" : "\(seconds.formatted()) seconds"
    }

}
