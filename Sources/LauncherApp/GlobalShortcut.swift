import AppKit
import HotKey

/// Narrow adapter: keep third-party shortcut types out of the app's action model.
final class GlobalShortcut {
    private let hotKey: HotKey
    var isRegistered: Bool { hotKey.isRegistered }
    init(modifiers: NSEvent.ModifierFlags = [.command], handler: @escaping () -> Void) {
        hotKey = HotKey(key: .space, modifiers: modifiers)
        hotKey.keyDownHandler = handler
    }
}
