import AppKit
import CoreGraphics
import Foundation

enum RegionPickResult {
    case picked(CGRect)
    case cancelled
}

enum RegionPicker {
    static func pick(displayID: CGDirectDisplayID) throws -> CGRect {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        guard let screen = NSScreen.screens.first(where: { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        }) else {
            throw RecorderError.message("Could not find the screen for display selection.")
        }

        let controller = RegionPickerController(screen: screen)
        controller.show()
        app.activate(ignoringOtherApps: true)

        while controller.result == nil {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.03))
        }

        switch controller.result! {
        case .cancelled:
            throw RecorderError.message("Region selection was cancelled.")
        case .picked(let rect):
            if rect.width < 2 || rect.height < 2 {
                throw RecorderError.message("The selected region is too small.")
            }
            return rect
        }
    }
}

final class RegionPickerController: NSObject {
    private let screen: NSScreen
    private var overlay: NSWindow?
    private let canvas: RegionPickerView
    var result: RegionPickResult?

    init(screen: NSScreen) {
        self.screen = screen
        self.canvas = RegionPickerView(frame: screen.frame)
        super.init()
        canvas.onComplete = { [weak self] result in
            self?.finish(result)
        }
    }

    func show() {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = canvas
        window.makeKeyAndOrderFront(nil)
        overlay = window
        canvas.window?.makeFirstResponder(canvas)
    }

    private func finish(_ result: RegionPickResult) {
        self.result = result
        overlay?.orderOut(nil)
        overlay = nil
    }
}

final class RegionPickerView: NSView {
    var onComplete: ((RegionPickResult) -> Void)?
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var finished = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            complete(.cancelled)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        guard let rect = selectionRect(), rect.width >= 2, rect.height >= 2 else {
            complete(.cancelled)
            return
        }
        complete(.picked(rect))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let rect = selectionRect() else {
            return
        }

        NSColor.clear.setFill()
        rect.fill(using: .clear)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        border.stroke()

        let label = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        let labelOrigin = CGPoint(x: rect.midX - size.width / 2, y: max(8, rect.minY - size.height - 8))
        label.draw(at: labelOrigin, withAttributes: attributes)
    }

    private func selectionRect() -> NSRect? {
        guard let startPoint, let currentPoint else {
            return nil
        }
        return NSRect(
            x: min(startPoint.x, currentPoint.x),
            y: min(startPoint.y, currentPoint.y),
            width: abs(currentPoint.x - startPoint.x),
            height: abs(currentPoint.y - startPoint.y)
        )
    }

    private func complete(_ result: RegionPickResult) {
        guard !finished else {
            return
        }
        finished = true
        onComplete?(result)
    }
}
