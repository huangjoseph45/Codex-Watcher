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

    // Give the status bar a concrete bitmap template. SVG-backed NSImages can
    // redraw inconsistently as AppKit changes the button's highlighted state.
    static let menuBarImage: NSImage? = {
        guard let source = image,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        source.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size = NSSize(width: 18, height: 18)
        let result = NSImage(size: bitmap.size)
        result.addRepresentation(bitmap)
        result.isTemplate = true
        return result
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
        }
    }
}
