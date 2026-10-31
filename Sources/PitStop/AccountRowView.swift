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
        var note: String? = nil    // "No limit" — drawn instead of a bar and %
    }

    struct Model {
        var email: String
        var planLabel: String
        var isActive: Bool
        var sourceBadge: String? = nil  // e.g. "Desktop" — a quiet source tag
        var bars: [BarRow]
        var barsDimmed = false     // last-known (gated) data — render muted
        var modelsLine: String?    // "Extra 4%"
        var projectionLine: String? = nil  // "↗ on pace to hit limit ~3:40 PM"
        var statusLine: String?    // error / stale / loading info
        var statusIsInfo: Bool = false  // muted (neutral) vs orange (warning)
        var onSwitch: (() -> Void)?  // nil = active (not clickable)
        var onLogin: (() -> Void)?   // non-nil = show a coral "Login" pill; click re-authenticates
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
        if model.projectionLine != nil { height += 15 }
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // NSTrackingArea retains its owner, so view → area → view is a cycle;
        // drop the areas when the view leaves the window so rows discarded by
        // buildMenu() can deallocate. AppKit re-calls updateTrackingAreas if
        // the view is ever attached again.
        if window == nil { trackingAreas.forEach(removeTrackingArea) }
    }

    override func mouseEntered(with event: NSEvent) {
        guard model.onSwitch != nil || model.onLogin != nil else { return }
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let action = model.onLogin ?? model.onSwitch
        guard let action else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        // Let the menu finish closing before mutating state / notifying.
        DispatchQueue.main.async { action() }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if (hovering && model.onSwitch != nil) || model.onLogin != nil {
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

        // Plan chip → coral "Switch" on hover, or always-coral "Login" when the
        // row's token was rejected.
        let chipFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let isLogin = model.onLogin != nil
        let switching = isLogin || (hovering && model.onSwitch != nil)
        let chipText = isLogin ? "Login" : (switching ? "Switch" : model.planLabel)
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

        // Source tag (e.g. "Desktop"), an outlined chip left of the plan chip.
        if let badge = model.sourceBadge {
            let badgeFont = NSFont.systemFont(ofSize: 9.5, weight: .medium)
            let textSize = badge.size(withAttributes: [.font: badgeFont])
            let chip = NSRect(x: emailMaxX - textSize.width - 12, y: y,
                              width: textSize.width + 12, height: 16)
            let path = NSBezierPath(roundedRect: chip, xRadius: 8, yRadius: 8)
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 1
            path.stroke()
            badge.draw(at: NSPoint(x: chip.minX + 6, y: chip.minY + 2),
                       withAttributes: [.font: badgeFont,
                                        .foregroundColor: NSColor.tertiaryLabelColor])
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

        // Per-row label gutter: labels right-align into the space left of the
        // bars, and a row whose labels outgrow the default gutter (Gemini
        // model names) pushes its bars right instead of spilling into the
        // leading margin. The bars' right edge stays fixed so the % and reset
        // columns still line up across rows.
        let labelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let maxLabelWidth = model.bars
            .map { $0.label.size(withAttributes: [.font: labelFont]).width }
            .max() ?? 0
        let rowBarX = max(barX, contentX + maxLabelWidth + 6)
        let rowBarWidth = barX + barWidth - rowBarX

        // Usage bars
        for bar in model.bars {
            let labelSize = bar.label.size(withAttributes: [.font: labelFont])
            bar.label.draw(at: NSPoint(x: rowBarX - 6 - labelSize.width, y: y + 1),
                           withAttributes: [.font: labelFont,
                                            .foregroundColor: NSColor.secondaryLabelColor])

            // A window that doesn't apply ("No limit"): no track, no number —
            // an empty bar would read as 0% used.
            if let note = bar.note {
                let noteFont = NSFont.systemFont(ofSize: 11)
                let noteSize = note.size(withAttributes: [.font: noteFont])
                note.draw(at: NSPoint(x: pctRightEdge - noteSize.width, y: y),
                          withAttributes: [
                              .font: noteFont,
                              .foregroundColor: model.barsDimmed
                                  ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
                          ])
                y += 16
                continue
            }

            let trackRect = NSRect(x: rowBarX, y: y + 4.5, width: rowBarWidth, height: 5)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: trackRect, xRadius: 2.5, yRadius: 2.5).fill()

            var pctColor = NSColor.labelColor
            if let pct = bar.utilization {
                // Threshold on the rounded value — the same number the text
                // shows — so a displayed "90%" is never un-red.
                let rounded = pct.rounded()
                let fillColor: NSColor = rounded >= 90 ? .systemRed
                    : (rounded >= 70 ? .systemOrange : .systemGreen)
                let w = max(rowBarWidth * min(pct, 100) / 100, pct > 0 ? 4 : 0)
                if w > 0 {
                    let fill = NSRect(x: rowBarX, y: y + 4.5, width: w, height: 5)
                    (model.barsDimmed ? fillColor.withAlphaComponent(0.45) : fillColor).setFill()
                    NSBezierPath(roundedRect: fill, xRadius: 2.5, yRadius: 2.5).fill()
                }
                if rounded >= 70 { pctColor = fillColor }
            }
            if model.barsDimmed { pctColor = .tertiaryLabelColor }

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

        // Time-to-limit projection — coral accent, a soft "trending up" heads-up.
        if let proj = model.projectionLine {
            proj.draw(at: NSPoint(x: barX, y: y + 1),
                      withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                                       .foregroundColor: coral])
            y += 15
        }

        // Error / stale / loading line — orange for warnings, muted for
        // neutral info (e.g. the live Codex account waiting on its own refresh).
        if let status = model.statusLine {
            status.draw(at: NSPoint(x: barX, y: y + 1),
                        withAttributes: [
                            .font: NSFont.systemFont(ofSize: 10.5),
                            .foregroundColor: model.statusIsInfo
                                ? NSColor.secondaryLabelColor : NSColor.systemOrange,
                        ])
        }
    }
}
