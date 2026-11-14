import SwiftUI
import AppKit

private struct ButtonHoverFeedback: ViewModifier {
    let highlightPadding: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var cursorPushed = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.orange.opacity(hovering && isEnabled ? 0.09 : 0))
                    .padding(-highlightPadding)
                    .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering && isEnabled)
            .onHover { inside in
                hovering = inside
                updateCursor(inside && isEnabled)
            }
            .onContinuousHover { phase in
                if case .active = phase, isEnabled { NSCursor.pointingHand.set() }
            }
            .onChange(of: isEnabled) { _, enabled in updateCursor(hovering && enabled) }
            .onDisappear { updateCursor(false) }
    }

    private func updateCursor(_ active: Bool) {
        if active && !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        } else if !active && cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

extension View {
    func buttonHoverFeedback(highlightPadding: CGFloat = 0) -> some View {
        modifier(ButtonHoverFeedback(highlightPadding: highlightPadding))
    }
}
