import SwiftUI
import AppKit

struct ScoutIcon: View {
    static let image: NSImage? = {
        let url = Bundle.main.url(forResource: "scout", withExtension: "svg")
            ?? Bundle.module.url(forResource: "scout", withExtension: "svg")
        let image = url.flatMap { NSImage(contentsOf: $0) }
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        return image
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
        }
    }
}
