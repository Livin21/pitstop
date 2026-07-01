import AppKit

/// A small modal window for the Claude code-paste fallback: shows instructions,
/// a text field, and Submit/Cancel. Returns the pasted string or nil.
@MainActor
final class LoginPasteWindowController {
    private var window: NSWindow?
    private var field: NSTextField?
    private var continuation: CheckedContinuation<String?, Never>?

    func prompt() async -> String? {
        await withCheckedContinuation { cont in
            self.continuation = cont
            show()
        }
    }

    private func show() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Finish Claude sign-in"
        let label = NSTextField(wrappingLabelWithString:
            "Your browser is showing a sign-in code. Copy it and paste it here.")
        label.frame = NSRect(x: 20, y: 96, width: 380, height: 40)
        let field = NSTextField(frame: NSRect(x: 20, y: 60, width: 380, height: 24))
        field.placeholderString = "Paste code here"
        let submit = NSButton(title: "Sign In", target: self, action: #selector(submit(_:)))
        submit.frame = NSRect(x: 300, y: 16, width: 100, height: 32)
        submit.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.frame = NSRect(x: 200, y: 16, width: 100, height: 32)
        w.contentView?.addSubview(label)
        w.contentView?.addSubview(field)
        w.contentView?.addSubview(submit)
        w.contentView?.addSubview(cancel)
        w.center()
        self.window = w
        self.field = field
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func submit(_ sender: Any?) {
        finish(field?.stringValue)
    }

    @objc private func cancel(_ sender: Any?) {
        finish(nil)
    }

    private func finish(_ value: String?) {
        window?.orderOut(nil)
        window = nil; field = nil
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        continuation?.resume(returning: (trimmed?.isEmpty ?? true) ? nil : trimmed)
        continuation = nil
    }
}
