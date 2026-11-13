import AppKit

@MainActor
final class NotificationSounds {
    enum Cue: String { case actionRequired = "action-required", turnFinished = "turn-finished" }
    private var sounds: [Cue: NSSound] = [:]

    func play(_ cue: Cue, volume: Double) {
        guard volume > 0 else { return }
        if sounds[cue] == nil {
            let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "wav")
                ?? Bundle.module.url(forResource: cue.rawValue, withExtension: "wav")
            sounds[cue] = url.flatMap { NSSound(contentsOf: $0, byReference: false) }
        }
        guard let sound = sounds[cue] else { return }
        if sound.isPlaying { sound.stop() }
        sound.volume = Float(min(max(volume, 0), 1))
        sound.play()
    }
}
