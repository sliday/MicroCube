import AppKit
import CoreGraphics
import MetalKit

final class MetalInputView: MTKView {
    private enum KeyCode {
        static let a: UInt16 = 0
        static let s: UInt16 = 1
        static let d: UInt16 = 2
        static let f: UInt16 = 3
        static let q: UInt16 = 12
        static let w: UInt16 = 13
        static let e: UInt16 = 14
        static let r: UInt16 = 15
        static let returnKey: UInt16 = 36
        static let space: UInt16 = 49
        static let escape: UInt16 = 53

        static let movement = [w, s, a, d, q, e]
    }

    let input: InputState
    var onToggleFullscreen: (() -> Void)?
    var onReset: (() -> Void)?
    var onCaptureChanged: ((Bool) -> Void)?

    private(set) var isMouseCaptured = false

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
        window?.makeFirstResponder(self)
        captureMouse()
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        captureMouse()
    }

    override func mouseMoved(with event: NSEvent) {
        recordMouseDelta(event)
    }

    override func mouseDragged(with event: NSEvent) {
        recordMouseDelta(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        recordMouseDelta(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        recordMouseDelta(event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case KeyCode.returnKey, KeyCode.space:
            if !isMouseCaptured && !event.isARepeat {
                captureMouse()
            }
        case KeyCode.escape:
            if !event.isARepeat {
                releaseMouse()
            }
        case KeyCode.f:
            if !event.isARepeat {
                onToggleFullscreen?()
            }
        case KeyCode.r:
            if !event.isARepeat {
                onReset?()
            }
        case KeyCode.w, KeyCode.s, KeyCode.a, KeyCode.d, KeyCode.q, KeyCode.e:
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
        input.setSpeedBoost(event.modifierFlags.contains(.shift))
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

    @objc private func windowDidResignKey() {
        releaseMouse()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        releaseMouse()
    }
}
