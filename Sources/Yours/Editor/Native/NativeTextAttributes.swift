import SwiftUI

#if os(macOS)
    import AppKit
    typealias PlatformTextView = NSTextView
    typealias PlatformFont = NSFont
#else
    import UIKit
    typealias PlatformTextView = UITextView
    typealias PlatformFont = UIFont
#endif

enum CodeStyleAttribute: CodableAttributedStringKey {
    typealias Value = String
    static let name = "yours.codeStyle"
}

struct NoteAttributeScope: AttributeScope {
    let swiftUI: NoteSwiftUIAttributes
    let table: TableAttribute
    let renderedContent: RenderedContentAttribute
    let codeLanguage: CodeLanguageAttribute
    let codeStyle: CodeStyleAttribute
    let paragraphStyle: ParagraphStyleAttribute
    let quote: QuoteAttribute
    let taskState: TaskStateAttribute
    let listMarker: ListMarkerAttribute
    let inlineEmphasis: InlineEmphasisAttribute
}

extension NSAttributedString.Key {
    static let yoursStoredFont = NSAttributedString.Key("yours.storedFont")
    static let yoursInlineEmphasis = NSAttributedString.Key(InlineEmphasisAttribute.name)
    static let yoursRenderedContent = NSAttributedString.Key(RenderedContentAttribute.name)
    static let yoursTable = NSAttributedString.Key(TableAttribute.name)
    static let yoursCodeLanguage = NSAttributedString.Key(CodeLanguageAttribute.name)
    static let yoursSyntaxColor = NSAttributedString.Key("yours.syntaxColor")
    static let yoursParagraphStyle = NSAttributedString.Key(ParagraphStyleAttribute.name)
    static let yoursQuote = NSAttributedString.Key(QuoteAttribute.name)
    static let yoursQuoteColor = NSAttributedString.Key("yours.quoteColor")
    static let yoursListMarker = NSAttributedString.Key(ListMarkerAttribute.name)
    static let yoursTaskChecked = NSAttributedString.Key(TaskStateAttribute.name)
    static let yoursInlineSpacing = NSAttributedString.Key("yours.inlineSpacing")
    static let yoursCodeStyle = NSAttributedString.Key(CodeStyleAttribute.name)
}

/// Keeps normal paragraphs at reading width while unwrapped code gets its own horizontal viewport.
final class CodeTextContainer: NSTextContainer {
    override func lineFragmentRect(
        forProposedRect proposedRect: CGRect, at characterIndex: Int,
        writingDirection: NSWritingDirection, remaining remainingRect: UnsafeMutablePointer<CGRect>?
    ) -> CGRect {
        var rect = super.lineFragmentRect(
            forProposedRect: proposedRect, at: characterIndex, writingDirection: writingDirection, remaining: remainingRect)
        guard let layout = layoutManager as? CodeLayoutManager, let storage = layout.textStorage,
            characterIndex < storage.length,
            let id = storage.attribute(.yoursCodeStyle, at: characterIndex, effectiveRange: nil) as? String,
            id.hasPrefix("block:")
        else { return rect }
        let gutter = layout.codeGutterWidth(at: characterIndex)
        if layout.unwrappedCode.contains(id) {
            rect.origin.x = -(layout.codeScrollOffsets[id] ?? 0)
            rect.size.width = max(size.width, layout.codeLineWidths[id] ?? size.width)
        }
        rect.origin.x += gutter
        rect.size.width = max(1, rect.width - gutter)
        return rect
    }
}

