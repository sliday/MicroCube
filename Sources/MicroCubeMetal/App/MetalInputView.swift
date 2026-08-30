import AppKit
import CoreGraphics
import MetalKit

final class MetalInputView: MTKView {
    private enum KeyCode {
        static let a: UInt16 = 0
        static let s: UInt16 = 1
        static let d: UInt16 = 2
        static let q: UInt16 = 12
        static let w: UInt16 = 13
        static let e: UInt16 = 14
        static let returnKey: UInt16 = 36
        static let space: UInt16 = 49

        static let movement = [w, s, a, d, q, e]
    }

    let input: InputState
    var onRenderAction: ((RenderAction) -> Bool)?
    var onCaptureChanged: ((Bool) -> Void)?
    var onUserInteraction: (() -> Bool)?

    private(set) var isMouseCaptured = false
    private var userInteractionNotificationArmed = false

    init(frame: NSRect, device: MTLDevice, input: InputState) {
        self.input = input
        super.init(frame: frame, device: device)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: nil
        )

        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    override func mouseDown(with event: NSEvent) {
        notifyUserInteraction()
        window?.makeFirstResponder(self)
        captureMouse()
    }

    override func rightMouseDown(with event: NSEvent) {
        notifyUserInteraction()
        window?.makeFirstResponder(self)
        captureMouse()
    }

    override func otherMouseDown(with event: NSEvent) {
        notifyUserInteraction()
        window?.makeFirstResponder(self)
        captureMouse()
    }

    override func mouseMoved(with event: NSEvent) {
        notifyUserInteraction()
        recordMouseDelta(event)
    }

    override func mouseDragged(with event: NSEvent) {
        notifyUserInteraction()
        recordMouseDelta(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        notifyUserInteraction()
        recordMouseDelta(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        notifyUserInteraction()
        recordMouseDelta(event)
    }

    override func scrollWheel(with event: NSEvent) {
        notifyUserInteraction()
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleRendererShortcut(event) {
            return
        }
        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.space:
            notifyUserInteraction()
            if !isMouseCaptured && !event.isARepeat {
                captureMouse()
            }
        case KeyCode.w, KeyCode.s, KeyCode.a, KeyCode.d, KeyCode.q, KeyCode.e:
            notifyUserInteraction()
            input.setKey(event.keyCode, down: true)
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        switch event.keyCode {
        case KeyCode.w, KeyCode.s, KeyCode.a, KeyCode.d, KeyCode.q, KeyCode.e:
            input.setKey(event.keyCode, down: false)
        default:
            super.keyUp(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        notifyUserInteraction()
        input.setSpeedBoost(event.modifierFlags.contains(.shift))
    }

    func handleRendererShortcut(_ event: NSEvent) -> Bool {
        guard !event.isARepeat,
              let action = RenderShortcut.action(
                keyCode: event.keyCode,
                modifiers: RenderShortcutModifiers(event.modifierFlags)
              ) else {
            return false
        }
        notifyUserInteraction()
        let handled = onRenderAction?(action) ?? false
        if action == .escape && !handled {
            releaseMouse()
        }
        return true
    }

    func captureMouse() {
        guard !isMouseCaptured else { return }
        isMouseCaptured = true
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
        onCaptureChanged?(true)
    }

    func releaseMouse() {
        guard isMouseCaptured else {
            clearInput()
            return
        }

        isMouseCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        clearInput()
        onCaptureChanged?(false)
    }

    func armUserInteractionNotification() {
        userInteractionNotificationArmed = true
    }

    func disarmUserInteractionNotification() {
        userInteractionNotificationArmed = false
    }

    private func recordMouseDelta(_ event: NSEvent) {
        guard isMouseCaptured else { return }
        input.addMouseDelta(x: Float(event.deltaX), y: Float(event.deltaY))
    }

    private func clearInput() {
        for keyCode in KeyCode.movement {
            input.setKey(keyCode, down: false)
        }
        input.setSpeedBoost(false)
    }

    private func notifyUserInteraction() {
        guard userInteractionNotificationArmed, onUserInteraction?() == true else { return }
        userInteractionNotificationArmed = false
    }

    @objc private func windowDidResignKey() {
        notifyUserInteraction()
        releaseMouse()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        releaseMouse()
    }
}

private extension RenderShortcutModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: RenderShortcutModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        self = modifiers
    }
}
