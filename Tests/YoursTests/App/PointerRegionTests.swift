#if os(macOS)
    import AppKit
    import Testing
    @testable import Yours

    @MainActor
    struct PointerRegionTests {
        @Test func textTrackingCannotOverrideAnOverlayButtonCursor() throws {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: .titled, backing: .buffered, defer: false)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            window.contentView = host
            let editor = ReadingMacTextView(frame: host.bounds)
            host.addSubview(editor)
            let region = PointingHandRegionView(frame: NSRect(x: 20, y: 20, width: 32, height: 32))
            host.addSubview(region)
            let point = NSPoint(x: 30, y: 30)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
            defer { NSCursor.arrow.set() }
            #expect(PointingHandRegionView.cursor(at: point, in: window) == .pointingHand)
            #expect(region.hitTest(NSPoint(x: 5, y: 5)) == nil)
            NSCursor.arrow.set()
            editor.cursorUpdate(with: event)
            #expect(NSCursor.current == .pointingHand)
            editor.mouseMoved(with: event)
            #expect(NSCursor.current == .pointingHand)
            region.cursor = .operationNotAllowed
            editor.cursorUpdate(with: event)
            #expect(NSCursor.current == .operationNotAllowed)
            region.isHidden = true
            editor.cursorUpdate(with: event)
            #expect(NSCursor.current == .iBeam)
            region.isHidden = false
            region.removeFromSuperview()
            #expect(PointingHandRegionView.cursor(at: point, in: window) == nil)
            editor.cursorUpdate(with: event)
            #expect(NSCursor.current == .iBeam)
        }
    }
#endif