/// Draw code surfaces behind text while retaining native selection, caret and scrolling.
final class CodeLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    private(set) var unwrappedCode: Set<String> = []
    private(set) var codeLineWidths: [String: CGFloat] = [:]
    private(set) var codeScrollOffsets: [String: CGFloat] = [:]

    private var codeGutters: [String: CGFloat] = [:]

    private func codeNumberFont(at character: Int) -> PlatformFont {
        let font = textStorage?.attribute(.font, at: character, effectiveRange: nil) as? PlatformFont
        return .monospacedDigitSystemFont(ofSize: max(10, (font?.pointSize ?? DocumentTypography.bodySize) - 2), weight: .regular)
    }

    func codeGutterWidth(at character: Int) -> CGFloat {
        guard let storage = textStorage, character < storage.length else { return 0 }
        var range = NSRange()
        guard
            let id = storage.attribute(
                .yoursCodeStyle, at: character, longestEffectiveRange: &range,
                in: NSRange(location: 0, length: storage.length)) as? String, id.hasPrefix("block:")
        else { return 0 }
        if character != range.location, let width = codeGutters[id] { return width }
        let source = storage.string as NSString
        var count = 0
        var cursor = range.location
        while cursor < NSMaxRange(range) {
            count += 1
            cursor = NSMaxRange(source.lineRange(for: NSRange(location: cursor, length: 0)))
        }
        if NSMaxRange(range) == storage.length, storage.string.hasSuffix("\n") { count += 1 }
        let digits = max(2, String(count).count)
        let width =
            ceil((String(repeating: "0", count: digits) as NSString).size(withAttributes: [.font: codeNumberFont(at: character)]).width)
            + 12
        codeGutters[id] = width
        return width
    }

    struct CodeLineNumber {
        let number: Int
        let character: Int
        let rect: CGRect
    }

    func codeLineNumbers(in container: NSTextContainer) -> [CodeLineNumber] {
        guard let storage = textStorage else { return [] }
        let source = storage.string as NSString
        var labels: [CodeLineNumber] = []
        storage.enumerateAttribute(.yoursCodeStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let id = value as? String, id.hasPrefix("block:") else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let surface = self.codeBackgroundRect(forGlyphRange: glyphs, in: container)
            let gutter = self.codeGutterWidth(at: range.location)
            let font = self.codeNumberFont(at: range.location)
            let left = surface.minX + DocumentTypography.codeInset
            let top = surface.minY + Self.codeTopPadding + Self.headerHeight
            let bottom = surface.maxY - DocumentTypography.codeInset
            var cursor = range.location
            var number = 1
            while cursor < NSMaxRange(range) {
                let glyph = self.glyphIndexForCharacter(at: cursor)
                let baseline = self.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + self.location(forGlyphAt: glyph).y
                let rect = CGRect(x: left, y: baseline - font.ascender, width: gutter - 12, height: font.ascender - font.descender)
                if rect.maxY > top, rect.minY < bottom {
                    labels.append(CodeLineNumber(number: number, character: cursor, rect: rect))
                }
                cursor = NSMaxRange(source.lineRange(for: NSRange(location: cursor, length: 0)))
                number += 1
            }
            if NSMaxRange(range) == storage.length, storage.string.hasSuffix("\n"), self.extraLineFragmentUsedRect.height > 0 {
                let rect = CGRect(
                    x: left, y: self.extraLineFragmentUsedRect.minY, width: gutter - 12, height: font.ascender - font.descender)
                labels.append(CodeLineNumber(number: number, character: storage.length, rect: rect))
            }
        }
        return labels
    }

    private func drawCodeLineNumbers(at origin: CGPoint) {
        guard let container = textContainers.first, let storage = textStorage, storage.length > 0 else { return }
        for label in codeLineNumbers(in: container) {
            let character = min(label.character, storage.length - 1)
            let font = codeNumberFont(at: character)
            #if os(macOS)
                let color = NSColor.secondaryLabelColor
                let context = NSGraphicsContext.current?.cgContext
            #else
                let color = UIColor.secondaryLabel
                let context = UIGraphicsGetCurrentContext()
            #endif
            var range = NSRange()
            _ = storage.attribute(
                .yoursCodeStyle, at: character, longestEffectiveRange: &range,
                in: NSRange(location: 0, length: storage.length))
            var clip = codeBackgroundRect(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            clip.origin.y += Self.codeTopPadding + Self.headerHeight
            clip.size.height -= Self.codeTopPadding + Self.headerHeight + DocumentTypography.codeInset
            context?.saveGState()
            context?.clip(to: clip.offsetBy(dx: origin.x, dy: origin.y))
            let text = String(label.number) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let width = text.size(withAttributes: attributes).width
            text.draw(at: CGPoint(x: origin.x + label.rect.maxX - width, y: origin.y + label.rect.minY), withAttributes: attributes)
            context?.restoreGState()
        }
    }

    static let codeMaximumHeight: CGFloat = 400
    static var codeContentHeight: CGFloat {
        codeMaximumHeight - headerHeight - codeTopPadding - DocumentTypography.codeInset
    }
    private(set) var expandedCode: Set<String> = []

    func canExpandCode(id: String) -> Bool {
        (codeViewports[id]?.contentHeight ?? 0) > Self.codeContentHeight
    }

    private func contentHeightLimit(id: String) -> CGFloat {
        expandedCode.contains(id) ? CGFloat.greatestFiniteMagnitude : Self.codeContentHeight
    }

    func setCodeExpanded(_ expanded: Bool, id: String, in container: NSTextContainer) {
        if expanded { expandedCode.insert(id) } else { expandedCode.remove(id) }
        codeVerticalOffsets[id] = 0
        textContainerChangedGeometry(container)
        ensureLayout(for: container)
    }

    struct CodeOverflowEdges {
        let top: Bool
        let bottom: Bool
        let left: Bool
        let right: Bool
    }

    func codeOverflowEdges(id: String, in container: NSTextContainer) -> CodeOverflowEdges {
        let vertical = codeVerticalLimit(id: id)
        let horizontal = unwrappedCode.contains(id) ? max(0, (codeLineWidths[id] ?? 0) - container.size.width) : 0
        let x = codeScrollOffsets[id] ?? 0
        let y = codeVerticalOffsets[id] ?? 0
        return CodeOverflowEdges(
            top: vertical > 0 && y > 0.5, bottom: y < vertical - 0.5,
            left: horizontal > 0 && x > 0.5, right: x < horizontal - 0.5)
    }

    private struct CodeLine {
        let characters: NSRange
        let top: CGFloat
        let advance: CGFloat
        let height: CGFloat
    }
    private struct CodeViewport {
        var top: CGFloat
        var lines: [Int: CodeLine] = [:]
        var contentHeight: CGFloat = 0
        var nextCharacter: Int = 0
        var nextTop: CGFloat = 0
    }
    private var codeViewports: [String: CodeViewport] = [:]
    private(set) var codeVerticalOffsets: [String: CGFloat] = [:]

    func codeVerticalLimit(id: String) -> CGFloat {
        max(0, (codeViewports[id]?.contentHeight ?? 0) - contentHeightLimit(id: id))
    }

    func scrollCodeVertically(id: String, delta: CGFloat, in container: NSTextContainer, showIndicator: Bool = false) {
        let limit = codeVerticalLimit(id: id)
        if showIndicator, limit > 0, delta != 0 { showCodeIndicatorRespectingMotion(id: id) }
        let offset = min(limit, max(0, (codeVerticalOffsets[id] ?? 0) + delta))
        guard offset != (codeVerticalOffsets[id] ?? 0) else { return }
        codeVerticalOffsets[id] = offset
        textContainerChangedGeometry(container)
        ensureLayout(for: container)
    }

    func scrollableCode(at point: CGPoint, in container: NSTextContainer, vertical: Bool) -> String? {
        guard let storage = textStorage else { return nil }
        ensureLayout(for: container)
        var found: String?
        storage.enumerateAttribute(.yoursCodeStyle, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let id = value as? String,
                vertical ? self.codeVerticalLimit(id: id) > 0 : self.unwrappedCode.contains(id)
            else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            if self.codeBackgroundRect(forGlyphRange: glyphs, in: container).contains(point) {
                found = id
                stop.pointee = true
            }
        }
        return found
    }

    // Keep full text and UTF-16 ranges in native storage. Each visual line only
    // contributes its intersection with the block viewport to document height;
    // glyph baselines retain their unclipped position and drawing clips at the
    // fixed viewport. The natural line map also makes hidden caret targets visible.
    private func constrainCodeLine(
        id: String, range: NSRange, character: Int, glyphs: NSRange,
        fragment: UnsafeMutablePointer<CGRect>, used: UnsafeMutablePointer<CGRect>, baseline: UnsafeMutablePointer<CGFloat>
    ) {
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let paragraph = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle
        let lastCharacter = (storage.string as NSString).character(at: NSMaxRange(characters) - 1)
        let trailing = lastCharacter == 10 || lastCharacter == 0x2029 ? paragraph?.paragraphSpacing ?? 0 : 0
        let leading = max(0, used.pointee.minY - fragment.pointee.minY)
        let advance = max(0, fragment.pointee.height - leading - trailing)
        if character == range.location {
            codeViewports[id] = CodeViewport(top: used.pointee.minY)
        }
        guard var viewport = codeViewports[id] else { return }
        let top: CGFloat
        if viewport.nextCharacter == character {
            top = viewport.nextTop
        } else {
            let preceding = viewport.lines.values.filter { NSMaxRange($0.characters) <= character }.max { $0.top < $1.top }
            top = preceding.map { $0.top + $0.advance } ?? 0
            viewport.lines = viewport.lines.filter { $0.key < character }
        }
        viewport.nextCharacter = NSMaxRange(characters)
        viewport.nextTop = top + advance
        viewport.lines[character] = CodeLine(characters: characters, top: top, advance: advance, height: used.pointee.height)
        viewport.contentHeight = top + used.pointee.height
        codeViewports[id] = viewport
        let offset = codeVerticalOffsets[id] ?? 0
        let start = min(contentHeightLimit(id: id), max(0, top - offset))
        let end = min(contentHeightLimit(id: id), max(0, top + advance - offset))
        let actualTop = viewport.top + top - offset
        let visibleTop = viewport.top + start
        let visibleBottom = min(viewport.top + contentHeightLimit(id: id), actualTop + used.pointee.height)
        let baselineFromUsed = baseline.pointee - leading
        fragment.pointee.size.height = leading + end - start + trailing
        used.pointee.origin.y = visibleTop
        used.pointee.size.height = max(0, visibleBottom - visibleTop)
        baseline.pointee = actualTop - fragment.pointee.minY + baselineFromUsed
    }

    weak var codeDisplayView: PlatformTextView?
    private struct ScrollIndicator {
        var start: TimeInterval
        var lastActivity: TimeInterval
        var startOpacity: CGFloat
        var reducedMotion: Bool

        func opacity(at time: TimeInterval) -> CGFloat {
            let elapsed = max(0, time - start)
            let idle = max(0, time - lastActivity - 0.65)
            if reducedMotion { return idle > 0 ? 0 : 1 }
            let fadeIn = min(1, elapsed / 0.12)
            let fadeOut = min(1, idle / 0.25)
            return (startOpacity + (1 - startOpacity) * fadeIn) * (1 - fadeOut)
        }
    }
    private var scrollIndicators: [String: ScrollIndicator] = [:]
    private var indicatorTimer: Timer?

    func codeIndicatorOpacity(id: String, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> CGFloat {
        scrollIndicators[id]?.opacity(at: time) ?? 0
    }

    func showCodeIndicator(id: String, at time: TimeInterval = ProcessInfo.processInfo.systemUptime, reducedMotion: Bool = false) {
        if var indicator = scrollIndicators[id], time - indicator.lastActivity <= 0.65 {
            indicator.lastActivity = time
            scrollIndicators[id] = indicator
        } else {
            scrollIndicators[id] = ScrollIndicator(
                start: time, lastActivity: time, startOpacity: codeIndicatorOpacity(id: id, at: time), reducedMotion: reducedMotion)
        }
        guard indicatorTimer == nil else { return }
        let target = CodeIndicatorClock()
        target.layout = self
        let timer = Timer(timeInterval: 1 / 60, target: target, selector: #selector(CodeIndicatorClock.tick), userInfo: nil, repeats: true)
        indicatorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func showCodeIndicatorRespectingMotion(id: String) {
        // Native scroll callbacks are delivered on the main thread.
        let reducedMotion = MainActor.assumeIsolated {
            #if os(macOS)
                NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            #else
                UIAccessibility.isReduceMotionEnabled
            #endif
        }
        showCodeIndicator(id: id, reducedMotion: reducedMotion)
    }

    func updateCodeIndicators(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        scrollIndicators = scrollIndicators.filter { time - $0.value.lastActivity < ($0.value.reducedMotion ? 0.65 : 0.9) }
        // The native editor and this common-mode timer both run on the main thread.
        // Redraw the view because the indicator is below the glyph invalidation rect.
        let view = codeDisplayView
        MainActor.assumeIsolated {
            #if os(macOS)
                view?.needsDisplay = true
            #else
                view?.setNeedsDisplay()
            #endif
        }
        if scrollIndicators.isEmpty {
            indicatorTimer?.invalidate()
            indicatorTimer = nil
        }
    }

    func updateCodeWidth(id: String, range: NSRange, in container: NSTextContainer) {
        guard let storage = textStorage else { return }
        let source = storage.string as NSString
        var width: CGFloat = 0
        var index = range.location
        while index < NSMaxRange(range) {
            let line = NSIntersectionRange(source.lineRange(for: NSRange(location: index, length: 0)), range)
            let text = storage.attributedSubstring(from: line)
            width = max(width, CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)))
            index = NSMaxRange(line)
        }
        let quote = storage.attribute(.yoursQuote, at: range.location, effectiveRange: nil) as? Bool == true
        width =
            ceil(width) + 2 * (container.lineFragmentPadding + DocumentTypography.codeInset) + (quote ? DocumentTypography.quoteIndent : 0)
            + 1
        let oldGutter = codeGutters[id]
        let gutter = codeGutterWidth(at: range.location)
        width += gutter
        if oldGutter != gutter { invalidateLayout(forCharacterRange: range, actualCharacterRange: nil) }
        let oldWidth = codeLineWidths[id]
        let oldOffset = codeScrollOffsets[id]
        codeLineWidths[id] = width
        codeScrollOffsets[id] = min(codeScrollOffsets[id] ?? 0, max(0, width - container.size.width))
        if unwrappedCode.contains(id), oldWidth != width || oldOffset != codeScrollOffsets[id] {
            invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }

    func setCodeWrapping(_ wraps: Bool, id: String) {
        if wraps { unwrappedCode.remove(id) } else { unwrappedCode.insert(id) }
        codeScrollOffsets[id] = 0
        codeVerticalOffsets[id] = 0
        scrollIndicators[id] = nil
        if let storage = textStorage {
            invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        }
    }

    func scrollCode(id: String, delta: CGFloat, in container: NSTextContainer, showIndicator: Bool = false) {
        guard unwrappedCode.contains(id) else { return }
        let limit = max(0, (codeLineWidths[id] ?? 0) - container.size.width)
        if showIndicator, limit > 0, delta != 0 {
            showCodeIndicatorRespectingMotion(id: id)
        }
        let offset = min(limit, max(0, (codeScrollOffsets[id] ?? 0) + delta))
        guard offset != codeScrollOffsets[id] else { return }
        codeScrollOffsets[id] = offset
        textContainerChangedGeometry(container)
    }

    func unwrappedCode(at point: CGPoint, in container: NSTextContainer) -> String? {
        scrollableCode(at: point, in: container, vertical: false)
    }

    func clampCodeViewports(in container: NSTextContainer) {
        ensureLayout(for: container)
        var changed = false
        for (id, offset) in codeVerticalOffsets {
            let clamped = min(offset, codeVerticalLimit(id: id))
            if clamped != offset {
                codeVerticalOffsets[id] = clamped
                changed = true
            }
        }
        if changed {
            textContainerChangedGeometry(container)
            ensureLayout(for: container)
        }
    }

    override func setExtraLineFragmentRect(_ fragmentRect: CGRect, usedRect: CGRect, textContainer: NSTextContainer) {
        guard let storage = textStorage, storage.length > 0, storage.string.hasSuffix("\n"),
            let id = storage.attribute(.yoursCodeStyle, at: storage.length - 1, effectiveRange: nil) as? String,
            var viewport = codeViewports[id],
            let paragraph = storage.attribute(.paragraphStyle, at: storage.length - 1, effectiveRange: nil) as? NSParagraphStyle
        else {
            super.setExtraLineFragmentRect(fragmentRect, usedRect: usedRect, textContainer: textContainer)
            return
        }
        let height = paragraph.minimumLineHeight + paragraph.lineSpacing
        viewport.contentHeight = viewport.nextTop + height
        codeViewports[id] = viewport
        var fragment = fragmentRect
        var used = usedRect
        if textContainer is CodeTextContainer {
            let gutter = codeGutterWidth(at: storage.length - 1)
            fragment.origin.x = gutter - (codeScrollOffsets[id] ?? 0)
            fragment.size.width = max(1, fragment.width - gutter)
            used.origin.x = fragment.minX + textContainer.lineFragmentPadding + paragraph.firstLineHeadIndent
        }
        let top = viewport.nextTop - (codeVerticalOffsets[id] ?? 0)
        fragment.origin.y = viewport.top + min(contentHeightLimit(id: id), max(0, top))
        fragment.size.height = max(0, min(contentHeightLimit(id: id), top + height) - max(0, top))
        used.origin.y = fragment.minY
        used.size.height = min(used.height, fragment.height)
        super.setExtraLineFragmentRect(fragment, usedRect: used, textContainer: textContainer)
    }

    func prepareCodeVerticalMovement(from index: Int, down: Bool, in container: NSTextContainer) {
        guard let storage = textStorage, storage.length > 0 else { return }
        ensureLayout(for: container)
        let character = min(index, storage.length - 1)
        guard let id = storage.attribute(.yoursCodeStyle, at: character, effectiveRange: nil) as? String,
            codeVerticalLimit(id: id) > 0, let viewport = codeViewports[id]
        else {
            let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: character, length: 0))
            let neighbor = down ? NSMaxRange(paragraph) : paragraph.location - 1
            if neighbor >= 0, neighbor < storage.length { revealCodeCaret(at: neighbor, in: container, horizontally: false) }
            return
        }
        let lines = viewport.lines.values.sorted { $0.characters.location < $1.characters.location }
        guard let current = lines.firstIndex(where: { NSLocationInRange(character, $0.characters) }) else { return }
        let isTrailingBlank = index == storage.length && storage.string.hasSuffix("\n")
        let adjacent = current + (isTrailingBlank ? 1 : 0) + (down ? 1 : -1)
        guard lines.indices.contains(adjacent) else { return }
        // Give TextKit real visible geometry for the adjacent visual line before
        // it performs native column-preserving movement or extends a selection.
        revealCodeCaret(at: lines[adjacent].characters.location, in: container, horizontally: false)
    }

    func revealCodeCaret(at index: Int, in container: NSTextContainer, horizontally: Bool = true) {
        guard let storage = textStorage, storage.length > 0, index <= storage.length else { return }
        let character = min(index, storage.length - 1)
        guard let id = storage.attribute(.yoursCodeStyle, at: character, effectiveRange: nil) as? String,
            id.hasPrefix("block:")
        else { return }
        ensureLayout(for: container)
        if let viewport = codeViewports[id],
            var line = viewport.lines.values.first(where: { NSLocationInRange(character, $0.characters) })
        {
            if index == storage.length, storage.string.hasSuffix("\n") {
                line = CodeLine(
                    characters: NSRange(location: index, length: 0), top: viewport.nextTop,
                    advance: line.advance, height: viewport.contentHeight - viewport.nextTop)
            }
            let offset = codeVerticalOffsets[id] ?? 0
            if line.top < offset { scrollCodeVertically(id: id, delta: line.top - offset, in: container) }
            if line.top + line.height > offset + contentHeightLimit(id: id) {
                scrollCodeVertically(id: id, delta: line.top + line.height - offset - contentHeightLimit(id: id), in: container)
            }
        }
        guard horizontally, unwrappedCode.contains(id) else { return }
        let glyph = glyphIndexForCharacter(at: character)
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        var x = fragment.minX + location(forGlyphAt: glyph).x
        if index == storage.length {
            x =
                storage.string.hasSuffix("\n")
                ? fragment.minX + container.lineFragmentPadding + DocumentTypography.codeInset
                : lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).maxX - DocumentTypography.codeInset
        }
        let quote = storage.attribute(.yoursQuote, at: character, effectiveRange: nil) as? Bool == true
        let left =
            container.lineFragmentPadding + DocumentTypography.codeInset + codeGutterWidth(at: character)
            + (quote ? DocumentTypography.quoteIndent : 0)
        let right = container.size.width - container.lineFragmentPadding - DocumentTypography.codeInset
        if x < left { scrollCode(id: id, delta: x - left, in: container) }
        if x > right { scrollCode(id: id, delta: x - right + 1, in: container) }
    }

    private func drawNativeText(for glyphs: NSRange, at origin: CGPoint, background: Bool) {
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.yoursCodeStyle, in: characters) { value, range, _ in
            let part = NSIntersectionRange(glyphs, self.glyphRange(forCharacterRange: range, actualCharacterRange: nil))
            guard part.length > 0 else { return }
            #if os(macOS)
                let context = NSGraphicsContext.current?.cgContext
            #else
                let context = UIGraphicsGetCurrentContext()
            #endif
            context?.saveGState()
            if let id = value as? String, id.hasPrefix("block:"),
                let container = self.textContainer(forGlyphAt: part.location, effectiveRange: nil)
            {
                var blockRange = NSRange()
                _ = storage.attribute(
                    .yoursCodeStyle, at: range.location, longestEffectiveRange: &blockRange,
                    in: NSRange(location: 0, length: storage.length))
                let blockGlyphs = self.glyphRange(forCharacterRange: blockRange, actualCharacterRange: nil)
                var clip = self.codeBackgroundRect(forGlyphRange: blockGlyphs, in: container)
                let gutter = self.codeGutterWidth(at: blockRange.location)
                clip.origin.x += DocumentTypography.codeInset + gutter
                clip.size.width -= 2 * DocumentTypography.codeInset + gutter
                clip.origin.y += Self.codeTopPadding + Self.headerHeight
                clip.size.height -= Self.codeTopPadding + Self.headerHeight + DocumentTypography.codeInset
                context?.clip(to: clip.offsetBy(dx: origin.x, dy: origin.y))
            }
            if background {
                super.drawBackground(forGlyphRange: part, at: origin)
            } else {
                super.drawGlyphs(forGlyphRange: part, at: origin)
            }
            context?.restoreGState()
        }
    }

    #if os(macOS)
        private struct LinkTransition {
            var value: CGFloat
            var start: CGFloat
            var target: CGFloat
        }
        private var linkTransitions: [NSRange: LinkTransition] = [:]
        private var linkAnimation: LinkHoverAnimation?
        var shouldReduceLinkHoverMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        var hoveredLinkRange: NSRange? {
            didSet {
                guard hoveredLinkRange != oldValue else { return }
                linkAnimation?.stop()
                for range in Array(linkTransitions.keys) {
                    guard var transition = linkTransitions[range] else { continue }
                    transition.start = transition.value
                    transition.target = 0
                    linkTransitions[range] = transition
                }
                if let range = hoveredLinkRange {
                    let value = linkTransitions[range]?.value ?? 0
                    linkTransitions[range] = LinkTransition(value: value, start: value, target: 1)
                }
                guard !shouldReduceLinkHoverMotion() else {
                    updateLinkHoverAnimation(progress: 1)
                    return
                }
                let animation = LinkHoverAnimation(duration: 0.16, animationCurve: .easeInOut)
                animation.layout = self
                animation.frameRate = 60
                animation.animationBlockingMode = .nonblocking
                linkAnimation = animation
                animation.start()
            }
        }

        func clearLinkHover() {
            hoveredLinkRange = nil
            linkAnimation?.stop()
            for range in linkTransitions.keys { invalidateLinkDisplay(range) }
            linkTransitions.removeAll()
            linkAnimation = nil
        }

        func updateLinkHoverAnimation(progress: CGFloat) {
            for range in Array(linkTransitions.keys) {
                guard var transition = linkTransitions[range] else { continue }
                transition.value = transition.start + (transition.target - transition.start) * progress
                linkTransitions[range] = progress >= 1 && transition.target == 0 ? nil : transition
                invalidateLinkDisplay(range)
            }
        }

        private func invalidateLinkDisplay(_ range: NSRange) {
            let valid = NSIntersectionRange(range, NSRange(location: 0, length: textStorage?.length ?? 0))
            if valid.length > 0 { invalidateDisplay(forCharacterRange: valid) }
        }

        func layoutManager(
            _ layoutManager: NSLayoutManager, shouldUseTemporaryAttributes attrs: [NSAttributedString.Key: Any],
            forDrawingToScreen toScreen: Bool, atCharacterIndex charIndex: Int, effectiveRange: NSRangePointer?
        ) -> [NSAttributedString.Key: Any]? {
            guard toScreen, !linkTransitions.isEmpty else { return attrs }
            let hover = linkTransitions.keys.first { NSLocationInRange(charIndex, $0) }
            if hover == nil {
                if let effectiveRange,
                    let next = linkTransitions.keys.filter({ $0.location > charIndex }).map(\.location).min()
                {
                    effectiveRange.pointee.length =
                        min(NSMaxRange(effectiveRange.pointee), next) - effectiveRange.pointee.location
                }
                return attrs
            }
            guard let hover, let transition = linkTransitions[hover] else { return attrs }
            if let effectiveRange {
                effectiveRange.pointee = NSIntersectionRange(effectiveRange.pointee, hover)
            }
            guard let storage = textStorage, charIndex < storage.length,
                storage.attribute(.link, at: charIndex, effectiveRange: nil) != nil
            else { return attrs }
            var result = attrs
            let foreground =
                attrs[.foregroundColor] as? NSColor
                ?? storage.attribute(.foregroundColor, at: charIndex, effectiveRange: nil) as? NSColor ?? .labelColor
            let underline = attrs[.underlineColor] as? NSColor ?? AppTheme.nativeAccent
            let hoverColor = AppTheme.nativeAccent.blended(withFraction: 0.15, of: .black) ?? AppTheme.nativeAccent
            result[.foregroundColor] = foreground.blended(withFraction: transition.value, of: hoverColor) ?? foreground
            result[.underlineColor] = underline.blended(withFraction: transition.value, of: hoverColor) ?? underline
            result[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return result
        }
    #endif
    static let headerHeight = DocumentTypography.codeHeaderHeight
    static let codeTopPadding: CGFloat = 12
    #if os(macOS)
        private struct BaselineKey: Hashable {
            let fontSize: CGFloat
            let lineHeight: CGFloat
        }
        private var baselineOffsets: [BaselineKey: CGFloat] = [:]
    #endif
    #if os(macOS)
        var emptyLineHeadIndent: CGFloat = 0 {
            didSet {
                guard emptyLineHeadIndent != oldValue,
                    let container = textContainers.first
                else { return }
                textContainerChangedGeometry(container)
                ensureLayout(for: container)
                guard let extraContainer = extraLineFragmentTextContainer else { return }
                // Resetting the native extra fragment makes NSTextView discard the
                // stale insertion rect it caches for a completely empty document.
                // The typesetter has already applied the typing paragraph's indent.
                super.setExtraLineFragmentRect(
                    extraLineFragmentRect,
                    usedRect: extraLineFragmentUsedRect,
                    textContainer: extraContainer
                )
            }
        }
    #endif
    var hoveredTaskMarker: Int? {
        didSet {
            guard hoveredTaskMarker != oldValue else { return }
            if let oldValue { invalidateDisplay(forCharacterRange: NSRange(location: oldValue, length: 1)) }
            if let hoveredTaskMarker { invalidateDisplay(forCharacterRange: NSRange(location: hoveredTaskMarker, length: 1)) }
        }
    }

    func codeHeaderY(forGlyph glyph: Int) -> CGFloat {
        if let storage = textStorage, characterIndexForGlyph(at: glyph) < storage.length,
            let id = storage.attribute(.yoursCodeStyle, at: characterIndexForGlyph(at: glyph), effectiveRange: nil) as? String,
            let viewport = codeViewports[id]
        {
            return viewport.top - Self.headerHeight
        }
        let used = lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        #if os(macOS)
            return used.minY - Self.headerHeight
        #else
            return used.minY
        #endif
    }

    func codeBackgroundRect(forGlyphRange glyphs: NSRange, in container: NSTextContainer) -> CGRect {
        var bounds = CGRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, used, _, lineGlyphs, _ in
            var surface = used
            #if os(macOS)
                if lineGlyphs.location == glyphs.location {
                    let headerY = self.codeHeaderY(forGlyph: lineGlyphs.location)
                    surface.size.height += surface.minY - headerY
                    surface.origin.y = headerY
                }
            #endif
            bounds = bounds.union(surface)
        }
        guard !bounds.isNull else { return .zero }
        if let storage = textStorage, storage.length > 0,
            NSMaxRange(characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)) == storage.length,
            storage.string.hasSuffix("\n"),
            (storage.attribute(.yoursCodeStyle, at: storage.length - 1, effectiveRange: nil) as? String)?.hasPrefix("block:") == true,
            let paragraph = storage.attribute(.paragraphStyle, at: storage.length - 1, effectiveRange: nil) as? NSParagraphStyle
        {
            // An open code paragraph belongs to the surface even when the caret leaves it.
            // Do not use extraLineFragmentRect: its metrics depend on current typing attributes.
            bounds.size.height += paragraph.minimumLineHeight + paragraph.lineSpacing
        }
        let quoteInset: CGFloat
        if let storage = textStorage,
            storage.attribute(.yoursQuote, at: characterRange(forGlyphRange: glyphs, actualGlyphRange: nil).location, effectiveRange: nil)
                as? Bool == true
        {
            quoteInset = DocumentTypography.quoteIndent
        } else {
            quoteInset = 0
        }
        bounds.origin.x = container.lineFragmentPadding + quoteInset
        bounds.size.width = max(0, container.size.width - 2 * container.lineFragmentPadding - quoteInset)
        if let storage = textStorage,
            let id = storage.attribute(.yoursCodeStyle, at: characterIndexForGlyph(at: glyphs.location), effectiveRange: nil) as? String,
            let viewport = codeViewports[id]
        {
            bounds.origin.y = viewport.top - Self.headerHeight
            bounds.size.height = Self.headerHeight + min(contentHeightLimit(id: id), viewport.contentHeight)
        }
        var surface = bounds
        surface.origin.y -= Self.codeTopPadding
        surface.size.height += Self.codeTopPadding + DocumentTypography.codeInset
        if let storage = textStorage, glyphs.length > 0 {
            let source = storage.string as NSString
            let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let first = source.paragraphRange(for: NSRange(location: characters.location, length: 0))
            let last = source.paragraphRange(for: NSRange(location: NSMaxRange(characters) - 1, length: 0))
            func isCodeParagraph(at index: Int) -> Bool {
                let paragraph = source.paragraphRange(for: NSRange(location: index, length: 0))
                return (storage.attribute(.yoursCodeStyle, at: paragraph.location, effectiveRange: nil) as? String)?.hasPrefix("block:")
                    == true
            }
            // Separate code ranges may touch. Their translucent padding must
            // never overlap, even when an empty range reuses an earlier block ID.
            if first.location > 0, isCodeParagraph(at: first.location - 1) {
                let top = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil).minY
                surface.size.height -= max(0, top - surface.minY)
                surface.origin.y = max(surface.minY, top)
            }
            if NSMaxRange(last) < storage.length, isCodeParagraph(at: NSMaxRange(last)) {
                let bottom = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil).maxY
                surface.size.height = min(surface.maxY, bottom) - surface.minY
            }
        }
        return surface
    }
    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    #if os(macOS)
        func stableBaselineOffset(fontSize: CGFloat, lineHeight: CGFloat) -> CGFloat {
            let key = BaselineKey(fontSize: fontSize, lineHeight: lineHeight)
            if let cached = baselineOffsets[key] { return cached }
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
            let canonicalFont =
                CTFontCreateUIFontForLanguage(.system, fontSize, nil)
                ?? NSFont.systemFont(ofSize: fontSize) as CTFont
            let attributes: [NSAttributedString.Key: Any] = [
                // Use the concrete SF font behind SwiftUI's body role. The dynamic
                // `.AppleSystemUIFont` placeholder has different fractional leading.
                .font: canonicalFont as NSFont,
                .paragraphStyle: style,
            ]
            let storage = NSTextStorage(string: "A", attributes: attributes)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 100, height: 100))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let offset = layout.location(forGlyphAt: 0).y
            baselineOffsets[key] = offset
            return offset
        }
    #endif

    func quoteBarRect(forGlyphRange glyphs: NSRange, in container: NSTextContainer) -> CGRect {
        guard glyphs.length > 0, let storage = textStorage else { return .zero }
        var bounds = CGRect.null
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
            let visible = NSIntersectionRange(glyphs, lineGlyphs)
            guard visible.length > 0 else { return }
            let characters = self.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
            let style = storage.attribute(.paragraphStyle, at: characters.location, effectiveRange: nil) as? NSParagraphStyle
            let font = storage.attribute(.font, at: characters.location, effectiveRange: nil) as? PlatformFont
            let fixedHeight = style?.maximumLineHeight ?? 0
            let height =
                fixedHeight > 0
                ? fixedHeight
                : font.map(NativeTextAttributes.stableLineHeight) ?? fragment.height
            bounds = bounds.union(CGRect(x: fragment.minX, y: fragment.minY, width: fragment.width, height: height))
        }
        guard !bounds.isNull else { return .zero }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let fontSize =
            characters.location < storage.length
            ? (storage.attribute(.font, at: characters.location, effectiveRange: nil) as? PlatformFont)?.pointSize
                ?? DocumentTypography.bodySize
            : DocumentTypography.bodySize
        // Keep the bar airy inside a quote, but stop it at the final quote
        // fragment once the following paragraph has returned to body style.
        // Otherwise its overshoot visually collides with the body caret.
        let rangeEnd = NSMaxRange(characters)
        let endsAtOpenQuote = rangeEnd == storage.length && !storage.string.hasSuffix("\n")
        let continuesQuote =
            rangeEnd < storage.length
            && storage.attribute(.yoursQuote, at: rangeEnd, effectiveRange: nil) as? Bool == true
        return quoteBarRect(
            forLineBounds: bounds,
            fontSize: fontSize,
            extendsBelow: endsAtOpenQuote || continuesQuote,
            in: container
        )
    }

    private func quoteBarRect(
        forLineBounds bounds: CGRect, fontSize: CGFloat,
        extendsBelow: Bool, in container: NSTextContainer
    ) -> CGRect {
        let overshoot = fontSize * DocumentTypography.quoteBarVerticalOvershootRatio
        let opticalRise = fontSize * DocumentTypography.quoteBarOpticalRiseRatio
        let bottomOvershoot =
            extendsBelow
            ? overshoot
            : fontSize * DocumentTypography.quoteBarTerminalBottomOvershootRatio
        return CGRect(
            x: container.lineFragmentPadding,
            y: bounds.minY - overshoot - opticalRise,
            width: 2,
            height: bounds.height + overshoot + bottomOvershoot
        )
    }

    func emptyQuoteBarRect(at insertion: Int = 0, font: PlatformFont, in container: NSTextContainer) -> CGRect {
        let fragment: CGRect
        if let storage = textStorage, storage.length > 0, insertion < storage.length {
            let glyph = glyphIndexForCharacter(at: insertion)
            fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            fragment = extraLineFragmentRect
        }
        let lineHeight = NativeTextAttributes.stableLineHeight(for: font)
        let fontSize = font.pointSize
        let storageLength = textStorage?.length ?? 0
        let continuesQuote =
            insertion < storageLength
            && textStorage?.attribute(.yoursQuote, at: insertion, effectiveRange: nil) as? Bool == true
        return quoteBarRect(
            forLineBounds: CGRect(x: fragment.minX, y: fragment.minY, width: fragment.width, height: lineHeight),
            fontSize: fontSize,
            // An empty quote at the document end is still open. In the middle of
            // a document, use the same shorter terminal edge as a filled quote.
            extendsBelow: insertion >= storageLength || continuesQuote,
            in: container
        )
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<CGRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<CGRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let storage = textStorage, glyphRange.length > 0 else { return false }
        let character = characterIndexForGlyph(at: glyphRange.location)
        guard character < storage.length else { return false }
        #if os(macOS)
            // Keep a small share below the glyphs so native selection and caret do
            // not hug descenders, while most reading spacing stays outside input geometry.
            let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let spacing = interLineSpacing(for: characters)
            let paragraph = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle
            let codeStyle = storage.attribute(.yoursCodeStyle, at: character, effectiveRange: nil) as? String
            var hasAttachment = false
            storage.enumerateAttribute(.attachment, in: characters) { value, _, stop in
                if value != nil {
                    hasAttachment = true
                    stop.pointee = true
                }
            }
            let font = storage.attribute(.font, at: character, effectiveRange: nil) as? PlatformFont
            let stableContentHeight: CGFloat?
            if !hasAttachment, let maximum = paragraph?.maximumLineHeight, maximum > 0 {
                stableContentHeight = maximum
            } else if !hasAttachment, codeStyle?.hasPrefix("block:") != true, let font {
                // AppKit can temporarily drop the paragraph's maximum line height
                // while installing IME marked text. Keep normal prose on the same
                // mixed-script line box instead of falling back to the current
                // Latin or CJK glyph bounds.
                stableContentHeight = NativeTextAttributes.stableLineHeight(for: font)
            } else {
                stableContentHeight = nil
            }
            if let stableContentHeight {
                // TextKit puts paragraphSpacingBefore inside the first fragment,
                // above its used rect. Preserve that offset in both the line box
                // and baseline so glyphs stay aligned with native caret/selection.
                let contentOffset = max(0, lineFragmentUsedRect.pointee.minY - lineFragmentRect.pointee.minY)
                let last = (storage.string as NSString).character(at: NSMaxRange(characters) - 1)
                let paragraphSpacing = last == 10 || last == 0x2029 ? paragraph?.paragraphSpacing ?? 0 : 0
                lineFragmentRect.pointee.size.height = contentOffset + stableContentHeight + spacing + paragraphSpacing
                lineFragmentUsedRect.pointee.size.height = stableContentHeight + spacing * DocumentTypography.selectionLineSpacingShare
                if let font {
                    let baseFontSize =
                        codeStyle == "inline"
                        ? font.pointSize / DocumentTypography.inlineCodeScale
                        : font.pointSize
                    // TextKit substitutes PingFang while composing or committing
                    // CJK text. Its leading differs from SF by about half a point,
                    // so normalize the baseline as well as the line box.
                    baselineOffset.pointee =
                        contentOffset
                        + stableBaselineOffset(
                            fontSize: baseFontSize,
                            lineHeight: stableContentHeight
                        )
                }
            } else {
                lineFragmentUsedRect.pointee.size.height -= spacing * (1 - DocumentTypography.selectionLineSpacingShare)
            }
        #endif
        var range = NSRange()
        guard
            let id = storage.attribute(
                .yoursCodeStyle, at: character, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) as? String,
            id.hasPrefix("block:")
        else { return true }
        // TextKit ignores paragraphSpacingBefore at the start of a document.
        // Reserve both the header and the first block's upper surface padding;
        // drawing above the first line otherwise clips off its rounded corners.
        if character == range.location {
            let topPadding = character == 0 ? Self.codeTopPadding : 0
            lineFragmentRect.pointee.size.height += Self.headerHeight + topPadding
            lineFragmentUsedRect.pointee.origin.y += Self.headerHeight + topPadding
            baselineOffset.pointee += Self.headerHeight + topPadding
        }
        constrainCodeLine(
            id: id, range: range, character: character, glyphs: glyphRange,
            fragment: lineFragmentRect, used: lineFragmentUsedRect, baseline: baselineOffset)
        return true
    }

    #if os(macOS)
        private func interLineSpacing(for characters: NSRange) -> CGFloat {
            guard let storage = textStorage, characters.length > 0,
                let paragraph = storage.attribute(.paragraphStyle, at: characters.location, effectiveRange: nil) as? NSParagraphStyle
            else { return 0 }
            let last = (storage.string as NSString).character(at: NSMaxRange(characters) - 1)
            return NSMaxRange(characters) < storage.length || last == 10 || last == 0x2028 || last == 0x2029
                ? paragraph.lineSpacing : 0
        }
    #endif

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        guard let storage = textStorage else {
            super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        storage.enumerateAttribute(.yoursCodeStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let style = value as? String else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard style.hasPrefix("block:") || NSIntersectionRange(glyphs, glyphsToShow).length > 0,
                let container = self.textContainer(forGlyphAt: glyphs.location, effectiveRange: nil)
            else { return }
            #if os(macOS)
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
            #else
                UIColor.label.withAlphaComponent(0.06).setFill()
            #endif
            if style.hasPrefix("block:") {
                let rect = self.codeBackgroundRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
                self.fill(rect, radius: 8)
                let verticalLimit = self.codeVerticalLimit(id: style)
                if verticalLimit > 0 {
                    let track = CGRect(
                        x: rect.maxX - 7, y: rect.minY + Self.codeTopPadding + Self.headerHeight,
                        width: 3, height: Self.codeContentHeight)
                    let thumbHeight = max(24, track.height * Self.codeContentHeight / (Self.codeContentHeight + verticalLimit))
                    let progress = min(1, (self.codeVerticalOffsets[style] ?? 0) / verticalLimit)
                    #if os(macOS)
                        NSColor.secondaryLabelColor.withAlphaComponent(0.45 * self.codeIndicatorOpacity(id: style)).setFill()
                    #else
                        UIColor.secondaryLabel.withAlphaComponent(0.45 * self.codeIndicatorOpacity(id: style)).setFill()
                    #endif
                    self.fill(
                        CGRect(
                            x: track.minX, y: track.minY + (track.height - thumbHeight) * progress,
                            width: track.width, height: thumbHeight), radius: 1.5)
                }
                if self.unwrappedCode.contains(style), let width = self.codeLineWidths[style], width > container.size.width {
                    let track = CGRect(
                        x: rect.minX + DocumentTypography.codeInset, y: rect.maxY - 7,
                        width: max(0, rect.width - 2 * DocumentTypography.codeInset), height: 3)
                    let thumbWidth = max(24, track.width * container.size.width / width)
                    let progress = (self.codeScrollOffsets[style] ?? 0) / (width - container.size.width)
                    #if os(macOS)
                        NSColor.secondaryLabelColor.withAlphaComponent(0.45 * self.codeIndicatorOpacity(id: style)).setFill()
                    #else
                        UIColor.secondaryLabel.withAlphaComponent(0.45 * self.codeIndicatorOpacity(id: style)).setFill()
                    #endif
                    self.fill(
                        CGRect(
                            x: track.minX + (track.width - thumbWidth) * progress, y: track.minY,
                            width: thumbWidth, height: track.height), radius: 1.5)
                }
            } else {
                #if os(macOS)
                    let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    NSColor.labelColor.withAlphaComponent(dark ? 0.12 : 0.065).setFill()
                #else
                    UIColor.label.withAlphaComponent(UITraitCollection.current.userInterfaceStyle == .dark ? 0.12 : 0.065).setFill()
                #endif
                for rect in self.inlineCodeBackgroundRects(forGlyphRange: glyphs, in: container) {
                    self.fill(
                        rect.offsetBy(dx: origin.x, dy: origin.y),
                        radius: self.inlineCodeFontSize(forGlyphRange: glyphs) * DocumentTypography.inlineCodeRadiusRatio)
                }
            }
        }
        drawNativeText(for: glyphsToShow, at: origin, background: true)
    }

    private func generatedInlineSpacing(at character: Int) -> CGFloat {
        guard let storage = textStorage, character >= 0, character < storage.length,
            let original = storage.attribute(.yoursInlineSpacing, at: character, effectiveRange: nil) as? CGFloat
        else { return 0 }
        return max(0, (storage.attribute(.kern, at: character, effectiveRange: nil) as? CGFloat ?? original) - original)
    }

    #if os(macOS)
        override func fillBackgroundRectArray(
            _ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
            forCharacterRange charRange: NSRange, color: NSColor
        ) {
            // AppKit paints native selection through this primitive, bypassing
            // enumerateEnclosingRects. Apply the same boundary before the fill.
            guard let storage = textStorage, let container = textContainers.first,
                let view = container.textView, charRange.length > 0
            else {
                super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
                return
            }
            let (selected, origin, selectedColor) = MainActor.assumeIsolated {
                (view.selectedRange(), view.textContainerOrigin, view.selectedTextAttributes[.backgroundColor] as? NSColor)
            }
            guard selected.length > 0, NSMaxRange(selected) <= storage.length,
                NSMaxRange(charRange) == NSMaxRange(selected),
                color == selectedColor || color == NSColor.unemphasizedSelectedTextBackgroundColor
            else {
                super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
                return
            }
            let last = (storage.string as NSString).rangeOfComposedCharacterSequence(at: NSMaxRange(selected) - 1)
            let gap = generatedInlineSpacing(at: last.location)
            guard gap > 0 else {
                super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
                return
            }
            var trailing = CGRect.zero
            super.enumerateEnclosingRects(
                forGlyphRange: glyphRange(forCharacterRange: last, actualCharacterRange: nil),
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                trailing = rect.offsetBy(dx: origin.x, dy: origin.y)
            }
            var rects = Array(UnsafeBufferPointer(start: rectArray, count: rectCount))
            for index in rects.indices {
                let rect = rects[index]
                if rect.minY < trailing.maxY, rect.maxY > trailing.minY,
                    rect.maxX > trailing.maxX - gap, rect.maxX <= trailing.maxX + 1
                {
                    rects[index].size.width = max(0, trailing.maxX - gap - rect.minX)
                }
            }
            rects.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                super.fillBackgroundRectArray(base, count: rectCount, forCharacterRange: charRange, color: color)
            }
        }
    #endif

    // Layout reserves the code surface's padding, but selection geometry ends at
    // the character advance. Interior gaps remain selected when spanning a boundary.
    override func enumerateEnclosingRects(
        forGlyphRange glyphRange: NSRange, withinSelectedGlyphRange selectedRange: NSRange,
        in textContainer: NSTextContainer, using block: @escaping (CGRect, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        guard selectedRange.location != NSNotFound, selectedRange.length > 0,
            let storage = textStorage, NSMaxRange(selectedRange) <= numberOfGlyphs
        else {
            super.enumerateEnclosingRects(
                forGlyphRange: glyphRange, withinSelectedGlyphRange: selectedRange,
                in: textContainer, using: block)
            return
        }
        let characters = characterRange(forGlyphRange: selectedRange, actualGlyphRange: nil)
        let last = (storage.string as NSString).rangeOfComposedCharacterSequence(at: NSMaxRange(characters) - 1).location
        let gap = generatedInlineSpacing(at: last)
        let glyph = glyphIndexForCharacter(at: last)
        var trailingRect = CGRect.zero
        super.enumerateEnclosingRects(
            forGlyphRange: NSRange(location: glyph, length: 1),
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer
        ) { rect, _ in
            trailingRect = rect
        }
        super.enumerateEnclosingRects(
            forGlyphRange: glyphRange, withinSelectedGlyphRange: selectedRange,
            in: textContainer
        ) { rect, stop in
            var selection = rect
            if gap > 0, rect.minY < trailingRect.maxY, rect.maxY > trailingRect.minY, abs(rect.maxX - trailingRect.maxX) < 0.5 {
                selection.size.width = max(0, selection.width - gap)
            }
            block(selection, stop)
        }
    }

    override func characterIndex(
        for point: CGPoint, in container: NSTextContainer,
        fractionOfDistanceBetweenInsertionPoints partialFraction: UnsafeMutablePointer<CGFloat>?
    ) -> Int {
        let index = super.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: partialFraction)
        guard let storage = textStorage, index < storage.length else { return index }
        let character = (storage.string as NSString).rangeOfComposedCharacterSequence(at: index)
        let gap = generatedInlineSpacing(at: character.location)
        guard gap > 0 else { return index }
        let glyphs = glyphRange(forCharacterRange: character, actualCharacterRange: nil)
        var inSpacing = false
        super.enumerateEnclosingRects(
            forGlyphRange: glyphs,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
        ) { rect, _ in
            if point.y >= rect.minY, point.y <= rect.maxY, point.x >= rect.maxX - gap, point.x <= rect.maxX {
                inSpacing = true
            }
        }
        guard inSpacing else { return index }
        partialFraction?.pointee = 0
        return NSMaxRange(character)
    }

    override func getLineFragmentInsertionPoints(
        forCharacterAt charIndex: Int, alternatePositions aFlag: Bool, inDisplayOrder dFlag: Bool,
        positions: UnsafeMutablePointer<CGFloat>?, characterIndexes: UnsafeMutablePointer<Int>?
    ) -> Int {
        let count = super.getLineFragmentInsertionPoints(
            forCharacterAt: charIndex, alternatePositions: aFlag,
            inDisplayOrder: dFlag, positions: positions, characterIndexes: characterIndexes)
        guard let positions, let storage = textStorage, count > 0 else { return count }
        var indexes = [Int](repeating: 0, count: count)
        if let characterIndexes {
            for index in 0..<count { indexes[index] = characterIndexes[index] }
        } else {
            _ = super.getLineFragmentInsertionPoints(
                forCharacterAt: charIndex, alternatePositions: aFlag,
                inDisplayOrder: dFlag, positions: nil, characterIndexes: &indexes)
        }
        #if os(macOS)
            if let view = textContainers.first?.textView as? ReadingMacTextView {
                let boundary = MainActor.assumeIsolated { () -> (Int, CGPoint)? in
                    guard let state = view.inlineCodeBoundary, let point = view.inlineCodeBoundaryPoint() else { return nil }
                    return (state.index, point)
                }
                if let (character, point) = boundary {
                    let glyph = glyphIndexForCharacter(at: min(charIndex, max(0, storage.length - 1)))
                    let line = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    for index in 0..<count where indexes[index] == character { positions[index] = point.x - line.minX }
                }
            }
        #endif
        return count
    }

    private func drawInlineDecoration(for glyphs: NSRange, origin: CGPoint, draw: () -> Void) {
        guard glyphs.length > 0, let storage = textStorage,
            let container = textContainer(forGlyphAt: glyphs.location, effectiveRange: nil)
        else {
            draw()
            return
        }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var clips: [CGRect] = []
        var hasSpacing = false
        storage.enumerateAttribute(.yoursInlineSpacing, in: characters) { original, range, _ in
            var parts = [range]
            if original != nil {
                hasSpacing = true
                parts = []
                (storage.string as NSString).enumerateSubstrings(in: range, options: .byComposedCharacterSequences) { _, part, _, _ in
                    parts.append(part)
                }
            }
            for part in parts {
                let partGlyphs = self.glyphRange(forCharacterRange: part, actualCharacterRange: nil)
                super.enumerateEnclosingRects(
                    forGlyphRange: partGlyphs,
                    withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
                ) { rect, _ in
                    let gap = self.generatedInlineSpacing(at: part.location)
                    clips.append(
                        CGRect(
                            x: rect.minX + origin.x, y: rect.minY + origin.y - rect.height,
                            width: max(0, rect.width - gap), height: rect.height * 3))
                }
            }
        }
        guard hasSpacing else {
            draw()
            return
        }
        #if os(macOS)
            let context = NSGraphicsContext.current?.cgContext
        #else
            let context = UIGraphicsGetCurrentContext()
        #endif
        guard let context else {
            draw()
            return
        }
        context.saveGState()
        context.clip(to: clips)
        draw()
        context.restoreGState()
    }

    override func drawStrikethrough(
        forGlyphRange glyphRange: NSRange, strikethroughType strikethroughVal: NSUnderlineStyle,
        baselineOffset: CGFloat, lineFragmentRect lineRect: CGRect,
        lineFragmentGlyphRange lineGlyphRange: NSRange, containerOrigin: CGPoint
    ) {
        drawInlineDecoration(for: glyphRange, origin: containerOrigin) {
            super.drawStrikethrough(
                forGlyphRange: glyphRange, strikethroughType: strikethroughVal,
                baselineOffset: baselineOffset, lineFragmentRect: lineRect,
                lineFragmentGlyphRange: lineGlyphRange, containerOrigin: containerOrigin)
        }
    }

    override func drawUnderline(
        forGlyphRange glyphRange: NSRange, underlineType underlineVal: NSUnderlineStyle,
        baselineOffset: CGFloat, lineFragmentRect lineRect: CGRect,
        lineFragmentGlyphRange lineGlyphRange: NSRange, containerOrigin: CGPoint
    ) {
        var origin = containerOrigin
        if glyphRange.length > 0, let storage = textStorage {
            let character = characterIndexForGlyph(at: glyphRange.location)
            if character < storage.length, storage.attribute(.link, at: character, effectiveRange: nil) != nil {
                // Move only the decoration: glyph advances, selection and caret stay native.
                let font = storage.attribute(.font, at: character, effectiveRange: nil) as? PlatformFont
                origin.y += max(1.5, (font?.pointSize ?? DocumentTypography.bodySize) * 0.1)
            }
        }
        drawInlineDecoration(for: glyphRange, origin: origin) {
            super.drawUnderline(
                forGlyphRange: glyphRange, underlineType: underlineVal, baselineOffset: baselineOffset,
                lineFragmentRect: lineRect, lineFragmentGlyphRange: lineGlyphRange, containerOrigin: origin)
        }
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: CGPoint) {
        drawNativeText(for: glyphsToShow, at: origin, background: false)
        drawCodeLineNumbers(at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        #if os(macOS)
            if let textView = textContainers.first?.textView {
                let selected = MainActor.assumeIsolated { textView.selectedRange() }
                if selected.length > 0 {
                    NSColor.textBackgroundColor.setFill()
                    for rect in selectionCleanupRects(for: selected) {
                        fill(rect.offsetBy(dx: origin.x, dy: origin.y), radius: 0)
                    }
                }
            }
        #endif
        #if !os(macOS)
            drawQuoteBars(forGlyphRange: glyphsToShow, at: origin)
        #endif
        let visible = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let source = storage.string as NSString
        var location = source.paragraphRange(for: NSRange(location: visible.location, length: 0)).location
        let end = min(storage.length, NSMaxRange(visible))
        while location < end {
            let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
            if let marker = taskMarkerIndex(in: paragraph),
                let rect = taskMarkerRect(at: marker)?.offsetBy(dx: origin.x, dy: origin.y)
            {
                drawTaskMarker(
                    checked: storage.attribute(.yoursTaskChecked, at: marker, effectiveRange: nil) as? Bool ?? false,
                    hovered: hoveredTaskMarker == marker,
                    in: rect
                )
            }
            var listAnchor = paragraph.location
            while listAnchor < NSMaxRange(paragraph), source.character(at: listAnchor) == 9 { listAnchor += 1 }
            if listAnchor < storage.length,
                let marker = storage.attribute(.yoursListMarker, at: listAnchor, effectiveRange: nil) as? String,
                let rect = taskMarkerRect(at: listAnchor)?.offsetBy(dx: origin.x, dy: origin.y),
                let font = storage.attribute(.font, at: listAnchor, effectiveRange: nil) as? PlatformFont
            {
                drawListMarker(
                    marker, depth: listAnchor - paragraph.location, in: rect, font: font)
            }
            let next = NSMaxRange(paragraph)
            if next <= location { break }
            location = next
        }
    }

    #if os(macOS)
        func selectionCleanupRects(for selection: NSRange) -> [CGRect] {
            guard let storage = textStorage, selection.length > 0, storage.length > 0 else { return [] }
            let source = storage.string as NSString
            var rects: [CGRect] = []
            var location = source.paragraphRange(for: NSRange(location: min(selection.location, storage.length - 1), length: 0)).location
            let end = min(storage.length, NSMaxRange(selection))
            while location < end {
                let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
                let intersection = NSIntersectionRange(paragraph, selection)
                guard intersection.length > 0 else { break }
                let content = source.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
                let role = storage.attribute(.yoursParagraphStyle, at: paragraph.location, effectiveRange: nil) as? String ?? "body"
                let glyphs = glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
                if content.isEmpty, role == "body", glyphs.length > 0 {
                    enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
                        rects.append(fragment)
                    }
                }
                let next = NSMaxRange(paragraph)
                if next <= location { break }
                location = next
            }
            return rects
        }
    #endif

    func quoteBarDrawingRects(
        forGlyphRange glyphsToShow: NSRange, at origin: CGPoint,
        trailingEmptyBar: CGRect? = nil
    ) -> [CGRect] {
        guard let storage = textStorage else { return [] }
        var rects: [CGRect] = []
        storage.enumerateAttribute(.yoursQuote, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value as? Bool == true else { return }
            var drawnCharacters = range
            if drawnCharacters.length > 1,
                (storage.string as NSString).substring(with: NSRange(location: NSMaxRange(drawnCharacters) - 1, length: 1)) == "\n"
            {
                // A paragraph's terminating newline keeps its quote semantics
                // for serialization, but its TextKit glyph range reaches into
                // the following line. The active trailing empty quote is drawn
                // separately from typing attributes below.
                drawnCharacters.length -= 1
            }
            let glyphs = self.glyphRange(forCharacterRange: drawnCharacters, actualCharacterRange: nil)
            guard NSIntersectionRange(glyphs, glyphsToShow).length > 0,
                let container = self.textContainer(forGlyphAt: glyphs.location, effectiveRange: nil)
            else { return }
            rects.append(
                self.quoteBarRect(forGlyphRange: glyphs, in: container)
                    .offsetBy(dx: origin.x, dy: origin.y))
        }
        if let trailingEmptyBar,
            storage.length > 0,
            storage.string.hasSuffix("\n"),
            storage.attribute(.yoursQuote, at: storage.length - 1, effectiveRange: nil) as? Bool == true,
            !rects.isEmpty
        {
            rects[rects.count - 1] = rects[rects.count - 1].union(trailingEmptyBar)
        }
        return rects
    }

    @discardableResult
    func drawQuoteBars(
        forGlyphRange glyphsToShow: NSRange, at origin: CGPoint,
        trailingEmptyBar: CGRect? = nil
    ) -> Bool {
        let rects = quoteBarDrawingRects(
            forGlyphRange: glyphsToShow,
            at: origin,
            trailingEmptyBar: trailingEmptyBar
        )
        #if os(macOS)
            NSColor.labelColor.withAlphaComponent(0.22).setFill()
        #else
            UIColor.label.withAlphaComponent(0.22).setFill()
        #endif
        for rect in rects { fill(rect, radius: 1) }
        return trailingEmptyBar.map { empty in rects.contains(where: { $0.contains(empty) }) } ?? false
    }

    func taskMarkerRect(at character: Int) -> CGRect? {
        guard let storage = textStorage, character >= 0, character < storage.length,
            ["task", "bullet", "numbered"].contains(
                storage.attribute(.yoursParagraphStyle, at: character, effectiveRange: nil) as? String ?? "")
        else { return nil }
        let reference = character
        guard let font = storage.attribute(.font, at: reference, effectiveRange: nil) as? PlatformFont else { return nil }
        let glyphs = glyphRange(forCharacterRange: NSRange(location: reference, length: 1), actualCharacterRange: nil)
        guard glyphs.length > 0,
            textContainer(forGlyphAt: glyphs.location, effectiveRange: nil) != nil
        else { return nil }
        let fragment = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let textX = fragment.minX + location(forGlyphAt: glyphs.location).x
        let baseline = fragment.minY + self.location(forGlyphAt: glyphs.location).y
        let ascent = CTFontGetAscent(font as CTFont)
        let descent = CTFontGetDescent(font as CTFont)
        return taskMarkerRect(textX: textX, baseline: baseline, font: font, ascent: ascent, descent: descent)
    }

    func emptyTaskMarkerRect(
        at insertion: Int, font: PlatformFont, quoted: Bool,
        in container: NSTextContainer
    ) -> CGRect {
        let fragment: CGRect
        let source = (textStorage?.string ?? "") as NSString
        let paragraph = source.paragraphRange(for: NSRange(location: min(insertion, source.length), length: 0))
        let depth = source.substring(with: paragraph).prefix(while: { $0 == "\t" }).count
        if source.length > 0, paragraph.location < source.length {
            fragment = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: min(insertion, source.length - 1)), effectiveRange: nil)
        } else {
            fragment = extraLineFragmentRect
        }
        let lineHeight = NativeTextAttributes.stableLineHeight(for: font)
        #if os(macOS)
            let baseline = fragment.minY + stableBaselineOffset(fontSize: font.pointSize, lineHeight: lineHeight)
        #else
            let baseline = fragment.minY + max(0, (lineHeight - font.lineHeight) / 2) + font.ascender
        #endif
        let textX =
            fragment.minX + container.lineFragmentPadding + DocumentTypography.listIndent * CGFloat(depth + 1)
            + (quoted ? DocumentTypography.quoteIndent : 0)
        return taskMarkerRect(
            textX: textX,
            baseline: baseline,
            font: font,
            ascent: CTFontGetAscent(font as CTFont),
            descent: CTFontGetDescent(font as CTFont)
        )
    }

    func drawListMarker(_ marker: String, depth: Int, in rect: CGRect, font: PlatformFont) {
        let color = AppTheme.nativeAccent
        if marker == "•" {
            color.setFill()
            let diameter = max(4, font.pointSize * 0.34)
            let shape = CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)
            switch depth % 3 {
            case 1:
                color.setStroke()
                #if os(macOS)
                    let ring = NSBezierPath(ovalIn: shape)
                #else
                    let ring = UIBezierPath(ovalIn: shape)
                #endif
                ring.lineWidth = max(1, font.pointSize * 0.08)
                ring.stroke()
            case 2: fill(shape, radius: 0)
            default: fill(shape, radius: diameter / 2)
            }
        } else {
            let numberFont = PlatformFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: color]
            let label = ListMarkerFormatting.label(for: marker, depth: depth) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: rect.maxX - size.width, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }

    func emptyListMarkerRect(
        selection: NSRange, attributes: [NSAttributedString.Key: Any], in container: NSTextContainer
    ) -> CGRect? {
        guard let storage = textStorage, selection.length == 0,
            attributes[.yoursListMarker] is String,
            let font = attributes[.font] as? PlatformFont
        else { return nil }
        let source = storage.string as NSString
        let insertion = min(selection.location, source.length)
        let paragraph = source.paragraphRange(for: NSRange(location: insertion, length: 0))
        let line = source.substring(with: paragraph)
        let anchor = paragraph.location + line.prefix(while: { $0 == "\t" }).utf16.count
        // Tabs carry list attributes but do not provide a drawable marker anchor.
        // Only suppress the empty marker when the glyph pass can draw it itself.
        guard line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            anchor >= storage.length || storage.attribute(.yoursListMarker, at: anchor, effectiveRange: nil) == nil
        else { return nil }
        return emptyTaskMarkerRect(
            at: insertion, font: font, quoted: attributes[.yoursQuote] as? Bool == true, in: container)
    }

    func drawEmptyListMarker(selection: NSRange, attributes: [NSAttributedString.Key: Any], origin: CGPoint, in container: NSTextContainer)
    {
        guard let rect = emptyListMarkerRect(selection: selection, attributes: attributes, in: container),
            let marker = attributes[.yoursListMarker] as? String,
            let font = attributes[.font] as? PlatformFont,
            let storage = textStorage
        else { return }
        let source = storage.string as NSString
        let paragraph = source.paragraphRange(for: NSRange(location: min(selection.location, source.length), length: 0))
        drawListMarker(
            marker, depth: source.substring(with: paragraph).prefix(while: { $0 == "\t" }).count,
            in: rect.offsetBy(dx: origin.x, dy: origin.y), font: font)
    }

    private func taskMarkerRect(
        textX: CGFloat, baseline: CGFloat, font: PlatformFont,
        ascent: CGFloat, descent: CGFloat
    ) -> CGRect {
        let size = font.pointSize * DocumentTypography.taskIconScale
        let textGap = font.pointSize * DocumentTypography.taskTextGapRatio
        // Align to the font's full typographic box. Cap height biases the
        // square downward beside Chinese and mixed-script body text.
        let centerY = baseline + (descent - ascent) / 2
        return CGRect(x: textX - textGap - size, y: centerY - size / 2, width: size, height: size)
    }

    func taskMarkerCharacter(at point: CGPoint, in container: NSTextContainer) -> Int? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let glyph = glyphIndex(for: point, in: container)
        let character = min(storage.length - 1, characterIndexForGlyph(at: min(glyph, max(0, numberOfGlyphs - 1))))
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: character, length: 0))
        guard let marker = taskMarkerIndex(in: paragraph), let hitRect = taskMarkerHitRect(at: marker) else { return nil }
        return hitRect.contains(point) ? marker : nil
    }

    func taskMarkerHitRect(at character: Int) -> CGRect? {
        guard let rect = taskMarkerRect(at: character) else { return nil }
        return taskMarkerHitRect(for: rect)
    }

    func taskMarkerHitRect(for rect: CGRect) -> CGRect {
        let hitSize = max(DocumentTypography.taskIconHitSize, max(rect.width, rect.height))
        return CGRect(x: rect.midX - hitSize / 2, y: rect.midY - hitSize / 2, width: hitSize, height: hitSize)
    }

    func taskMarkerIndex(in paragraph: NSRange) -> Int? {
        guard let storage = textStorage, paragraph.location < storage.length else { return nil }
        let source = storage.string as NSString
        var marker = paragraph.location
        while marker < NSMaxRange(paragraph), source.character(at: marker) == 9 { marker += 1 }
        guard marker < storage.length,
            storage.attribute(.yoursParagraphStyle, at: marker, effectiveRange: nil) as? String == "task",
            storage.attribute(.yoursTaskChecked, at: marker, effectiveRange: nil) is Bool
        else { return nil }
        return marker
    }

    func taskMarkerAdjacent(to insertion: Int) -> Int? {
        guard let storage = textStorage, storage.length > 0, insertion >= 0, insertion <= storage.length else { return nil }
        let source = storage.string as NSString
        let probe = min(insertion, storage.length - 1)
        let paragraph = source.paragraphRange(for: NSRange(location: probe, length: 0))
        guard let marker = taskMarkerIndex(in: paragraph), insertion == marker else { return nil }
        return marker
    }

    func drawTaskMarker(checked: Bool, hovered: Bool, in rect: CGRect) {
        let borderInset = max(0.75, rect.height * DocumentTypography.taskBorderWidthRatio / 2)
        let outlineRect = rect.insetBy(dx: borderInset, dy: borderInset)
        let cornerRadius = outlineRect.height * DocumentTypography.taskCornerRadiusRatio
        let borderWidth = max(1, rect.height * DocumentTypography.taskBorderWidthRatio)
        #if os(macOS)
            let borderColor = NSColor.secondaryLabelColor
            let accentColor = AppTheme.nativeAccent
            let outline = NSBezierPath(roundedRect: outlineRect, xRadius: cornerRadius, yRadius: cornerRadius)
            (hovered ? accentColor : borderColor).setStroke()
            outline.lineWidth = borderWidth
            outline.stroke()
            guard checked else { return }
            let sizeConfiguration = NSImage.SymbolConfiguration(
                pointSize: rect.height * DocumentTypography.taskCheckScale,
                weight: .semibold,
                scale: .large
            )
            let colorConfiguration = NSImage.SymbolConfiguration(paletteColors: [accentColor])
            let configuration = sizeConfiguration.applying(colorConfiguration)
            guard let image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            else { return }
            let checkSize = rect.height * DocumentTypography.taskCheckScale
            let ratio = image.size.width / max(1, image.size.height)
            let horizontalOffset = rect.height * DocumentTypography.taskCheckHorizontalOffsetRatio
            let target = CGRect(
                x: rect.midX - checkSize * ratio / 2 + horizontalOffset, y: rect.midY - checkSize / 2, width: checkSize * ratio,
                height: checkSize)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        #else
            let borderColor = UIColor.secondaryLabel
            let accentColor = AppTheme.nativeAccent
            let outline = UIBezierPath(roundedRect: outlineRect, cornerRadius: cornerRadius)
            borderColor.setStroke()
            outline.lineWidth = borderWidth
            outline.stroke()
            guard checked else { return }
            let sizeConfiguration = UIImage.SymbolConfiguration(
                pointSize: rect.height * DocumentTypography.taskCheckScale,
                weight: .semibold,
                scale: .large
            )
            let colorConfiguration = UIImage.SymbolConfiguration(paletteColors: [accentColor])
            let configuration = sizeConfiguration.applying(colorConfiguration)
            guard let image = UIImage(systemName: "checkmark", withConfiguration: configuration) else { return }
            let checkSize = rect.height * DocumentTypography.taskCheckScale
            let ratio = image.size.width / max(1, image.size.height)
            let horizontalOffset = rect.height * DocumentTypography.taskCheckHorizontalOffsetRatio
            let target = CGRect(
                x: rect.midX - checkSize * ratio / 2 + horizontalOffset, y: rect.midY - checkSize / 2, width: checkSize * ratio,
                height: checkSize)
            image.draw(in: target)
        #endif
    }

    private func inlineCodeFontSize(forGlyphRange glyphs: NSRange) -> CGFloat {
        guard let storage = textStorage else { return DocumentTypography.bodySize * DocumentTypography.inlineCodeScale }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var size: CGFloat = 0
        storage.enumerateAttribute(.font, in: characters) { value, _, _ in
            if let font = value as? PlatformFont { size = max(size, font.pointSize) }
        }
        return size > 0 ? size : DocumentTypography.bodySize * DocumentTypography.inlineCodeScale
    }

    func inlineCodeBackgroundRects(forGlyphRange glyphs: NSRange, in container: NSTextContainer) -> [CGRect] {
        guard let storage = textStorage else { return [] }
        var result: [CGRect] = []
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
            let visible = NSIntersectionRange(glyphs, lineGlyphs)
            guard visible.length > 0 else { return }
            let characters = self.characterRange(forGlyphRange: visible, actualGlyphRange: nil)
            let text = storage.attributedSubstring(from: characters)
            let size = self.inlineCodeFontSize(forGlyphRange: visible)
            let ink = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(text), .useGlyphPathBounds)
            var above = max(0, ink.maxY)
            var below = max(0, -ink.minY)
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                guard let font = value as? PlatformFont else { return }
                // Cap height excludes the font's unused ascender space. Reserve
                // descenders consistently, and let CJK/emoji expand the surface.
                above = max(above, CTFontGetCapHeight(font as CTFont))
                below = max(below, CTFontGetDescent(font as CTFont))
            }
            let baseline = fragment.minY + self.location(forGlyphAt: visible.location).y
            self.enumerateEnclosingRects(
                forGlyphRange: visible, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                var background = CGRect(
                    x: rect.minX, y: baseline - above - size * DocumentTypography.inlineCodeBackgroundRiseRatio, width: rect.width,
                    height: above + below)
                let last = (storage.string as NSString).rangeOfComposedCharacterSequence(at: NSMaxRange(characters) - 1).location
                if storage.attribute(.yoursInlineSpacing, at: last, effectiveRange: nil) != nil {
                    let original = storage.attribute(.yoursInlineSpacing, at: last, effectiveRange: nil) as? CGFloat ?? 0
                    let current = storage.attribute(.kern, at: last, effectiveRange: nil) as? CGFloat ?? original
                    background.size.width = max(0, background.width - (current - original))
                }
                result.append(
                    background.insetBy(
                        dx: -size * DocumentTypography.inlineCodePaddingRatio, dy: -size * DocumentTypography.inlineCodeVerticalPaddingRatio
                    ))
            }
        }
        return result
    }

    func fill(_ rect: CGRect, radius: CGFloat) {
        #if os(macOS)
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        #else
            UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
        #endif
    }
}

