#if os(macOS)
    import AppKit
    import SwiftUI

    /// A non-intercepting native cursor region for controls layered over NSTextView.
    struct PointingHandRegion: NSViewRepresentable {
        var cursor: NSCursor = .pointingHand

        func makeNSView(context: Context) -> PointingHandRegionView {
            let view = PointingHandRegionView()
            view.cursor = cursor
            return view
        }
        func updateNSView(_ view: PointingHandRegionView, context: Context) {
            view.cursor = cursor
            view.window?.invalidateCursorRects(for: view)
        }
    }

    final class PointingHandRegionView: NSView {
        private static let regions = NSHashTable<PointingHandRegionView>.weakObjects()
        private var cursorTracking: NSTrackingArea?
        var cursor: NSCursor = .pointingHand

        static func cursor(at point: NSPoint, in window: NSWindow?) -> NSCursor? {
            guard let window else { return nil }
            return regions.allObjects.first {
                $0.window === window && !$0.isHiddenOrHasHiddenAncestor
                    && $0.visibleRect.contains($0.convert(point, from: nil))
            }?.cursor
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                Self.regions.add(self)
            } else {
                Self.regions.remove(self)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(visibleRect, cursor: cursor)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let cursorTracking { removeTrackingArea(cursorTracking) }
            let area = NSTrackingArea(
                rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self, userInfo: nil)
            addTrackingArea(area)
            cursorTracking = area
        }

        override func cursorUpdate(with event: NSEvent) { cursor.set() }
        override func mouseEntered(with event: NSEvent) { cursor.set() }
        override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
    }
#endif
