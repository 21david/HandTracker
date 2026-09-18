import AppKit
import Foundation

/// Suppresses the macOS system beep that fires when keyDown reaches a window with no
/// key-handling first responder (HandTrack's dashboard has none). Text fields still receive keys.
@MainActor
enum MacUnhandledKeystrokeBeepProbe {
    private static var monitor: Any?

    static func startIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let allow = Self.shouldAllowKeyDown(event)
            return allow ? event : nil
        }
    }

    /// SwiftUI `.popover` often uses a nonactivating panel: not `keyWindow`, and `NSApp.isActive`
    /// may be false — so scan the event window and every app window for a text first responder.
    private static func shouldAllowKeyDown(_ event: NSEvent) -> Bool {
        if isTextInputResponder(event.window?.firstResponder) { return true }
        for window in NSApp.windows {
            if isTextInputResponder(window.firstResponder) { return true }
        }
        return false
    }

    private static func isTextInputResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        var current: NSResponder? = responder
        while let node = current {
            if node is NSTextView || node is NSTextField || node is NSText { return true }
            if node.conforms(to: NSTextInputClient.self) { return true }
            let name = String(describing: type(of: node))
            if name.contains("Text") || name.contains("FieldEditor") || name.contains("TextField") {
                return true
            }
            current = node.nextResponder
        }
        return false
    }
}