/// Keeps the persisted SwiftUI attributes separate from the platform input system.
enum NativeTextAttributes {
    // Link decoration belongs to the view, not stored text or typing attributes.
    // The accent distinguishes links from ordinary underlines without changing stored colors or fonts.
    static var linkTextAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: AppTheme.nativeAccent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: AppTheme.nativeAccent,
        ]
    }

    // Display scaling is reversible; stored font sizes remain independent of the reading layout.
    static let readingScale = DocumentTypography.readingScale

    private static let systemChineseFamilies: Set<String> = Set(
        ["zh-Hans", "zh-Hant", "zh-HK"].compactMap { language in
            guard let system = CTFontCreateUIFontForLanguage(.system, 13, language as CFString) else { return nil }
            let fallback = CTFontCreateForString(system, "中文" as CFString, CFRange(location: 0, length: 2))
            return CTFontCopyFamilyName(fallback) as String
        })

    static func displayFont(_ font: CTFont, emphasis: Int = 0, role: String = "body", usesDocumentFont: Bool = true) -> CTFont {
        let size = CTFontGetSize(font) * readingScale
        let system = PlatformFont.systemFont(ofSize: CTFontGetSize(font)) as CTFont
        let traits = CTFontGetSymbolicTraits(font)
        let family = CTFontCopyFamilyName(font) as String
        let isSystem = family == CTFontCopyFamilyName(system) as String || systemChineseFamilies.contains(family)
        if !usesDocumentFont, !traits.contains(.traitMonoSpace) {
            let descriptor = CTFontDescriptorCreateCopyWithAttributes(
                CTFontCopyFontDescriptor(system), [kCTFontTraitsAttribute: CTFontCopyTraits(font)] as CFDictionary)
            return CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
        guard !traits.contains(.traitMonoSpace), isSystem, BundledSerifFont.isRegistered
        else { return CTFontCreateCopyWithAttributes(font, size, nil, nil) }
        let name: String
        if role.hasPrefix("heading:") {
            name = emphasis & 1 != 0 ? BundledSerifFont.heavyName : BundledSerifFont.mediumName
        } else {
            name = traits.contains(.traitBold) || emphasis & 1 != 0 ? BundledSerifFont.boldName : BundledSerifFont.lightName
        }
        // Source Han Serif has no italic face. Apply a display-only oblique matrix;
        // the original system font retains its italic and weight semantics for storage.
        var matrix =
            traits.contains(.traitItalic) || emphasis & 2 != 0 ? CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0) : .identity
        return CTFontCreateWithName(name as CFString, size, &matrix)
    }

    static func storedFont(_ font: CTFont, original: CTFont? = nil) -> CTFont {
        CTFontCreateCopyWithAttributes(original ?? font, CTFontGetSize(font) / readingScale, nil, nil)
    }

    static func setFont(
        _ font: CTFont, emphasis: Int = 0, role: String = "body", usesDocumentFont: Bool = true,
        in attributes: inout [NSAttributedString.Key: Any]
    ) {
        attributes[.font] = displayFont(font, emphasis: emphasis, role: role, usesDocumentFont: usesDocumentFont)
        // This native-only attribute travels with typing, undo and copied spans.
        // It is deliberately absent from NoteAttributeScope and removed by rich().
        attributes[.yoursStoredFont] = font
    }

    static func stableLineHeight(for font: PlatformFont) -> CGFloat {
        let sample = NSAttributedString(string: "Ag\u{4E2D}\u{6587}", attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(sample)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return ceil(max(font.pointSize * DocumentTypography.lineHeightRatio, ascent + descent + leading)) + 1
    }

    private static func paragraphRegion(in text: NSAttributedString, around affected: NSRange?) -> NSRange {
        let whole = NSRange(location: 0, length: text.length)
        guard let affected, text.length > 0 else { return whole }
        let source = text.string as NSString
        let lowerProbe = max(0, min(text.length - 1, affected.location - 1))
        let upperProbe = max(lowerProbe, min(text.length - 1, NSMaxRange(affected)))
        let lower = source.paragraphRange(for: NSRange(location: lowerProbe, length: 0)).location
        let upper = NSMaxRange(source.paragraphRange(for: NSRange(location: upperProbe, length: 0)))
        return NSRange(location: lower, length: upper - lower)
    }

    /// Refresh display-only gaps during composition without rewriting marked text
    /// or normalizing its paragraph and semantic attributes.
    static func layoutInlineCodeSpacing(_ text: NSMutableAttributedString, around affected: NSRange) {
        layoutInlineCode(text, in: paragraphRegion(in: text, around: affected))
    }

    private static func layoutInlineCode(_ text: NSMutableAttributedString, in region: NSRange) {
        text.enumerateAttribute(.yoursInlineSpacing, in: region) { previous, range, _ in
            guard let previous = previous as? CGFloat else { return }
            if previous == 0 { text.removeAttribute(.kern, range: range) } else { text.addAttribute(.kern, value: previous, range: range) }
        }
        text.removeAttribute(.yoursInlineSpacing, range: region)
        let source = text.string as NSString
        func addGap(at index: Int, amount: CGFloat) {
            guard amount > 0 else { return }
            let range = source.rangeOfComposedCharacterSequence(at: index)
            let previous = text.attribute(.kern, at: index, effectiveRange: nil) as? CGFloat ?? 0
            text.addAttributes([.kern: previous + amount, .yoursInlineSpacing: previous], range: range)
        }
        func isInline(at index: Int) -> Bool {
            index >= 0 && index < text.length && text.attribute(.yoursCodeStyle, at: index, effectiveRange: nil) as? String == "inline"
        }
        func gap(beside range: NSRange, size: CGFloat) -> CGFloat {
            let character = source.substring(with: range)
            if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 0 }
            return size * (DocumentTypography.inlineCodePaddingRatio + DocumentTypography.inlineCodeMarginRatio)
        }
        func spaceWidth(at index: Int) -> CGFloat {
            CGFloat(
                CTLineGetTypographicBounds(
                    CTLineCreateWithAttributedString(text.attributedSubstring(from: NSRange(location: index, length: 1))), nil, nil, nil))
        }
        text.enumerateAttribute(.yoursCodeStyle, in: region) { value, clippedRange, _ in
            guard value as? String == "inline", clippedRange.length > 0 else { return }
            var range = NSRange()
            _ = text.attribute(
                .yoursCodeStyle, at: clippedRange.location, longestEffectiveRange: &range,
                in: NSRange(location: 0, length: text.length))
            let size =
                (text.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont)?.pointSize ?? DocumentTypography.bodySize
                * DocumentTypography.inlineCodeScale
            if range.location > 0 {
                let previous = source.rangeOfComposedCharacterSequence(at: range.location - 1)
                if source.substring(with: previous) == " " {
                    // Count the existing space toward the visual gap. Multiple
                    // spaces, tabs and line breaks retain their authored spacing.
                    if previous.location > 0 {
                        let neighbor = source.rangeOfComposedCharacterSequence(at: previous.location - 1)
                        let neighborSize =
                            (text.attribute(.font, at: neighbor.location, effectiveRange: nil) as? PlatformFont)?.pointSize ?? size
                        let target =
                            isInline(at: neighbor.location)
                            ? (size + neighborSize) * (DocumentTypography.inlineCodePaddingRatio + DocumentTypography.inlineCodeMarginRatio)
                            : gap(beside: neighbor, size: size)
                        addGap(at: previous.location, amount: max(0, target - spaceWidth(at: previous.location)))
                    }
                } else {
                    addGap(at: previous.location, amount: gap(beside: previous, size: size))
                }
            }
            let end = NSMaxRange(range)
            if end < text.length {
                let next = source.rangeOfComposedCharacterSequence(at: end)
                let last = source.rangeOfComposedCharacterSequence(at: end - 1).location
                if source.substring(with: next) == " " {
                    if end + 1 < text.length, !isInline(at: end + 1) {
                        let neighbor = source.rangeOfComposedCharacterSequence(at: end + 1)
                        addGap(at: last, amount: max(0, gap(beside: neighbor, size: size) - spaceWidth(at: end)))
                    }
                } else {
                    addGap(at: last, amount: gap(beside: next, size: size))
                }
            }
        }
    }

    static func layoutParagraphs(_ text: NSMutableAttributedString, around affected: NSRange? = nil) {
        var counter = ListMarkerFormatting.Counter()
        let listSource = text.string as NSString
        var listLocation = 0
        while listLocation < text.length {
            let paragraph = listSource.paragraphRange(for: NSRange(location: listLocation, length: 0))
            let raw = text.attribute(.yoursListMarker, at: listLocation, effectiveRange: nil) as? String
            let depth = listSource.substring(with: paragraph).prefix(while: { $0 == "\t" }).count
            if let marker = counter.marker(raw, depth: depth), marker != raw {
                text.addAttribute(.yoursListMarker, value: marker, range: paragraph)
            }
            listLocation = NSMaxRange(paragraph)
        }
        let region = paragraphRegion(in: text, around: affected)
        layoutInlineCode(text, in: region)
        text.enumerateAttribute(.yoursQuoteColor, in: region) { value, range, _ in
            guard value != nil else { return }
            #if os(macOS)
                text.addAttribute(.foregroundColor, value: AppTheme.documentBody, range: range)
            #else
                text.addAttribute(.foregroundColor, value: AppTheme.documentBody, range: range)
            #endif
        }
        text.removeAttribute(.yoursQuoteColor, range: region)
        let source = text.string as NSString
        var location = region.location
        while location < NSMaxRange(region) {
            let range = source.paragraphRange(for: NSRange(location: location, length: 0))
            let content = source.substring(with: range).trimmingCharacters(in: .newlines)
            var font = text.attribute(.font, at: location, effectiveRange: nil) as? PlatformFont
            if text.attribute(.yoursCodeStyle, at: location, effectiveRange: nil) as? String == "inline", let inlineFont = font {
                font =
                    CTFontCreateCopyWithAttributes(
                        inlineFont as CTFont, inlineFont.pointSize / DocumentTypography.inlineCodeScale, nil, nil) as PlatformFont
            }
            let paragraph = NSMutableParagraphStyle()
            if let font {
                // Build one line box from both Latin and CJK metrics before
                // fallback glyphs arrive. The extra point keeps both scripts clear.
                let stableLineHeight = stableLineHeight(for: font)
                paragraph.minimumLineHeight = stableLineHeight
                // TextKit otherwise changes a Latin line by about half a point as
                // soon as a CJK fallback glyph appears, which visibly moves the
                // caret and following content while typing. Attachments stay
                // unconstrained because their height belongs to their content.
                var containsAttachment = false
                text.enumerateAttribute(.attachment, in: range) { value, _, stop in
                    if value != nil {
                        containsAttachment = true
                        stop.pointee = true
                    }
                }
                if !containsAttachment { paragraph.maximumLineHeight = stableLineHeight }
            }
            paragraph.lineSpacing = DocumentTypography.bodyLineSpacing
            paragraph.paragraphSpacing = DocumentTypography.bodyParagraphSpacing
            let role = text.attribute(.yoursParagraphStyle, at: location, effectiveRange: nil) as? String ?? "body"
            text.enumerateAttributes(in: range) { attributes, colorRange, _ in
                guard attributes[.yoursSyntaxColor] == nil,
                    let color = attributes[.foregroundColor] as? AppTheme.NativeColor,
                    AppTheme.isDefaultDocumentColor(color)
                else { return }
                text.addAttribute(.foregroundColor, value: AppTheme.documentText(for: role), range: colorRange)
            }
            let quoted =
                text.attribute(.yoursQuote, at: location, effectiveRange: nil) as? Bool == true
                || role == "quote" || content.hasPrefix("│ ")
            if let heading = DocumentTypography.heading(for: role) {
                paragraph.lineSpacing = heading.lineSpacing
                paragraph.paragraphSpacingBefore = location == 0 ? 0 : heading.before
                paragraph.paragraphSpacing = heading.after
            }
            if content.trimmingCharacters(in: .whitespaces).hasPrefix("• ") || ["task", "bullet", "numbered"].contains(role)
                || content.range(of: #"^\d+\. "#, options: .regularExpression) != nil
            {
                paragraph.headIndent = DocumentTypography.listIndent
                paragraph.paragraphSpacing = DocumentTypography.listSpacing
            }
            if ["task", "bullet", "numbered"].contains(role) {
                paragraph.firstLineHeadIndent = DocumentTypography.listIndent
            }
            if quoted {
                text.addAttribute(.yoursQuote, value: true, range: range)
                if content.hasPrefix("│ ") {
                    #if os(macOS)
                        text.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: location, length: 1))
                    #else
                        text.addAttribute(.foregroundColor, value: UIColor.clear, range: NSRange(location: location, length: 1))
                    #endif
                    if let font {
                        let markerLine = CTLineCreateWithAttributedString(NSAttributedString(string: "│", attributes: [.font: font]))
                        let markerWidth = CGFloat(CTLineGetTypographicBounds(markerLine, nil, nil, nil))
                        let spaceLine = CTLineCreateWithAttributedString(NSAttributedString(string: " ", attributes: [.font: font]))
                        let spaceWidth = CGFloat(CTLineGetTypographicBounds(spaceLine, nil, nil, nil))
                        text.addAttribute(.kern, value: -markerWidth, range: NSRange(location: location, length: 1))
                        text.addAttribute(.kern, value: -spaceWidth, range: NSRange(location: location + 1, length: 1))
                    }
                }
            }
            if let code = text.attribute(.yoursCodeStyle, at: location, effectiveRange: nil) as? String, code.hasPrefix("block:") {
                let previous = location > 0 ? text.attribute(.yoursCodeStyle, at: location - 1, effectiveRange: nil) as? String : nil
                let next =
                    NSMaxRange(range) < text.length
                    ? text.attribute(.yoursCodeStyle, at: NSMaxRange(range), effectiveRange: nil) as? String : nil
                paragraph.maximumLineHeight = 0
                paragraph.lineSpacing = DocumentTypography.codeLineSpacing
                paragraph.firstLineHeadIndent = DocumentTypography.codeInset
                paragraph.headIndent = DocumentTypography.codeInset
                paragraph.tailIndent = -DocumentTypography.codeInset
                paragraph.paragraphSpacingBefore = previous == code ? 0 : DocumentTypography.codeBefore
                paragraph.paragraphSpacing = next == code ? 0 : DocumentTypography.codeAfter
            }
            if quoted {
                let structured =
                    role == "task" || role == "bullet" || role == "numbered" || role == "code"
                    || MarkdownShortcut.listPrefix(content) != nil
                paragraph.firstLineHeadIndent += DocumentTypography.quoteIndent
                paragraph.headIndent += structured ? DocumentTypography.quoteIndent : DocumentTypography.quoteContinuationIndent
                if !structured { paragraph.paragraphSpacing = DocumentTypography.quoteSpacing }
                text.enumerateAttribute(.foregroundColor, in: range) { value, colorRange, _ in
                    #if os(macOS)
                        guard value == nil || (value as? NSColor).map(AppTheme.isDefaultDocumentColor) == true else { return }
                        text.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .yoursQuoteColor: true], range: colorRange)
                    #else
                        guard value == nil || (value as? UIColor).map(AppTheme.isDefaultDocumentColor) == true else { return }
                        text.addAttributes([.foregroundColor: UIColor.secondaryLabel, .yoursQuoteColor: true], range: colorRange)
                    #endif
                }
            }
            let level =
                MarkdownShortcut.listPrefix(content) == nil && !["task", "bullet", "numbered"].contains(role)
                ? 0 : content.prefix(while: { $0 == "\t" }).count
            paragraph.headIndent += CGFloat(level) * DocumentTypography.listIndent
            if text.attribute(.yoursCodeStyle, at: location, effectiveRange: nil) as? String == "inline",
                let inlineFont = text.attribute(.font, at: location, effectiveRange: nil) as? PlatformFont
            {
                // A leading inline span has no preceding character to carry its
                // inset. Reserve it through native paragraph layout instead.
                paragraph.firstLineHeadIndent +=
                    inlineFont.pointSize * (DocumentTypography.inlineCodePaddingRatio + DocumentTypography.inlineCodeMarginRatio)
            }
            // Tabs are absolute paragraph coordinates: shift their grid with the quote
            // so every nesting level advances a full list indent, including the first.
            let tabOrigin = quoted ? DocumentTypography.quoteIndent : 0
            paragraph.tabStops = (1...12).map {
                NSTextTab(textAlignment: .left, location: tabOrigin + CGFloat($0) * DocumentTypography.listIndent)
            }
            paragraph.defaultTabInterval = DocumentTypography.listIndent
            // Paragraph metrics follow their semantic role, never whether the
            // line or its neighbours currently contain text. Typing the first
            // character must not introduce margins or move subsequent content.
            text.addAttribute(.paragraphStyle, value: paragraph, range: range)
            location = NSMaxRange(range)
        }
    }

    @MainActor static func native(_ text: AttributedString, context: Font.Context, usesDocumentFont: Bool = true) -> NSAttributedString {
        let result = NSMutableAttributedString(string: String(text.characters))
        for run in text.runs {
            let range = NSRange(run.range, in: text)
            var attributes: [NSAttributedString.Key: Any] = [:]
            let emphasis = DocumentTypography.emphasis(in: run.attributes, context: context)
            let role = run[ParagraphStyleAttribute.self] ?? "body"
            let font =
                role.hasPrefix("heading:") || run[CodeStyleAttribute.self] == "inline"
                ? DocumentTypography.font(
                    for: role, emphasis: emphasis, inlineCode: run[CodeStyleAttribute.self] == "inline", context: context)
                : run.font ?? .body
            setFont(font.resolve(in: context).ctFont, emphasis: emphasis, role: role, usesDocumentFont: usesDocumentFont, in: &attributes)
            attributes[.yoursInlineEmphasis] = emphasis
            if let style = run[ParagraphStyleAttribute.self] { attributes[.yoursParagraphStyle] = style }
            if run[QuoteAttribute.self] == true { attributes[.yoursQuote] = true }
            if let marker = run[ListMarkerAttribute.self] { attributes[.yoursListMarker] = marker }
            if let checked = run[TaskStateAttribute.self] { attributes[.yoursTaskChecked] = checked }
            if let style = run[CodeStyleAttribute.self] {
                attributes[.yoursCodeStyle] = style
            } else if (run.font ?? .body).resolve(in: context).isMonospaced {
                // Compatibility with documents saved before code roles were persisted.
                attributes[.yoursCodeStyle] = run.backgroundColor == Color.secondary.opacity(0.1) ? "legacy-block" : "inline"
            }
            if let content = run[RenderedContentAttribute.self], String(text[run.range].characters) == "\u{FFFC}" {
                attributes[.yoursRenderedContent] = try? JSONEncoder().encode(content)
                attributes[.attachment] = RenderedContentAttachment(content: content)
            }
            if let table = run[TableAttribute.self], String(text[run.range].characters) == "\u{FFFC}" {
                attributes[.yoursTable] = try? JSONEncoder().encode(table)
                attributes[.attachment] = TableTextAttachment(table: table)
            }
            if let language = run[CodeLanguageAttribute.self] { attributes[.yoursCodeLanguage] = language }
            if let link = run.link { attributes[.link] = link }
            if run.underlineStyle != nil { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strikethroughStyle != nil { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            #if os(macOS)
                if run[QuoteAttribute.self] == true, run.foregroundColor == nil {
                    attributes[.foregroundColor] = NSColor.secondaryLabelColor
                    attributes[.yoursQuoteColor] = true
                } else {
                    attributes[.foregroundColor] = run.foregroundColor.map(NSColor.init) ?? AppTheme.documentText(for: role)
                }
                if let color = run.backgroundColor { attributes[.backgroundColor] = NSColor(color) }
            #else
                if run[QuoteAttribute.self] == true, run.foregroundColor == nil {
                    attributes[.foregroundColor] = UIColor.secondaryLabel
                    attributes[.yoursQuoteColor] = true
                } else {
                    attributes[.foregroundColor] = run.foregroundColor.map(UIColor.init) ?? AppTheme.documentText(for: role)
                }
                if let color = run.backgroundColor { attributes[.backgroundColor] = UIColor(color) }
            #endif
            if attributes[.yoursCodeStyle] != nil { attributes.removeValue(forKey: .backgroundColor) }
            result.setAttributes(attributes, range: range)
        }
        // Old fenced code stored only per-line fonts/backgrounds. Rejoin adjacent code paragraphs.
        let source = result.string as NSString
        var location = 0
        var blockStart: Int?
        while location < result.length {
            let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
            let content = source.substring(with: paragraph).trimmingCharacters(in: .newlines)
            let role = result.attribute(.yoursCodeStyle, at: location, effectiveRange: nil) as? String
            if role == "legacy-block", !content.isEmpty {
                let legacyBlockStart = blockStart ?? location
                blockStart = legacyBlockStart
                result.addAttribute(.yoursCodeStyle, value: "block:legacy-\(legacyBlockStart)", range: paragraph)
            } else {
                blockStart = nil
            }
            location = NSMaxRange(paragraph)
        }
        layoutParagraphs(result)
        highlightCode(result)
        return result
    }

    static func highlightCode(_ text: NSMutableAttributedString, around affected: NSRange? = nil) {
        var region = paragraphRegion(in: text, around: affected)
        let whole = NSRange(location: 0, length: text.length)
        if region.length > 0 {
            text.enumerateAttribute(.yoursCodeStyle, in: region) { value, clippedRange, _ in
                guard let id = value as? String, id.hasPrefix("block:") || id == "inline" else { return }
                var effective = NSRange()
                _ = text.attribute(.yoursCodeStyle, at: clippedRange.location, longestEffectiveRange: &effective, in: whole)
                region = NSUnionRange(region, effective)
            }
        }
        #if os(macOS)
            let base = NSColor.textColor
            let inlineColor = NSColor.textColor
        #else
            let base = UIColor.label
            let inlineColor = UIColor.label
        #endif
        text.enumerateAttribute(.yoursSyntaxColor, in: region) { marker, range, _ in
            if marker != nil { text.addAttribute(.foregroundColor, value: base, range: range) }
        }
        text.removeAttribute(.yoursSyntaxColor, range: region)
        text.enumerateAttribute(.yoursCodeStyle, in: region) { value, clippedRange, _ in
            var range = NSRange()
            _ = text.attribute(.yoursCodeStyle, at: clippedRange.location, longestEffectiveRange: &range, in: whole)
            if value as? String == "inline" {
                text.enumerateAttribute(.foregroundColor, in: range) { color, span, _ in
                    #if os(macOS)
                        let isDefault = color as? NSColor == base
                    #else
                        let isDefault = color as? UIColor == base
                    #endif
                    if isDefault {
                        text.addAttributes([.foregroundColor: inlineColor, .yoursSyntaxColor: true], range: span)
                    }
                }
            }
            guard let id = value as? String, id.hasPrefix("block:") else { return }
            let language = text.attribute(.yoursCodeLanguage, at: range.location, effectiveRange: nil) as? String ?? ""
            let literal = (text.string as NSString).substring(with: range)
            for token in CodeBlockEditing.tokens(source: literal, language: language) {
                #if os(macOS)
                    let color: NSColor
                #else
                    let color: UIColor
                #endif
                switch token.kind {
                case .keyword: color = .systemPurple
                case .string: color = .systemBrown
                case .number: color = .systemBlue
                case .comment: color = .systemGray
                }
                text.addAttributes(
                    [.foregroundColor: color, .yoursSyntaxColor: true],
                    range: NSRange(location: range.location + token.range.location, length: token.range.length))
            }
        }
    }

    static func rich(_ text: NSAttributedString) -> AttributedString {
        var result = AttributedString(text.string)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, nsRange, _ in
            guard let range = Range<AttributedString.Index>(nsRange, in: result) else { return }
            if let encoded = attributes[.yoursRenderedContent] as? Data,
                text.attributedSubstring(from: nsRange).string == "\u{FFFC}",
                let content = try? JSONDecoder().decode(RenderedContent.self, from: encoded)
            {
                result[range][RenderedContentAttribute.self] = content
            }
            if let encoded = attributes[.yoursTable] as? Data,
                text.attributedSubstring(from: nsRange).string == "\u{FFFC}",
                let table = try? JSONDecoder().decode(TableData.self, from: encoded)
            {
                result[range][TableAttribute.self] = table
            }
            if let emphasis = attributes[.yoursInlineEmphasis] as? Int { result[range][InlineEmphasisAttribute.self] = emphasis }
            if let language = attributes[.yoursCodeLanguage] as? String { result[range][CodeLanguageAttribute.self] = language }
            if let style = attributes[.yoursParagraphStyle] as? String { result[range][ParagraphStyleAttribute.self] = style }
            if attributes[.yoursQuote] as? Bool == true { result[range][QuoteAttribute.self] = true }
            if let marker = attributes[.yoursListMarker] as? String { result[range][ListMarkerAttribute.self] = marker }
            if let checked = attributes[.yoursTaskChecked] as? Bool { result[range][TaskStateAttribute.self] = checked }
            if let style = attributes[.yoursCodeStyle] as? String { result[range][CodeStyleAttribute.self] = style }
            if let font = attributes[.font] as? PlatformFont {
                let original = (attributes[.yoursStoredFont] as? PlatformFont).map { $0 as CTFont }
                let stored = storedFont(font as CTFont, original: original)
                let name = CTFontCopyPostScriptName(stored) as String
                result[range].font = name.hasPrefix("SourceHanSerif") ? .custom(name, fixedSize: CTFontGetSize(stored)) : Font(stored)
            }
            if let link = attributes[.link] as? URL {
                result[range].link = link
            } else if let link = attributes[.link] as? String {
                result[range].link = URL(string: link)
            }
            if let style = attributes[.underlineStyle] as? Int, style != 0 { result[range].underlineStyle = .single }
            if let style = attributes[.strikethroughStyle] as? Int, style != 0 { result[range].strikethroughStyle = .single }
            #if os(macOS)
                if let color = attributes[.foregroundColor] as? NSColor, !AppTheme.isDefaultDocumentColor(color), color != .clear,
                    attributes[.yoursSyntaxColor] == nil, attributes[.yoursQuoteColor] == nil
                {
                    result[range].foregroundColor = Color(nsColor: color)
                }
                if let color = attributes[.backgroundColor] as? NSColor { result[range].backgroundColor = Color(nsColor: color) }
            #else
                if let color = attributes[.foregroundColor] as? UIColor, !AppTheme.isDefaultDocumentColor(color), color != .clear,
                    attributes[.yoursSyntaxColor] == nil, attributes[.yoursQuoteColor] == nil
                {
                    result[range].foregroundColor = Color(uiColor: color)
                }
                if let color = attributes[.backgroundColor] as? UIColor { result[range].backgroundColor = Color(uiColor: color) }
            #endif
        }
        return result
    }
}

#if os(macOS)
    /// AppKit drives progress on the main run loop; the weak reference avoids retaining an editor.
    private final class LinkHoverAnimation: NSAnimation {
        weak var layout: CodeLayoutManager?
        override var currentProgress: NSAnimation.Progress {
            didSet { layout?.updateLinkHoverAnimation(progress: CGFloat(currentValue)) }
        }
    }
#endif

/// Timer retains this proxy, never the editor or its layout manager.
private final class CodeIndicatorClock: NSObject {
    weak var layout: CodeLayoutManager?
    @objc func tick(_ timer: Timer) {
        guard let layout else {
            timer.invalidate()
            return
        }
        layout.updateCodeIndicators()
    }
}
