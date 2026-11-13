import SwiftUI
import AppKit

struct QuitIcon: View {
    private static let image: NSImage? = {
        let url = Bundle.main.url(forResource: "quit", withExtension: "svg")
            ?? Bundle.module.url(forResource: "quit", withExtension: "svg")
        let image = url.flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "power", accessibilityDescription: "Quit Codex Watcher")
        image?.isTemplate = true
        return image
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).renderingMode(.template)
                .resizable().scaledToFit().frame(width: 16, height: 16)
                .accessibilityHidden(true)
        }
    }
}
