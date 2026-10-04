import AppKit
import InferCore

/// Feeds key events to `PushToTalkGesture`. A local monitor only sees
/// events while Infer is the active app, which is the intended scope,
/// and needs no Accessibility permission. Events pass through unchanged.
@MainActor
final class PushToTalkMonitor {
    private var monitor: Any?
    private var gesture: PushToTalkGesture?
    private var flag: NSEvent.ModifierFlags = []
    private var onAction: ((PushToTalkGesture.Action) -> Void)?

    func install(key: PushToTalkKey, onAction: @escaping (PushToTalkGesture.Action) -> Void) {
        uninstall()
        gesture = PushToTalkGesture(key: key)
        flag = Self.modifierFlag(for: key)
        self.onAction = onAction
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            let isKeyDown = event.type == .keyDown
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            MainActor.assumeIsolated {
                self?.handle(isKeyDown: isKeyDown, keyCode: keyCode, flags: flags)
            }
            return event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        gesture = nil
        onAction = nil
    }

    private func handle(isKeyDown: Bool, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard var g = gesture else { return }
        let action = isKeyDown
            ? g.keyDown()
            : g.flagsChanged(keyCode: keyCode, keyIsDown: flags.contains(flag))
        gesture = g
        if let action { onAction?(action) }
    }

    private static func modifierFlag(for key: PushToTalkKey) -> NSEvent.ModifierFlags {
        switch key {
        case .fn: return .function
        case .rightOption: return .option
        case .rightCommand: return .command
        }
    }
}
