import SwiftUI
import AppKit

struct SettingsMenu: NSViewRepresentable {
    let store: SessionStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> SettingsButton {
        let button = SettingsButton()
        button.title = ""
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.setButtonType(.momentaryPushIn)
        button.contentTintColor = .systemOrange
        button.target = context.coordinator
        button.action = #selector(Coordinator.openMenu(_:))
        button.toolTip = "Settings"
        button.setAccessibilityLabel("Settings")
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        return button
    }

    func updateNSView(_ button: SettingsButton, context: Context) {
        context.coordinator.store = store
        let size = store.configuration.textSize + 4
        let url = Bundle.main.url(forResource: "settings", withExtension: "svg")
            ?? Bundle.module.url(forResource: "settings", withExtension: "svg")
        button.image = url.flatMap { NSImage(contentsOf: $0) }
        button.image?.isTemplate = true
        button.image?.size = NSSize(width: size, height: size)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SettingsButton, context: Context) -> CGSize? {
        let size = store.configuration.textSize + 8
        return CGSize(width: size, height: size)
    }

    @MainActor
    final class Coordinator: NSObject {
        var store: SessionStore
        init(store: SessionStore) { self.store = store }

        @objc func openMenu(_ button: NSButton) {
            let menu = NSMenu(title: "Settings")
            menu.autoenablesItems = false
            let refresh = NSMenu(title: "Refresh interval")
            for seconds in store.configuration.refreshOptions.sorted() {
                refresh.addItem(ActionItem(seconds == 1 ? "1 second" : "\(seconds.formatted()) seconds",
                    selected: store.refreshIntervalSeconds == seconds) { [store] in store.setRefreshInterval(seconds) })
            }
            refresh.addItem(.separator())
            refresh.addItem(ActionItem("Use config default (\(store.configuration.refreshIntervalSeconds.formatted())s)") { [store] in
                store.resetRefreshInterval()
            })
            menu.addItem(submenu("Refresh interval: \(store.refreshIntervalSeconds.formatted())s", refresh))

            let sounds = NSMenu(title: "Sounds")
            sounds.addItem(ActionItem("Action required", selected: store.actionSoundEnabled) { [store] in
                store.setActionSoundEnabled(!store.actionSoundEnabled)
            })
            sounds.addItem(ActionItem("Turn completed", selected: store.completionSoundEnabled) { [store] in
                store.setCompletionSoundEnabled(!store.completionSoundEnabled)
            })
            let volumeMenu = NSMenu(title: "Volume")
            for volume in store.configuration.soundSettings.volumeOptions.sorted() {
                volumeMenu.addItem(ActionItem(volume == 0 ? "Muted" : "\(Int((volume * 100).rounded()))%",
                    selected: store.soundVolume == volume) { [store] in store.setSoundVolume(volume) })
            }
            sounds.addItem(submenu("Volume: \(Int((store.soundVolume * 100).rounded()))%", volumeMenu))
            sounds.addItem(.separator())
            sounds.addItem(ActionItem("Preview action sound") { [store] in
                store.notificationSounds.play(.actionRequired, volume: store.soundVolume)
            })
            sounds.addItem(ActionItem("Preview completion sound") { [store] in
                store.notificationSounds.play(.turnFinished, volume: store.soundVolume)
            })
            menu.addItem(submenu("Sounds", sounds))
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
        }

        private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            return item
        }
    }
}

@MainActor
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, selected: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        state = selected ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("Settings menus are created programmatically.") }
    @objc private func invoke() { handler() }
}

final class SettingsButton: NSButton {
    private var hoverArea: NSTrackingArea?
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        if isEnabled { layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.09).cgColor }
    }
    override func mouseExited(with event: NSEvent) { layer?.backgroundColor = nil }
}
