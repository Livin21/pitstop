import AppKit

/// A rich menu row for one account: email + plan chip on the title line,
/// then a compact colored usage bar per rate-limit window. Inactive accounts
/// highlight on hover (chip flips to a coral "Switch") and switch on click.
@MainActor
final class AccountRowView: NSView {
    struct BarRow {
        let label: String          // "5h" / "7d"
        let utilization: Double?   // nil = unknown
        let resetText: String
    }

    struct Model {
        var email: String
        var planLabel: String
        var isActive: Bool
        var bars: [BarRow]
        var modelsLine: String?    // "Opus wk 12% · Sonnet wk 10%"
        var statusLine: String?    // error / stale / loading info
        var onSwitch: (() -> Void)?  // nil = active (not clickable)
    }

    static let rowWidth: CGFloat = 408

    private var model: Model
    private var hovering: Bool

    private let coral = NSColor(srgbRed: 217 / 255, green: 119 / 255,
                                blue: 87 / 255, alpha: 1)

    private let contentX: CGFloat = 32
    private let barX: CGFloat = 58
    private let barWidth: CGFloat = 126
    private let pctRightEdge: CGFloat = 230
    private let resetX: CGFloat = 240

    static func height(for model: Model) -> CGFloat {
        var height: CGFloat = 29 + CGFloat(model.bars.count) * 16 + 6
        if model.modelsLine != nil { height += 15 }
        if model.statusLine != nil { height += 15 }
        return height
    }

    init(model: Model, hover: Bool = false) {
        self.model = model
        self.hovering = hover
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth,
                                 height: Self.height(for: model)))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Refresh the row's data in place (keeps hover state, so the open menu
    /// doesn't flicker on periodic refresh). Fails when the new model needs
    /// a different row height — the caller falls back to a full rebuild.
    @discardableResult
    func apply(_ new: Model) -> Bool {
        guard Self.height(for: new) == frame.height else { return false }
        model = new
        needsDisplay = true
        return true
    }

    override var isFlipped: Bool { true }

    // MARK: - Hover & click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard model.onSwitch != nil else { return }
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let onSwitch = model.onSwitch else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        // Let the menu finish closing before mutating state / notifying.
        DispatchQueue.main.async { onSwitch() }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if hovering, model.onSwitch != nil {
            let r = NSRect(x: 6, y: 1, width: bounds.width - 12, height: bounds.height - 2)
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }

        var y: CGFloat = 8

        // Active marker
        if model.isActive {
            coral.setFill()
            NSBezierPath(ovalIn: NSRect(x: 16, y: y + 4, width: 9, height: 9)).fill()
        }

        // Plan chip (flips to a coral "Switch" pill on hover)
        let chipFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let switching = hovering && model.onSwitch != nil
        let chipText = switching ? "Switch" : model.planLabel
        var emailMaxX = bounds.width - 12
        if !chipText.isEmpty {
            let textSize = chipText.size(withAttributes: [.font: chipFont])
            let chip = NSRect(x: bounds.width - 12 - textSize.width - 12,
                              y: y, width: textSize.width + 12, height: 16)
            (switching ? coral : NSColor.labelColor.withAlphaComponent(0.08)).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 8, yRadius: 8).fill()
            chipText.draw(at: NSPoint(x: chip.minX + 6, y: chip.minY + 1.5),
                          withAttributes: [
                              .font: chipFont,
                              .foregroundColor: switching ? NSColor.white : .secondaryLabelColor,
                          ])
            emailMaxX = chip.minX - 8
        }

        // Email (truncated to leave room for the chip)
        let emailStyle = NSMutableParagraphStyle()
        emailStyle.lineBreakMode = .byTruncatingTail
        model.email.draw(
            in: NSRect(x: contentX, y: y, width: emailMaxX - contentX, height: 17),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: model.isActive ? .semibold : .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: emailStyle,
            ])

        y += 21

        // Usage bars
        for bar in model.bars {
            let labelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
            let labelSize = bar.label.size(withAttributes: [.font: labelFont])
            bar.label.draw(at: NSPoint(x: barX - 6 - labelSize.width, y: y + 1),
                           withAttributes: [.font: labelFont,
                                            .foregroundColor: NSColor.secondaryLabelColor])

            let trackRect = NSRect(x: barX, y: y + 4.5, width: barWidth, height: 5)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: trackRect, xRadius: 2.5, yRadius: 2.5).fill()

            var pctColor = NSColor.labelColor
            if let pct = bar.utilization {
                let fillColor: NSColor = pct >= 90 ? .systemRed
                    : (pct >= 70 ? .systemOrange : .systemGreen)
                let w = max(barWidth * min(pct, 100) / 100, pct > 0 ? 4 : 0)
                if w > 0 {
                    let fill = NSRect(x: barX, y: y + 4.5, width: w, height: 5)
                    fillColor.setFill()
                    NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
                }
                if pct >= 70 { pctColor = fillColor }
            }

            let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            let pctText = Format.percent(bar.utilization)
            let pctSize = pctText.size(withAttributes: [.font: pctFont])
            pctText.draw(at: NSPoint(x: pctRightEdge - pctSize.width, y: y),
                         withAttributes: [.font: pctFont, .foregroundColor: pctColor])

            bar.resetText.draw(at: NSPoint(x: resetX, y: y + 0.5),
                               withAttributes: [
                                   .font: NSFont.systemFont(ofSize: 10.5),
                                   .foregroundColor: NSColor.secondaryLabelColor,
                               ])
            y += 16
        }

        // Per-model / extra-usage line
        if let line = model.modelsLine {
            line.draw(at: NSPoint(x: barX, y: y + 1),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 10.5),
                                       .foregroundColor: NSColor.secondaryLabelColor])
            y += 15
        }

        // Error / stale / loading line
        if let status = model.statusLine {
            status.draw(at: NSPoint(x: barX, y: y + 1),
                        withAttributes: [.font: NSFont.systemFont(ofSize: 10.5),
                                         .foregroundColor: NSColor.systemOrange])
        }
    }
}
