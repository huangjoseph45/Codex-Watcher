import SwiftUI

struct SoundSettingsMenu: View {
    let store: SessionStore

    var body: some View {
        Menu("Sounds") {
            Toggle("Action required", isOn: Binding(
                get: { store.actionSoundEnabled }, set: { store.setActionSoundEnabled($0) }))
            Toggle("Turn completed", isOn: Binding(
                get: { store.completionSoundEnabled }, set: { store.setCompletionSoundEnabled($0) }))
            SoundVolumeMenu(store: store)
            Divider()
            Button("Preview action sound") { store.notificationSounds.play(.actionRequired, volume: store.soundVolume) }
            Button("Preview completion sound") { store.notificationSounds.play(.turnFinished, volume: store.soundVolume) }
        }
    }
}

private struct SoundVolumeMenu: View {
    let store: SessionStore

    var body: some View {
        Menu("Volume: \(Int((store.soundVolume * 100).rounded()))%") {
            ForEach(store.configuration.soundSettings.volumeOptions.sorted(), id: \.self) { volume in
                Button {
                    store.setSoundVolume(volume)
                } label: {
                    if store.soundVolume == volume {
                        Label(volumeLabel(volume), systemImage: "checkmark")
                    } else { Text(volumeLabel(volume)) }
                }
            }
        }
    }

    private func volumeLabel(_ volume: Double) -> String {
        volume == 0 ? "Muted" : "\(Int((volume * 100).rounded()))%"
    }
}
