import AppKit

/// A menu section header (provider title) with a trailing external-link icon
/// that opens the provider's usage dashboard. AppKit's native
/// `NSMenuItem.sectionHeader` is non-interactive, so provider sections use this
/// custom view. The whole row is the click target; the icon is the affordance.
@MainActor
final class SectionHeaderView: NSView {
    private let title: String
    private let onOpen: () -> Void
    private var hovering: Bool

    private let coral = NSColor(srgbRed: 217 / 255, green: 119 / 255,
                                blue: 87 / 255, alpha: 1)
    private let inset: CGFloat = 14

    init(title: String, hover: Bool = false, onOpen: @escaping () -> Void) {
        self.title = title
        self.onOpen = onOpen
        self.hovering = hover
        super.init(frame: NSRect(x: 0, y: 0, width: AccountRowView.rowWidth, height: 24))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        // Let the menu finish closing before opening the browser.
        DispatchQueue.main.async { self.onOpen() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let titleColor = hovering ? coral : NSColor.secondaryLabelColor
        let size = title.size(withAttributes: [.font: font])
        let ty = (bounds.height - size.height) / 2
        title.draw(at: NSPoint(x: inset, y: ty),
                   withAttributes: [.font: font, .foregroundColor: titleColor])

        // External-link glyph just after the title, palette-colored so it draws
        // tinted in this custom view (a template image wouldn't pick up a color).
        let tint = hovering ? coral : NSColor.tertiaryLabelColor
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        if let icon = NSImage(systemSymbolName: "arrow.up.right",
                              accessibilityDescription: "Open usage dashboard")?
            .withSymbolConfiguration(config) {
            let iSize = icon.size
            let ix = inset + size.width + 5
            let iy = (bounds.height - iSize.height) / 2
            icon.draw(in: NSRect(x: ix, y: iy, width: iSize.width, height: iSize.height))
        }
    }
}
