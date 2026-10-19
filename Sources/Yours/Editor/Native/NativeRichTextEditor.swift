import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@MainActor
struct NativeRichTextEditor {
    @Binding var text: AttributedString
    @Binding var selection: AttributedTextSelection
    var commandBridge: EditorCommandBridge?
    var documentID: UUID?
    var focusWhenEmpty = true
    var focusRequest = 0
    var onEditLink: () -> Void = {}
    var onToast: (ToastMessage) -> Void = { _ in }
    @Environment(\.fontResolutionContext) private var fontContext

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: NativeRichTextEditor
        private var lastValue: AttributedString
        private var lastNativeValue = NSAttributedString()
        fileprivate var isUpdating = false
        private var locallyAppliedTypingAttributes: [NSAttributedString.Key: Any]?
        private var pendingTypingAttributesAfterInlineDeletion: [NSAttributedString.Key: Any]?
        private var pendingNativeEditRange: NSRange?
        private var handledFocusRequest: Int
        weak var textView: PlatformTextView?
        private let inputFeatures = EditorFeatureRegistry()
        private let controls = NativeEditorControls()
        private var slashAnchor: Int?
        private var pendingSlash = false
        var suppressSlashTrigger = false
        private var controlsSuppressed = false
        private var revision = 0
        private var controlsTargetRange = NSRange(location: 0, length: 0)
        private let tables = TableOverlayController()
        private let renderedContents = RenderedContentOverlayController()
        private let codeHeaders = CodeHeaderOverlayController()

        init(parent: NativeRichTextEditor) {
            self.parent = parent
            lastValue = parent.text
            handledFocusRequest = 0
        }

        fileprivate var storage: NSTextStorage? {
            #if os(macOS)
                textView?.textStorage
            #else
                textView?.textStorage
            #endif
        }

        fileprivate var currentSelection: NSRange {
            #if os(macOS)
                textView?.selectedRange() ?? NSRange(location: 0, length: 0)
            #else
                textView?.selectedRange ?? NSRange(location: 0, length: 0)
            #endif
        }

        /// Tab indentation belongs to the list layout, never an insertion position.
        func clampedListCaret(_ range: NSRange) -> NSRange {
            guard range.length == 0, let storage, range.location <= storage.length, !hasMarkedText else { return range }
            let source = storage.string as NSString
            let paragraph = source.paragraphRange(for: range)
            guard paragraph.location < storage.length,
                ["bullet", "numbered", "task"].contains(
                    storage.attribute(.yoursParagraphStyle, at: paragraph.location, effectiveRange: nil) as? String ?? "")
            else { return range }
            let depth = source.substring(with: paragraph).prefix(while: { $0 == "\t" }).utf16.count
            return NSRange(location: max(range.location, paragraph.location + depth), length: 0)
        }

        func moveLeftFromListStart() -> Bool {
            guard !hasMarkedText, let storage, currentSelection.length == 0 else { return false }
            let source = storage.string as NSString
            let paragraph = source.paragraphRange(for: currentSelection)
            let start = clampedListCaret(NSRange(location: paragraph.location, length: 0))
            guard start.location > paragraph.location, currentSelection == start else { return false }
            setSelection(NSRange(location: max(0, paragraph.location - 1), length: 0))
            publishSelection()
            return true
        }

        private func setSelection(_ proposed: NSRange) {
            let range = clampedListCaret(proposed)
            #if os(macOS)
                textView?.setSelectedRange(range)
            #else
                textView?.selectedRange = range
            #endif
        }

        fileprivate var hasMarkedText: Bool {
            #if os(macOS)
                textView?.hasMarkedText() ?? false
            #else
                textView?.markedTextRange != nil
            #endif
        }

        func update(_ parent: NativeRichTextEditor) {
            if parent.documentID != self.parent.documentID {
                revision += 1
                dismissControls()
            }
            self.parent = parent
            guard let textView, !hasMarkedText else { return }
            isUpdating = true
            defer {
                isUpdating = false
                refreshTables()
            }
            if parent.text != lastValue {
                #if os(macOS)
                    (textView as? ReadingMacTextView)?.discardInlineCodeBoundary()
                #endif
                revision += 1
                dismissControls()
                #if os(macOS)
                    (textView.layoutManager as? CodeLayoutManager)?.clearLinkHover()
                #endif
                storage?.setAttributedString(NativeTextAttributes.native(parent.text, context: parent.fontContext))
                lastValue = parent.text
            }
            var range: NSRange
            switch parent.selection.indices(in: parent.text) {
            case .insertionPoint(let index): range = NSRange(index..<index, in: parent.text)
            case .ranges(let ranges):
                guard let first = ranges.ranges.first else { return }
                range = NSRange(first, in: parent.text)
            }
            range = clampedListCaret(range)
            if NSMaxRange(range) <= (storage?.length ?? 0), range != currentSelection { setSelection(range) }
            let attributes = parent.selection.typingAttributes(in: parent.text)
            let source = (storage?.string ?? "") as NSString
            let paragraphRange = source.paragraphRange(for: NSRange(location: min(range.location, source.length), length: 0))
            let isBlank = source.substring(with: paragraphRange).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let sample = NativeTextAttributes.native(
                AttributedString(isBlank ? "\n" : " ", attributes: attributes), context: parent.fontContext)
            var nativeAttributes = sample.attributes(at: 0, effectiveRange: nil)
            // A synthetic space has body margins. Reuse the actual paragraph's
            // layout when restoring typing state so clicking cannot change its height.
            if let storage, paragraphRange.location < storage.length,
                storage.attribute(.yoursParagraphStyle, at: paragraphRange.location, effectiveRange: nil) as? String == nativeAttributes[
                    .yoursParagraphStyle] as? String,
                storage.attribute(.yoursCodeStyle, at: paragraphRange.location, effectiveRange: nil) as? String == nativeAttributes[
                    .yoursCodeStyle] as? String
            {
                nativeAttributes[.paragraphStyle] = storage.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil)
            }
            nativeAttributes = positionedHeadingTypingAttributes(nativeAttributes, at: range.location, in: source as String)
            nativeAttributes.removeValue(forKey: .attachment)
            nativeAttributes.removeValue(forKey: .yoursRenderedContent)
            nativeAttributes.removeValue(forKey: .yoursTable)
            let localAttributes = locallyAppliedTypingAttributes
            locallyAppliedTypingAttributes = nil
            if let localAttributes, parent.text == lastValue, range == currentSelection {
                // `text` and `selection` are separate bindings. SwiftUI can update
                // the representable after the text write but before the matching
                // selection typing state arrives. Keep the attributes from the
                // native edit for that one intermediate update.
                textView.typingAttributes = localAttributes
            } else {
                textView.typingAttributes = nativeAttributes
            }
            #if os(macOS)
                (textView as? ReadingMacTextView)?.restoreInlineCodeBoundaryTyping()
                (textView as? ReadingMacTextView)?.updateEmptyQuoteBar()
            #endif
            if let storage { lastNativeValue = NSAttributedString(attributedString: storage) }
            if parent.focusRequest != handledFocusRequest {
                handledFocusRequest = parent.focusRequest
                DispatchQueue.main.async { [weak textView] in
                    #if os(macOS)
                        textView?.window?.makeFirstResponder(textView)
                    #else
                        textView?.becomeFirstResponder()
                    #endif
                }
            }
        }

        fileprivate func publish(around affected: NSRange? = nil) {
            guard !isUpdating, let storage else { return }
            if !hasMarkedText {
                isUpdating = true
                NativeTextAttributes.layoutParagraphs(storage, around: affected)
                // Indenting an empty numbered item normalizes its stored number.
                // Keep the synthetic marker's typing state on that same number.
                if currentSelection.length == 0 {
                    let paragraph = (storage.string as NSString).paragraphRange(for: currentSelection)
                    if paragraph.location < storage.length,
                        let marker = storage.attribute(.yoursListMarker, at: paragraph.location, effectiveRange: nil) as? String
                    {
                        textView?.typingAttributes[.yoursListMarker] = marker
                        locallyAppliedTypingAttributes?[.yoursListMarker] = marker
                    }
                }
                NativeTextAttributes.highlightCode(storage, around: affected)
                isUpdating = false
            }
            revision += 1
            let value = NativeTextAttributes.rich(storage)
            lastValue = value
            parent.text = value
            publishSelection(in: value)
            lastNativeValue = NSAttributedString(attributedString: storage)
            refreshTables()
        }

        fileprivate func publishSelection(in value: AttributedString? = nil) {
            guard !isUpdating, !hasMarkedText, let textView else { return }
            let corrected = clampedListCaret(currentSelection)
            if corrected != currentSelection {
                isUpdating = true
                setSelection(corrected)
                isUpdating = false
            }
            if currentSelection.length == 0, let layout = textView.layoutManager as? CodeLayoutManager {
                #if os(macOS)
                    if let container = textView.textContainer { layout.revealCodeCaret(at: currentSelection.location, in: container) }
                #else
                    layout.revealCodeCaret(at: currentSelection.location, in: textView.textContainer)
                #endif
            }
            renderedContents.updateSelection(in: textView)
            #if os(macOS)
                renderedContents.updateSelectionEmphasis(textView.window?.firstResponder === textView)
            #endif
            let text = value ?? parent.text
            guard let range = Range<AttributedString.Index>(currentSelection, in: text) else { return }
            if range.isEmpty {
                let sample = NativeTextAttributes.rich(NSAttributedString(string: " ", attributes: textView.typingAttributes))
                parent.selection = AttributedTextSelection(
                    insertionPoint: range.lowerBound, typingAttributes: sample.runs.first?.attributes)
            } else {
                parent.selection = AttributedTextSelection(range: range)
            }
        }

        fileprivate func refreshTables() {
            guard let textView else { return }
            renderedContents.refresh(in: textView) { [weak self] original, source in
                self?.changeRenderedContent(original: original, source: source)
            }
            codeHeaders.refresh(
                in: textView,
                onLanguage: { [weak self] id, language in
                    self?.changeCodeLanguage(id: id, language: language)
                },
                onFormat: { [weak self] id in
                    try await self?.formatCode(id: id)
                },
                onToast: { [weak self] message in self?.parent.onToast(message) })
            tables.refresh(
                in: textView,
                onChange: { [weak self] id, table in
                    self?.changeTable(id: id, table: table)
                },
                onExit: { [weak self] index in
                    // Let SwiftUI resign the cell before restoring the document responder.
                    DispatchQueue.main.async { [weak self] in self?.exitTable(at: index) }
                })
        }

        func changeCodeLanguage(id: String, language: String) {
            guard !hasMarkedText, let storage, let view = textView else { return }
            var target: NSRange?
            storage.enumerateAttribute(.yoursCodeStyle, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if value as? String == id {
                    target = range
                    stop.pointee = true
                }
            }
            guard let target,
                storage.attribute(.yoursCodeLanguage, at: target.location, effectiveRange: nil) as? String != language
            else { return }
            registerUndo(
                text: NSAttributedString(attributedString: storage), selection: currentSelection, attributes: view.typingAttributes)
            let next = NSMutableAttributedString(attributedString: storage)
            next.addAttribute(.yoursCodeLanguage, value: language, range: target)
            var attributes = view.typingAttributes
            if attributes[.yoursCodeStyle] as? String == id { attributes[.yoursCodeLanguage] = language }
            apply(text: next, selection: currentSelection, attributes: attributes)
        }

        private func codeRange(id: String, in storage: NSTextStorage) -> NSRange? {
            var target: NSRange?
            storage.enumerateAttribute(.yoursCodeStyle, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if value as? String == id {
                    target = range
                    stop.pointee = true
                }
            }
            return target
        }

        func formatCode(id: String) async throws {
            guard !hasMarkedText, let storage, let target = codeRange(id: id, in: storage) else {
                throw CodeFormatting.Failure.changed
            }
            let snapshot = storage.attributedSubstring(from: target)
            let language = storage.attribute(.yoursCodeLanguage, at: target.location, effectiveRange: nil) as? String ?? ""
            let formatted = try await CodeFormatting.shared.format(snapshot.string, language: language)
            try Task.checkCancellation()
            guard self.storage === storage else { throw CodeFormatting.Failure.changed }
            try applyFormattedCode(formatted, id: id, snapshot: snapshot)
        }

        func applyFormattedCode(_ formatted: String, id: String, snapshot: NSAttributedString) throws {
            guard !hasMarkedText, let view = textView, let current = storage,
                let target = codeRange(id: id, in: current),
                current.attributedSubstring(from: target).isEqual(to: snapshot)
            else { throw CodeFormatting.Failure.changed }
            guard formatted != snapshot.string, !formatted.isEmpty else { return }

            let before = currentSelection
            let attributes = view.typingAttributes
            registerUndo(text: NSAttributedString(attributedString: current), selection: before, attributes: attributes)
            let next = NSMutableAttributedString(attributedString: current)
            let blockAttributes = current.attributes(at: target.location, effectiveRange: nil)
            next.replaceCharacters(in: target, with: NSAttributedString(string: formatted, attributes: blockAttributes))
            let length = (formatted as NSString).length
            func shifted(_ offset: Int) -> Int {
                if offset <= target.location { return offset }
                if offset >= NSMaxRange(target) { return offset + length - target.length }
                let relative = min(offset - target.location, length)
                guard relative < length else { return target.location + length }
                // Never leave the caret halfway through an emoji or composed character.
                return target.location + (formatted as NSString).rangeOfComposedCharacterSequence(at: relative).location
            }
            let start = shifted(before.location)
            let end = shifted(NSMaxRange(before))
            apply(text: next, selection: NSRange(location: start, length: max(0, end - start)), attributes: attributes)
            view.undoManager?.setActionName(L10n.string("code.format"))
        }

        private func exitTable(at index: Int) {
            guard let view = textView, let storage else { return }
            let offset = min(index, storage.length)
            var sample = AttributedString("\n")
            sample.font = .body
            sample[ParagraphStyleAttribute.self] = "body"
            let native = NativeTextAttributes.native(sample, context: parent.fontContext)
            let attributes = native.attributes(at: 0, effectiveRange: nil)
            if offset == storage.length || (storage.string as NSString).substring(with: NSRange(location: offset, length: 1)) != "\n" {
                registerUndo(
                    text: NSAttributedString(attributedString: storage), selection: currentSelection, attributes: view.typingAttributes)
                let next = NSMutableAttributedString(attributedString: storage)
                next.insert(native, at: offset)
                apply(text: next, selection: NSRange(location: offset + 1, length: 0), attributes: attributes)
            }
            isUpdating = true
            setSelection(NSRange(location: min(offset + 1, storage.length), length: 0))
            view.typingAttributes = attributes
            #if os(macOS)
                view.window?.makeFirstResponder(view)
            #else
                view.becomeFirstResponder()
            #endif
            isUpdating = false
            publishSelection()
        }

        func backspaceAtParagraphStart() -> Bool {
            guard !hasMarkedText, let storage, let view = textView, currentSelection.length == 0 else { return false }
            let paragraph = (storage.string as NSString).paragraphRange(for: currentSelection)
            let line = (storage.string as NSString).substring(with: paragraph)
            let quoted =
                paragraph.location < storage.length
                ? storage.attribute(.yoursQuote, at: paragraph.location, effectiveRange: nil) as? Bool == true
                : view.typingAttributes[.yoursQuote] as? Bool == true
            if quoted, currentSelection.location == paragraph.location,
                line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                var body = AttributedString(" ")
                body.font = .body
                body[ParagraphStyleAttribute.self] = "body"
                let attributes = NativeTextAttributes.native(body, context: parent.fontContext).attributes(at: 0, effectiveRange: nil)
                let next = NSMutableAttributedString(attributedString: storage)
                next.setAttributes(attributes, range: paragraph)
                registerUndo(
                    text: NSAttributedString(attributedString: storage), selection: currentSelection, attributes: view.typingAttributes)
                apply(text: next, selection: currentSelection, attributes: attributes)
                view.undoManager?.setActionName(L10n.string("quote.exit"))
                return true
            }
            let role =
                paragraph.location < storage.length
                ? storage.attribute(.yoursParagraphStyle, at: paragraph.location, effectiveRange: nil) as? String
                : view.typingAttributes[.yoursParagraphStyle] as? String
            guard ["bullet", "numbered", "task"].contains(role ?? "") || role?.hasPrefix("heading:") == true,
                currentSelection.location == paragraph.location + line.prefix(while: { $0 == "\t" }).utf16.count
            else {
                return false
            }
            return !intercept(range: currentSelection, replacement: "")
        }

        func copyStructured(cut: Bool) -> Bool {
            guard !hasMarkedText, let storage, let view = textView, currentSelection.length > 0 else { return false }
            let range = currentSelection
            let selected = NativeTextAttributes.rich(storage.attributedSubstring(from: range))
            let hasTable = selected.runs.contains {
                $0[TableAttribute.self] != nil || $0[ListMarkerAttribute.self] != nil || $0[RenderedContentAttribute.self] != nil
            }
            guard let encoded = try? RichTextClipboard.encode(selected) else {
                #if os(macOS)
                    NSSound.beep()
                #endif
                return true  // Never fall back to a lossy cut of a structured block.
            }
            let plain = hasTable ? MarkdownFormatting.serialize(selected, context: parent.fontContext) : String(selected.characters)
            let nativeSelection = storage.attributedSubstring(from: range)
            let richTextData = try? nativeSelection.data(
                from: NSRange(location: 0, length: nativeSelection.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(encoded, forType: NSPasteboard.PasteboardType("app.yours.richtext"))
                if let richTextData { NSPasteboard.general.setData(richTextData, forType: .rtf) }
                NSPasteboard.general.setString(plain, forType: .string)
            #else
                var item: [String: Any] = ["app.yours.richtext": encoded, "public.utf8-plain-text": plain]
                if let richTextData { item["public.rtf"] = richTextData }
                UIPasteboard.general.setItems([item])
            #endif
            if cut {
                registerUndo(text: NSAttributedString(attributedString: storage), selection: range, attributes: view.typingAttributes)
                let next = NSMutableAttributedString(attributedString: storage)
                next.deleteCharacters(in: range)
                var body = AttributedString(" ")
                body.font = .body
                body[ParagraphStyleAttribute.self] = "body"
                let attributes = NativeTextAttributes.native(body, context: parent.fontContext).attributes(at: 0, effectiveRange: nil)
                let originalParagraph = (storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
                let remainingParagraph = (next.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
                if range.location == originalParagraph.location, NSMaxRange(range) > NSMaxRange(originalParagraph),
                    (next.string as NSString).substring(with: remainingParagraph).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    // A trailing paragraph terminator belongs to the removed content,
                    // not to the new empty body paragraph left by a multi-paragraph cut.
                    next.setAttributes(attributes, range: remainingParagraph)
                }
                apply(text: next, selection: NSRange(location: range.location, length: 0), attributes: attributes)
                view.undoManager?.setActionName(L10n.string("edit.cut"))
            }
            return true
        }

        func pasteStructured() -> Bool {
            dismissControls()
            #if os(macOS)
                let pasteboard = NSPasteboard.general
                let encoded = pasteboard.data(forType: NSPasteboard.PasteboardType("app.yours.richtext"))
                let plainText = pasteboard.string(forType: .string)
                let hasRichText = pasteboard.availableType(from: [.rtf, .rtfd, .html]) != nil
            #else
                let pasteboard = UIPasteboard.general
                let encoded = pasteboard.data(forPasteboardType: "app.yours.richtext")
                let plainText = pasteboard.string
                let hasRichText = pasteboard.contains(pasteboardTypes: ["public.rtf", "com.apple.flat-rtfd", "public.html"])
            #endif
            var richText: NSAttributedString?
            if encoded == nil, hasRichText, plainText?.contains("$") == true {
                #if os(macOS)
                    richText = pasteboard.readObjects(forClasses: [NSAttributedString.self], options: nil)?.first as? NSAttributedString
                #else
                    for (type, format) in [("public.rtf", NSAttributedString.DocumentType.rtf), ("public.html", .html)] {
                        if let data = pasteboard.data(forPasteboardType: type) {
                            richText = try? NSAttributedString(data: data, options: [.documentType: format], documentAttributes: nil)
                            if richText != nil { break }
                        }
                    }
                #endif
            }
            return pasteContent(encoded: encoded, plainText: plainText, hasRichText: hasRichText, richText: richText)
        }

        func pasteContent(encoded: Data?, plainText: String?, hasRichText: Bool, richText: NSAttributedString? = nil) -> Bool {
            guard !hasMarkedText, let storage, let view = textView,
                view.typingAttributes[.yoursCodeStyle] == nil
            else { return false }
            var text: AttributedString
            var nativeFormulas: NSAttributedString?
            if let encoded, let decoded = try? RichTextClipboard.decode(encoded) {
                text = decoded
            } else if let richText, let converted = RichTextClipboard.renderFormulas(in: richText, context: parent.fontContext) {
                nativeFormulas = converted
                text = NativeTextAttributes.rich(converted)
            } else if let plainText, let markdown = RichTextClipboard.renderMarkdown(plainText, hasRichText: hasRichText) {
                text = markdown
            } else {
                return false
            }
            let range = currentSelection
            // Block objects must not share their paragraph with surrounding prose.
            var boundary = AttributedString("\n")
            boundary.font = .body
            boundary[ParagraphStyleAttribute.self] = "body"
            let existing = storage.string as NSString
            if text.runs.first?[RenderedContentAttribute.self]?.isBlock == true,
                range.location > 0, existing.substring(with: NSRange(location: range.location - 1, length: 1)) != "\n"
            {
                text = boundary + text
                if let native = nativeFormulas {
                    let prefixed = NSMutableAttributedString(
                        attributedString: NativeTextAttributes.native(boundary, context: parent.fontContext))
                    prefixed.append(native)
                    nativeFormulas = prefixed
                }
            }
            if text.runs.last?[RenderedContentAttribute.self]?.isBlock == true,
                NSMaxRange(range) == storage.length || existing.substring(with: NSRange(location: NSMaxRange(range), length: 1)) != "\n"
            {
                text += boundary
                if let native = nativeFormulas {
                    let suffixed = NSMutableAttributedString(attributedString: native)
                    suffixed.append(NativeTextAttributes.native(boundary, context: parent.fontContext))
                    nativeFormulas = suffixed
                }
            }
            let inserted = nativeFormulas ?? NativeTextAttributes.native(text, context: parent.fontContext)
            registerUndo(text: NSAttributedString(attributedString: storage), selection: range, attributes: view.typingAttributes)
            let next = NSMutableAttributedString(attributedString: storage)
            next.replaceCharacters(in: range, with: inserted)
            var body = AttributedString(" ")
            body.font = .body
            body[ParagraphStyleAttribute.self] = "body"
            let attributes = NativeTextAttributes.native(body, context: parent.fontContext).attributes(at: 0, effectiveRange: nil)
            apply(text: next, selection: NSRange(location: range.location + inserted.length, length: 0), attributes: attributes)
            view.undoManager?.setActionName(L10n.string("edit.paste"))
            return true
        }

        func changeRenderedContent(original: RenderedContent, source: String) {
            guard !hasMarkedText, source != original.source, let storage, let view = textView else { return }
            var target: NSRange?
            storage.enumerateAttribute(.yoursRenderedContent, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if let data = value as? Data, (try? JSONDecoder().decode(RenderedContent.self, from: data)) == original {
                    target = range
                    stop.pointee = true
                }
            }
            guard let target, target.length == 1 else { return }
            registerUndo(
                text: NSAttributedString(attributedString: storage), selection: currentSelection, attributes: view.typingAttributes)
            var content = original
            content.source = source
            guard let encoded = try? JSONEncoder().encode(content) else { return }
            let next = NSMutableAttributedString(attributedString: storage)
            next.addAttribute(.yoursRenderedContent, value: encoded, range: target)
            next.addAttribute(.attachment, value: RenderedContentAttachment(content: content), range: target)
            var body = AttributedString(" ")
            body.font = .body
            let attributes = NativeTextAttributes.native(body, context: parent.fontContext).attributes(at: 0, effectiveRange: nil)
            apply(text: next, selection: NSRange(location: NSMaxRange(target), length: 0), attributes: attributes)
        }

        func changeTable(id: UUID, table: TableData) {
            guard let storage, let view = textView else { return }
            var target: NSRange?
            storage.enumerateAttribute(.yoursTable, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
                if let encoded = value as? Data, let current = try? JSONDecoder().decode(TableData.self, from: encoded), current.id == id {
                    target = range
                    stop.pointee = true
                }
            }
            guard let target, let encoded = try? JSONEncoder().encode(table),
                storage.attribute(.yoursTable, at: target.location, effectiveRange: nil) as? Data != encoded
            else { return }
            registerUndo(
                text: NSAttributedString(attributedString: storage), selection: currentSelection, attributes: view.typingAttributes)
            isUpdating = true
            storage.addAttributes([.yoursTable: encoded, .attachment: TableTextAttachment(table: table)], range: target)
            isUpdating = false
            publish()
            view.undoManager?.setActionName(L10n.string("table.edit"))
        }

        func intercept(range: NSRange, replacement: String?) -> Bool {
            guard !isUpdating, !hasMarkedText, let textView, let storage, let replacement,
                textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true
            else { return true }
            if !suppressSlashTrigger, replacement == "/", range.length == 0 { pendingSlash = true }
            if slashAnchor != nil, replacement == "\n" { return !handleControlKey("return") }
            textView.typingAttributes.removeValue(forKey: .attachment)
            textView.typingAttributes.removeValue(forKey: .yoursRenderedContent)
            textView.typingAttributes.removeValue(forKey: .yoursTable)
            let context = EditorInputContext(
                storage: storage,
                typingAttributes: textView.typingAttributes,
                range: range,
                replacement: replacement,
                selection: currentSelection)
            guard let command = inputFeatures.command(for: context) else {
                if replacement.isEmpty, range.length > 0 {
                    prepareTypingAttributesAfterInlineDeletion(range)
                }
                let changed = NSRange(location: range.location, length: max(range.length, replacement.utf16.count))
                pendingNativeEditRange = pendingNativeEditRange.map { NSUnionRange($0, changed) } ?? changed
                return true
            }
            return execute(command, context: context, storage: storage, textView: textView)
        }

        private func execute(
            _ command: EditorInputCommand,
            context: EditorInputContext,
            storage: NSTextStorage,
            textView: PlatformTextView
        ) -> Bool {
            switch command {
            case .applyLink(let url):
                registerUndo(
                    text: NSAttributedString(attributedString: storage),
                    selection: context.selection,
                    attributes: textView.typingAttributes)
                let updated = NSMutableAttributedString(attributedString: storage)
                updated.addAttribute(.link, value: url, range: context.range)
                apply(text: updated, selection: context.range, attributes: textView.typingAttributes)
            case .preserveEmptyQuote:
                preserveEmptyQuote(context: context, storage: storage, textView: textView)
            case .indentCode(let outdent):
                applyCodeIndent(outdent: outdent, context: context, storage: storage, textView: textView)
            case .continueCodeLine(let prefix):
                continueCodeLine(prefix: prefix, context: context, storage: storage, textView: textView)
            case .edit(let edit, let origin):
                apply(edit: edit, origin: origin, context: context, storage: storage, textView: textView)
            case .consume:
                break
            }
            return false
        }

        private func preserveEmptyQuote(
            context: EditorInputContext,
            storage: NSTextStorage,
            textView: PlatformTextView
        ) {
            registerUndo(
                text: NSAttributedString(attributedString: storage),
                selection: context.selection,
                attributes: textView.typingAttributes)
            let next = NSMutableAttributedString(attributedString: storage)
            next.deleteCharacters(in: context.range)
            var attributes = textView.typingAttributes
            attributes[.yoursQuote] = true
            #if os(macOS)
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
            #else
                attributes[.foregroundColor] = UIColor.secondaryLabel
            #endif
            attributes[.yoursQuoteColor] = true
            apply(text: next, selection: NSRange(location: context.range.location, length: 0), attributes: attributes)
        }

        private func applyCodeIndent(
            outdent: Bool,
            context: EditorInputContext,
            storage: NSTextStorage,
            textView: PlatformTextView
        ) {
            var value = NativeTextAttributes.rich(storage)
            guard let selected = Range<AttributedString.Index>(context.selection, in: value) else { return }
            var selection =
                selected.isEmpty
                ? AttributedTextSelection(insertionPoint: selected.lowerBound)
                : AttributedTextSelection(range: selected)
            if CodeBlockEditing.indent(in: &value, selection: &selection, outdent: outdent) {
                registerUndo(
                    text: NSAttributedString(attributedString: storage),
                    selection: context.selection,
                    attributes: textView.typingAttributes)
                let after: NSRange
                switch selection.indices(in: value) {
                case .insertionPoint(let point): after = NSRange(point..<point, in: value)
                case .ranges(let ranges): after = ranges.ranges.first.map { NSRange($0, in: value) } ?? context.selection
                }
                apply(
                    text: NativeTextAttributes.native(value, context: parent.fontContext),
                    selection: after,
                    attributes: textView.typingAttributes)
                textView.undoManager?.setActionName(L10n.string("code.indent"))
                return
            }
            // A newly created empty code block exists only in typing attributes.
            guard !outdent, context.selection.length == 0 else { return }
            registerUndo(
                text: NSAttributedString(attributedString: storage),
                selection: context.selection,
                attributes: textView.typingAttributes)
            let next = NSMutableAttributedString(attributedString: storage)
            next.replaceCharacters(
                in: context.range,
                with: NSAttributedString(string: CodeBlockEditing.indentation, attributes: textView.typingAttributes))
            apply(
                text: next,
                selection: NSRange(location: context.range.location + CodeBlockEditing.indentationWidth, length: 0),
                attributes: textView.typingAttributes)
        }

        private func continueCodeLine(
            prefix: String,
            context: EditorInputContext,
            storage: NSTextStorage,
            textView: PlatformTextView
        ) {
            let newline = "\n" + prefix
            registerUndo(
                text: NSAttributedString(attributedString: storage),
                selection: context.selection,
                attributes: textView.typingAttributes)
            let next = NSMutableAttributedString(attributedString: storage)
            next.replaceCharacters(
                in: context.range,
                with: NSAttributedString(string: newline, attributes: textView.typingAttributes))
            apply(
                text: next,
                selection: NSRange(location: context.range.location + newline.utf16.count, length: 0),
                attributes: textView.typingAttributes)
        }

        private func apply(
            edit: MarkdownShortcut.Edit,
            origin: EditorInputOrigin,
            context: EditorInputContext,
            storage: NSTextStorage,
            textView: PlatformTextView
        ) {
            var attributes = textView.typingAttributes
            if attributes.removeValue(forKey: .yoursSyntaxColor) != nil {
                #if os(macOS)
                    attributes[.foregroundColor] = AppTheme.documentBody
                #else
                    attributes[.foregroundColor] = AppTheme.documentBody
                #endif
            }
            let originalAttributes = attributes
            if context.replacement == "\n", [.body, .bullet, .numbered, .task, .quote].contains(edit.style) {
                for key: NSAttributedString.Key in [
                    .underlineStyle, .underlineColor, .strikethroughStyle, .strikethroughColor,
                    .link, .backgroundColor, .yoursInlineSpacing, .kern,
                ] {
                    attributes.removeValue(forKey: key)
                }
            }
            let base = (attributes[.font] as? PlatformFont)
            let originalFont = (attributes[.yoursStoredFont] as? PlatformFont).map { $0 as CTFont }
            let font: Font
            switch edit.style {
            case .heading(let level): font = ParagraphEditing.font(for: "heading:\(level)", context: parent.fontContext)
            case .bold:
                font = base.map { Font(NativeTextAttributes.storedFont($0 as CTFont, original: originalFont)).bold() } ?? .body.bold()
            case .italic:
                font = base.map { Font(NativeTextAttributes.storedFont($0 as CTFont, original: originalFont)).italic() } ?? .body.italic()
            case .code: font = .body.monospaced()
            case .codeBlock: font = .body.monospaced()
            case .body, .bullet, .quote, .numbered, .task, .strike: font = .body
            }
            let displayRole: String
            switch edit.style {
            case .heading(let level): displayRole = "heading:\(level)"
            case .bold, .italic: displayRole = attributes[.yoursParagraphStyle] as? String ?? "body"
            default: displayRole = "body"
            }
            NativeTextAttributes.setFont(
                font.resolve(in: parent.fontContext).ctFont,
                emphasis: edit.style == .italic ? 2 : edit.style == .bold ? 1 : 0,
                role: displayRole,
                in: &attributes)
            switch edit.style {
            case .heading(let level):
                attributes[.yoursInlineEmphasis] = 0
                attributes[.yoursParagraphStyle] = "heading:\(level)"
                attributes.removeValue(forKey: .yoursCodeStyle)
                attributes.removeValue(forKey: .yoursCodeLanguage)
                attributes.removeValue(forKey: .yoursSyntaxColor)
                attributes.removeValue(forKey: .yoursTaskChecked)
            case .codeBlock:
                attributes[.yoursCodeStyle] = "block:" + UUID().uuidString
                attributes[.yoursCodeLanguage] = CodeBlockEditing.languageTag(from: context.line)
                attributes[.yoursParagraphStyle] = "code"
                attributes.removeValue(forKey: .yoursTaskChecked)
            case .body, .bullet, .numbered, .task, .quote:
                switch edit.style {
                case .quote:
                    attributes[.yoursParagraphStyle] = "body"
                    attributes[.yoursQuote] = true
                    #if os(macOS)
                        attributes[.foregroundColor] = NSColor.secondaryLabelColor
                    #else
                        attributes[.foregroundColor] = UIColor.secondaryLabel
                    #endif
                    attributes[.yoursQuoteColor] = true
                    var quoteSample = AttributedString("\n")
                    quoteSample.font = .body
                    quoteSample[ParagraphStyleAttribute.self] = "body"
                    quoteSample[QuoteAttribute.self] = true
                    let nativeQuote = NativeTextAttributes.native(quoteSample, context: parent.fontContext)
                    attributes[.paragraphStyle] = nativeQuote.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                case .numbered: attributes[.yoursParagraphStyle] = "numbered"
                case .bullet: attributes[.yoursParagraphStyle] = "bullet"
                case .task: attributes[.yoursParagraphStyle] = "task"
                default:
                    attributes[.yoursParagraphStyle] = "body"
                    attributes.removeValue(forKey: .yoursQuote)
                    if attributes.removeValue(forKey: .yoursQuoteColor) != nil {
                        #if os(macOS)
                            attributes[.foregroundColor] = AppTheme.documentBody
                        #else
                            attributes[.foregroundColor] = AppTheme.documentBody
                        #endif
                    }
                    var bodySample = AttributedString("\n")
                    bodySample.font = .body
                    bodySample[ParagraphStyleAttribute.self] = "body"
                    let nativeBody = NativeTextAttributes.native(bodySample, context: parent.fontContext)
                    attributes[.paragraphStyle] = nativeBody.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
                }
                attributes.removeValue(forKey: .yoursCodeStyle)
                attributes.removeValue(forKey: .yoursCodeLanguage)
                attributes.removeValue(forKey: .yoursSyntaxColor)
                attributes[.yoursInlineEmphasis] = 0
                attributes.removeValue(forKey: .link)
                if edit.style == .task {
                    let preservesTask = context.role == "task" && origin == .feature && context.replacement != "\n"
                    let checked =
                        context.paragraph.location < storage.length
                        ? storage.attribute(.yoursTaskChecked, at: context.paragraph.location, effectiveRange: nil) as? Bool
                        : originalAttributes[.yoursTaskChecked] as? Bool
                    attributes[.yoursTaskChecked] = preservesTask ? (checked ?? false) : false
                } else {
                    attributes.removeValue(forKey: .yoursTaskChecked)
                }
            default: break
            }
            switch edit.style {
            case .bullet: attributes[.yoursListMarker] = "•"
            case .numbered: attributes[.yoursListMarker] = edit.listMarker ?? context.listMarker ?? "1."
            case .bold, .italic, .code, .strike: break
            default: attributes.removeValue(forKey: .yoursListMarker)
            }
            if attributes[.yoursListMarker] != nil || edit.style == .task {
                let sample = NSMutableAttributedString(string: "\n", attributes: attributes)
                NativeTextAttributes.layoutParagraphs(sample)
                attributes[.paragraphStyle] = sample.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            }
            let inserted: NSAttributedString
            switch edit.style {
            case .bold, .italic, .code, .strike:
                let markerLength = edit.style == .bold || edit.style == .strike ? 2 : 1
                let contentRange = NSRange(location: edit.range.location + markerLength, length: edit.replacement.utf16.count)
                let content = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: contentRange))
                content.enumerateAttribute(.font, in: NSRange(location: 0, length: content.length)) { value, runRange, _ in
                    let original = (content.attribute(.yoursStoredFont, at: runRange.location, effectiveRange: nil) as? PlatformFont)
                        .map { $0 as CTFont }
                    let existing =
                        (value as? PlatformFont).map { Font(NativeTextAttributes.storedFont($0 as CTFont, original: original)) } ?? .body
                    let styled: Font =
                        edit.style == .bold
                        ? existing.weight(.bold)
                        : edit.style == .italic
                            ? existing.italic()
                            : edit.style == .code
                                ? DocumentTypography.font(
                                    for: context.role ?? "body",
                                    inlineCode: true,
                                    context: parent.fontContext)
                                : existing
                    var fontAttributes: [NSAttributedString.Key: Any] = [:]
                    NativeTextAttributes.setFont(
                        styled.resolve(in: parent.fontContext).ctFont,
                        emphasis: (content.attribute(.yoursInlineEmphasis, at: runRange.location, effectiveRange: nil) as? Int ?? 0)
                            | (edit.style == .italic ? 2 : edit.style == .bold ? 1 : 0),
                        role: content.attribute(.yoursParagraphStyle, at: runRange.location, effectiveRange: nil) as? String ?? "body",
                        in: &fontAttributes)
                    content.addAttributes(fontAttributes, range: runRange)
                }
                if edit.style == .bold || edit.style == .italic {
                    let flag = edit.style == .bold ? 1 : 2
                    content.enumerateAttribute(.yoursInlineEmphasis, in: NSRange(location: 0, length: content.length)) {
                        value, runRange, _ in
                        content.addAttribute(.yoursInlineEmphasis, value: (value as? Int ?? 0) | flag, range: runRange)
                    }
                }
                if edit.style == .strike {
                    content.addAttribute(
                        .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: NSRange(location: 0, length: content.length))
                }
                if edit.style == .code {
                    content.addAttribute(.yoursCodeStyle, value: "inline", range: NSRange(location: 0, length: content.length))
                    content.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: content.length))
                }
                inserted = content
            default:
                inserted = NSAttributedString(string: edit.replacement, attributes: attributes)
            }
            let updated = NSMutableAttributedString(attributedString: storage)
            updated.replaceCharacters(in: edit.range, with: inserted)
            if edit.style == .codeBlock, inserted.length == 0 {
                // An actual empty paragraph stores the block role immediately, so
                // its surface/header, language selection and undo survive before typing.
                let boundary = edit.range.location
                if boundary < updated.length, (updated.string as NSString).character(at: boundary) == 10 {
                    updated.setAttributes(attributes, range: NSRange(location: boundary, length: 1))
                } else {
                    updated.insert(NSAttributedString(string: "\n", attributes: attributes), at: boundary)
                }
            }
            // Persist the empty paragraph's boundary, otherwise the native view can
            // inherit code/quote attributes from a neighboring newline. When content
            // follows an empty quote marker, its terminating newline is at the edit
            // location after the marker is removed; at the end of the document the
            // preceding newline carries the empty paragraph's typing state instead.
            if [.body, .quote].contains(edit.style), context.replacement == "\n", inserted.length == 0 {
                let boundary: Int?
                if edit.range.location < updated.length,
                    (updated.string as NSString).substring(with: NSRange(location: edit.range.location, length: 1)) == "\n"
                {
                    boundary = edit.range.location
                } else if edit.range.location > 0,
                    (updated.string as NSString).substring(with: NSRange(location: edit.range.location - 1, length: 1)) == "\n"
                {
                    boundary = edit.range.location - 1
                } else {
                    boundary = nil
                }
                if let boundary {
                    updated.setAttributes(attributes, range: NSRange(location: boundary, length: 1))
                }
            }
            let after: NSRange
            if context.replacement == "\t" || context.replacement == "\u{19}" {
                after = NSRange(location: context.selection.location + inserted.length - edit.range.length, length: 0)
            } else {
                after = NSRange(location: edit.range.location + inserted.length, length: 0)
            }
            // An empty replacement has no run to carry the list role. Style its
            // existing paragraph boundary now, so TextKit places the caret after
            // the marker before the user types the first content character.
            if [.bullet, .numbered, .task].contains(edit.style), after.location < updated.length {
                let paragraph = (updated.string as NSString).paragraphRange(for: NSRange(location: after.location, length: 0))
                if let marker = attributes[.yoursListMarker] {
                    updated.addAttribute(.yoursListMarker, value: marker, range: paragraph)
                } else {
                    updated.removeAttribute(.yoursListMarker, range: paragraph)
                }
                if let checked = attributes[.yoursTaskChecked] {
                    updated.addAttribute(.yoursTaskChecked, value: checked, range: paragraph)
                } else {
                    updated.removeAttribute(.yoursTaskChecked, range: paragraph)
                }
                updated.addAttribute(.yoursParagraphStyle, value: attributes[.yoursParagraphStyle] ?? "bullet", range: paragraph)
                NativeTextAttributes.layoutParagraphs(updated, around: paragraph)
            }
            if edit.style == .body, origin == .feature, context.replacement != "\n", updated.length > after.location {
                let affected = (updated.string as NSString).paragraphRange(for: NSRange(location: after.location, length: 0))
                updated.removeAttribute(.yoursCodeStyle, range: affected)
                updated.removeAttribute(.yoursCodeLanguage, range: affected)
                updated.removeAttribute(.yoursTaskChecked, range: affected)
                updated.removeAttribute(.yoursListMarker, range: affected)
                updated.addAttribute(.yoursParagraphStyle, value: "body", range: affected)
                if let bodyFont = attributes[.font] {
                    updated.addAttribute(.font, value: bodyFont, range: affected)
                    if let original = attributes[.yoursStoredFont] {
                        updated.addAttribute(.yoursStoredFont, value: original, range: affected)
                    }
                }
            }
            let nextAttributes: [NSAttributedString.Key: Any]
            switch edit.style {
            case .bold, .italic, .code, .strike: nextAttributes = originalAttributes
            default: nextAttributes = attributes
            }
            // Register the raw typed marker as the undo state: one undo restores syntax,
            // without triggering the shortcut again through the input delegate.
            let raw = NSMutableAttributedString(attributedString: storage)
            if origin == .markdownShortcut {
                raw.replaceCharacters(
                    in: context.range,
                    with: NSAttributedString(string: context.replacement, attributes: originalAttributes))
            }
            registerUndo(
                text: raw,
                selection: origin == .markdownShortcut
                    ? NSRange(location: context.range.location + context.replacement.utf16.count, length: 0)
                    : context.selection,
                attributes: originalAttributes)
            apply(text: updated, selection: after, attributes: nextAttributes)
            textView.undoManager?.setActionName(L10n.string("markdown.shortcut"))
        }

        func exitTrailingCode() -> Bool {
            guard !hasMarkedText, let storage, let view = textView, storage.length > 0,
                (storage.attribute(.yoursCodeStyle, at: storage.length - 1, effectiveRange: nil) as? String)?.hasPrefix("block:") == true
            else { return false }
            var body = AttributedString("\n")
            body.font = .body
            body[ParagraphStyleAttribute.self] = "body"
            let boundary = NativeTextAttributes.native(body, context: parent.fontContext)
            let attributes = boundary.attributes(at: 0, effectiveRange: nil)
            registerUndo(
                text: NSAttributedString(attributedString: storage), selection: currentSelection, attributes: view.typingAttributes)
            let next = NSMutableAttributedString(attributedString: storage)
            if next.string.hasSuffix("\n") {
                next.setAttributes(attributes, range: NSRange(location: next.length - 1, length: 1))
            } else {
                next.append(boundary)
            }
            apply(text: next, selection: NSRange(location: next.length, length: 0), attributes: attributes)
            view.undoManager?.setActionName(L10n.string("code.exit"))
            return true
        }

        fileprivate func exitEmptyQuote() -> Bool {
            guard !hasMarkedText, let storage, let view = textView,
                storage.length == 0,
                currentSelection == NSRange(location: 0, length: 0),
                view.typingAttributes[.yoursQuote] as? Bool == true
            else { return false }
            var body = AttributedString(" ")
            body.font = .body
            body[ParagraphStyleAttribute.self] = "body"
            var attributes = NativeTextAttributes.native(body, context: parent.fontContext).attributes(at: 0, effectiveRange: nil)
            attributes.removeValue(forKey: .yoursQuote)
            attributes.removeValue(forKey: .yoursQuoteColor)
            registerUndo(
                text: NSAttributedString(attributedString: storage), selection: currentSelection, attributes: view.typingAttributes)
            apply(text: NSAttributedString(attributedString: storage), selection: currentSelection, attributes: attributes)
            view.undoManager?.setActionName(L10n.string("quote.exit"))
            return true
        }

        fileprivate func toggleTask(at index: Int) -> Bool {
            guard !hasMarkedText, let storage, let view = textView, index < storage.length else { return false }
            let source = storage.string as NSString
            let paragraph = source.paragraphRange(for: NSRange(location: index, length: 0))
            guard let layout = view.layoutManager as? CodeLayoutManager,
                let markerIndex = layout.taskMarkerIndex(in: paragraph), index == markerIndex
            else { return false }
            let checked = storage.attribute(.yoursTaskChecked, at: markerIndex, effectiveRange: nil) as? Bool ?? false
            registerUndo(
                text: NSAttributedString(attributedString: storage), selection: currentSelection, attributes: view.typingAttributes)
            let updated = NSMutableAttributedString(attributedString: storage)
            updated.addAttribute(.yoursTaskChecked, value: !checked, range: paragraph)
            apply(text: updated, selection: currentSelection, attributes: view.typingAttributes)
            view.undoManager?.setActionName(L10n.string("checklist.toggle.undo"))
            return true
        }

        func toggleEmptyTask() -> Bool {
            guard !hasMarkedText, let storage, let view = textView,
                currentSelection.length == 0,
                view.typingAttributes[.yoursParagraphStyle] as? String == "task",
                let checked = view.typingAttributes[.yoursTaskChecked] as? Bool
            else { return false }
            registerUndo(
                text: NSAttributedString(attributedString: storage),
                selection: currentSelection,
                attributes: view.typingAttributes
            )
            var attributes = view.typingAttributes
            attributes[.yoursTaskChecked] = !checked
            apply(
                text: NSAttributedString(attributedString: storage),
                selection: currentSelection,
                attributes: attributes
            )
            view.undoManager?.setActionName(L10n.string("checklist.toggle.undo"))
            return true
        }

        func refreshControlPosition() {
            guard controls.isShowing, !controls.hasDetail else { return }
            refreshControls()
        }

        func dismissRootControls() {
            guard !controls.hasDetail else { return }
            dismissControls()
        }

        func dismissControls() {
            slashAnchor = nil
            pendingSlash = false
            controlsSuppressed = true
            controls.close()
        }

        func controlsAfterTyping() {
            guard !isUpdating, let storage, let view = textView else { return }
            guard !hasMarkedText else {
                controls.close()
                return
            }
            if view.undoManager?.isUndoing == true || view.undoManager?.isRedoing == true {
                dismissControls()
                return
            }
            if controls.hasDetail { dismissControls() }
            if pendingSlash {
                // Retain highlights only while refining the current query, never
                // across separate slash sessions (including the same text offset).
                controls.state.commands = []
                controls.state.highlighted = 0
                slashAnchor = EditorSlashQuery.detect(in: storage.string, caret: currentSelection.location)?.range.location
                pendingSlash = false
            }
            controlsSuppressed = false
            refreshControls()
        }

        func controlsAfterSelection() {
            guard !isUpdating else { return }
            if controls.hasDetail {
                guard currentSelection != controlsTargetRange else { return }
                dismissControls()
            }
            if hasMarkedText {
                controls.close()
                return
            }
            controlsSuppressed = false
            refreshControls()
        }

        func refreshControls() {
            guard !isUpdating, !hasMarkedText, let view = textView, let storage else { return }
            if controls.hasDetail { return }
            let range = currentSelection
            let query = EditorSlashQuery.detect(in: storage.string, caret: range.location)
            let isSlash = range.length == 0 && slashAnchor != nil && query?.range.location == slashAnchor
            if !isSlash { slashAnchor = nil }
            #if os(macOS)
                guard view.selectedRanges.count == 1,
                    view.window?.firstResponder === view,
                    NSApp.currentEvent?.type != .leftMouseDragged
                else {
                    controls.close()
                    return
                }
            #endif
            guard !controlsSuppressed, isSlash || range.length > 0 else {
                controls.close()
                return
            }
            let rich = NativeTextAttributes.rich(storage)
            if !isSlash, let selected = Range<AttributedString.Index>(range, in: rich),
                rich[selected].runs.contains(where: { $0[TableAttribute.self] != nil || $0[RenderedContentAttribute.self] != nil })
            {
                controls.close()
                return
            }
            controlsTargetRange = range
            let selectedRange = Range<AttributedString.Index>(range, in: rich)
            let attributes = selectedRange.map { Array(rich[$0].runs.map(\.attributes)) } ?? []
            let definitions: [(String, String, String, EditorAction)] = [
                ("bold", "format.bold", "bold", .emphasis(1)),
                ("italic", "format.italic", "italic", .emphasis(2)),
                ("underline", "format.underline", "underline", .underline),
                ("strike", "format.strikethrough", "strikethrough", .strike),
                ("inline-code", "format.monospaced", "chevron.left.forwardslash.chevron.right", .inlineCode),
                ("link", "link.add_or_edit", "link", .link(nil)),
                ("quote", "format.quote", "text.quote", .quote),
                ("indent", "format.list.indent", "increase.indent", .indent(false)),
                ("outdent", "format.list.outdent", "decrease.indent", .indent(true)),
                ("clear", "format.clear", "textformat", .clear),
            ]
            controls.state.items =
                definitions.map { id, key, symbol, action in
                    let active = attributes.map { EditorCommandEditing.isActive(action, attributes: $0, context: parent.fontContext) }
                    return EditorControlItem(
                        id: id, title: L10n.string(String.LocalizationValue(key)), symbol: symbol, action: action,
                        enabled: EditorCommandEditing.isAllowed(action, text: rich, range: range),
                        active: !active.isEmpty && active.allSatisfy { $0 }, mixed: active.contains(true) && active.contains(false))
                }
                + EditorCommandCatalog.paragraphs.filter { $0.id != "table" && $0.id != "quote" }.map { command in
                    let active = attributes.map {
                        EditorCommandEditing.isActive(command.action, attributes: $0, context: parent.fontContext)
                    }
                    return EditorControlItem(
                        id: "paragraph-" + command.id, title: command.title, symbol: command.symbol, action: command.action,
                        enabled: EditorCommandEditing.isAllowed(command.action, text: rich, range: range),
                        active: !active.isEmpty && active.allSatisfy { $0 },
                        mixed: active.contains(true) && active.contains(false))
                }
            controls.state.isSlash = isSlash
            controls.state.address = attributes.compactMap { $0.link?.absoluteString }.first ?? ""
            if isSlash {
                let previousID =
                    controls.state.commands.indices.contains(controls.state.highlighted)
                    ? controls.state.commands[controls.state.highlighted].id : nil
                controls.state.commands = EditorCommandCatalog.matching(query?.query ?? "")
                controls.state.highlighted = controls.state.commands.firstIndex { $0.id == previousID } ?? 0
                // Block structures never offer commands from inside code or attachments.
                let sample = range.location > 0 ? storage.attributes(at: range.location - 1, effectiveRange: nil) : view.typingAttributes
                if sample[.yoursCodeStyle] != nil || sample[.yoursTable] != nil || sample[.link] != nil {
                    dismissControls()
                    return
                }
            }
            let expectedRevision = revision
            let expectedDocument = parent.documentID
            controls.state.choose = { [weak self] action in
                guard let self, self.revision == expectedRevision, self.parent.documentID == expectedDocument else { return }
                self.performControlAction(action, range: range, slash: isSlash ? query?.range : nil)
            }
            controls.state.cancel = { [weak self] in self?.dismissControls() }
            #if os(macOS)
                controls.show(in: view, range: range)
            #else
                if isSlash { controls.show(in: view, range: range) }
            #endif
        }

        func handleControlKey(_ key: String) -> Bool {
            guard !hasMarkedText, controls.isShowing else { return false }
            if controls.state.handleParagraphKey(key) { return true }
            if key == "escape" {
                dismissControls()
                return true
            }
            guard slashAnchor != nil, !controls.hasDetail else { return false }
            let count = controls.state.commands.count
            if key == "up" || key == "down" {
                if count > 0 { controls.state.highlighted = (controls.state.highlighted + (key == "up" ? count - 1 : 1)) % count }
                return true
            }
            if key == "tab" {
                dismissControls()
                return false
            }
            if key == "return" {
                guard count > 0 else {
                    dismissControls()
                    return false
                }
                let command = controls.state.commands[controls.state.highlighted]
                if command.id == "table" { controls.state.open("table") } else { controls.state.choose(command.action) }
                return true
            }
            return false
        }

        func presentControlDetail(_ kind: String, range capturedRange: NSRange? = nil) {
            guard !hasMarkedText, let view = textView, let storage else { return }
            let range = capturedRange ?? currentSelection
            controlsTargetRange = range
            let expected = revision
            let document = parent.documentID
            if kind == "link" {
                let rich = NativeTextAttributes.rich(storage)
                guard EditorCommandEditing.isAllowed(.link(nil), text: rich, range: range),
                    let selected = Range<AttributedString.Index>(range, in: rich)
                else { return }
                controls.state.address = rich[selected].runs.compactMap { $0.link?.absoluteString }.first ?? ""
            }
            controls.state.choose = { [weak self] action in
                guard let self, self.revision == expected, self.parent.documentID == document else { return }
                self.performControlAction(action, range: range)
            }
            controls.state.cancel = { [weak self] in self?.dismissControls() }
            controls.state.detail = kind
            #if os(macOS)
                controls.show(in: view, range: range)
                controls.state.open(kind)
            #else
                controls.showDetail(in: view)
            #endif
        }

        func performControlAction(_ action: EditorAction, range: NSRange, slash: NSRange? = nil) {
            #if os(macOS)
                (textView as? ReadingMacTextView)?.discardInlineCodeBoundary()
            #endif
            guard !hasMarkedText, let storage, let view = textView, NSMaxRange(range) <= storage.length else { return }
            var rich = NativeTextAttributes.rich(storage)
            var target = range
            if let slash {
                guard let deletion = Range<AttributedString.Index>(slash, in: rich),
                    !rich[deletion].runs.contains(where: {
                        $0[CodeStyleAttribute.self] != nil || $0.link != nil || $0[TableAttribute.self] != nil
                    })
                else { return }
                rich.removeSubrange(deletion)
                target = NSRange(location: slash.location, length: 0)
            }
            guard EditorCommandEditing.isAllowed(action, text: rich, range: target),
                let selected = Range<AttributedString.Index>(target, in: rich)
            else { return }
            let sample = NativeTextAttributes.rich(NSAttributedString(string: " ", attributes: view.typingAttributes))
            var selection =
                selected.isEmpty
                ? AttributedTextSelection(insertionPoint: selected.lowerBound, typingAttributes: sample.runs.first?.attributes)
                : AttributedTextSelection(range: selected)
            let previousTables = Set(rich.runs.compactMap { $0[TableAttribute.self]?.id })
            EditorCommandEditing.apply(action, text: &rich, selection: &selection, context: parent.fontContext, setQuote: slash != nil)
            let resultRange: NSRange
            switch selection.indices(in: rich) {
            case .insertionPoint(let caret): resultRange = NSRange(caret..<caret, in: rich)
            case .ranges(let ranges):
                guard let first = ranges.ranges.first, let last = ranges.ranges.last else { return }
                resultRange = NSRange(first.lowerBound..<last.upperBound, in: rich)
            }
            let typing = NativeTextAttributes.native(
                AttributedString(" ", attributes: selection.typingAttributes(in: rich)), context: parent.fontContext
            ).attributes(at: 0, effectiveRange: nil)
            let next = NativeTextAttributes.native(rich, context: parent.fontContext)
            if next.isEqual(to: storage), NSDictionary(dictionary: typing).isEqual(to: view.typingAttributes) {
                dismissControls()
                return
            }
            #if os(macOS)
                view.breakUndoCoalescing()
            #endif
            registerUndo(
                text: NSAttributedString(attributedString: storage), selection: currentSelection, attributes: view.typingAttributes)
            dismissControls()
            apply(text: next, selection: resultRange, attributes: typing)
            #if os(macOS)
                view.window?.makeKey()
                view.window?.makeFirstResponder(view)
            #else
                view.becomeFirstResponder()
            #endif
            if case .table = action,
                let id = rich.runs.compactMap({ $0[TableAttribute.self]?.id }).first(where: { !previousTables.contains($0) })
            {
                tables.focusFirstCell(id: id)
            }
            if resultRange.length > 0 {
                controlsSuppressed = false
                refreshControls()
            }
        }

        private func registerUndo(text: NSAttributedString, selection: NSRange, attributes: [NSAttributedString.Key: Any]) {
            textView?.undoManager?.registerUndo(withTarget: self) { coordinator in
                // UndoManager calls the registered target on the AppKit main
                // thread; the closure signature does not express that isolation.
                MainActor.assumeIsolated {
                    guard let current = coordinator.storage, let view = coordinator.textView else { return }
                    coordinator.registerUndo(
                        text: NSAttributedString(attributedString: current), selection: coordinator.currentSelection,
                        attributes: view.typingAttributes)
                    coordinator.dismissControls()
                    coordinator.apply(text: text, selection: selection, attributes: attributes)
                }
            }
        }

        private func prepareTypingAttributesAfterInlineDeletion(_ deletion: NSRange) {
            guard let storage, let view = textView, deletion.location < storage.length else { return }
            let source = storage.string as NSString
            let paragraph = source.paragraphRange(for: NSRange(location: deletion.location, length: 0))
            let limit = NSIntersectionRange(paragraph, NSRange(location: 0, length: storage.length))
            var resetCode = false
            var resetEmphasis = 0
            var resetStrike = false
            var resetUnderline = false
            var resetLink = false
            var location = deletion.location
            let end = min(NSMaxRange(deletion), storage.length)
            while location < end {
                var effective = NSRange()
                let attributes = storage.attributes(at: location, longestEffectiveRange: &effective, in: limit)
                let fullyDeleted = deletion.location <= effective.location && NSMaxRange(deletion) >= NSMaxRange(effective)
                if fullyDeleted {
                    if attributes[.yoursCodeStyle] as? String == "inline" { resetCode = true }
                    resetEmphasis |= attributes[.yoursInlineEmphasis] as? Int ?? 0
                    resetStrike = resetStrike || (attributes[.strikethroughStyle] as? Int ?? 0) != 0
                    resetUnderline = resetUnderline || (attributes[.underlineStyle] as? Int ?? 0) != 0
                    resetLink = resetLink || attributes[.link] != nil
                }
                location = max(location + 1, NSMaxRange(effective))
            }
            guard resetCode || resetEmphasis != 0 || resetStrike || resetUnderline || resetLink else { return }
            var attributes = view.typingAttributes
            let role =
                attributes[.yoursParagraphStyle] as? String
                ?? storage.attribute(.yoursParagraphStyle, at: deletion.location, effectiveRange: nil) as? String
                ?? "body"
            var emphasis = attributes[.yoursInlineEmphasis] as? Int ?? 0
            emphasis &= ~resetEmphasis
            attributes[.yoursInlineEmphasis] = emphasis
            if resetCode {
                attributes.removeValue(forKey: .yoursCodeStyle)
                attributes.removeValue(forKey: .yoursCodeLanguage)
                attributes.removeValue(forKey: .yoursSyntaxColor)
                attributes.removeValue(forKey: .yoursInlineSpacing)
                attributes.removeValue(forKey: .kern)
                attributes.removeValue(forKey: .backgroundColor)
            }
            if resetStrike { attributes.removeValue(forKey: .strikethroughStyle) }
            if resetUnderline { attributes.removeValue(forKey: .underlineStyle) }
            if resetLink { attributes.removeValue(forKey: .link) }
            NativeTextAttributes.setFont(
                DocumentTypography.font(for: role, emphasis: emphasis, context: parent.fontContext).resolve(in: parent.fontContext).ctFont,
                emphasis: emphasis, role: role, in: &attributes
            )
            pendingTypingAttributesAfterInlineDeletion = attributes
        }

        fileprivate func restoreEmptyQuoteTypingAttributesFromPreviousValue() {
            guard !isUpdating, let storage, let view = textView,
                storage.length < lastNativeValue.length,
                lastNativeValue.length > 0
            else { return }
            let source = storage.string as NSString
            let insertion = min(currentSelection.location, source.length)
            let paragraph = source.paragraphRange(for: NSRange(location: insertion, length: 0))
            guard source.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let anchor = min(insertion, lastNativeValue.length - 1)
            guard lastNativeValue.attribute(.yoursQuote, at: anchor, effectiveRange: nil) as? Bool == true else { return }
            var attributes = lastNativeValue.attributes(at: anchor, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            attributes.removeValue(forKey: .yoursRenderedContent)
            attributes.removeValue(forKey: .yoursTable)
            attributes[.yoursQuote] = true
            view.typingAttributes = attributes
            #if os(macOS)
                (view as? ReadingMacTextView)?.updateEmptyQuoteBar()
            #else
                view.setNeedsDisplay()
            #endif
        }

        private func positionedHeadingTypingAttributes(
            _ attributes: [NSAttributedString.Key: Any], at insertion: Int, in text: String
        ) -> [NSAttributedString.Key: Any] {
            guard let role = attributes[.yoursParagraphStyle] as? String,
                let heading = DocumentTypography.heading(for: role),
                let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            else { return attributes }
            let source = text as NSString
            let start = source.paragraphRange(for: NSRange(location: min(insertion, source.length), length: 0)).location
            // Synthetic typing samples start at zero; an empty heading elsewhere
            // must already reserve the same before-spacing as its first character.
            paragraph.paragraphSpacingBefore = start == 0 ? 0 : heading.before
            var result = attributes
            result[.paragraphStyle] = paragraph
            return result
        }

        private func apply(text: NSAttributedString, selection: NSRange, attributes: [NSAttributedString.Key: Any]) {
            revision += 1
            isUpdating = true
            storage?.setAttributedString(text)
            setSelection(selection)
            let attributes = positionedHeadingTypingAttributes(attributes, at: selection.location, in: text.string)
            textView?.typingAttributes = attributes
            locallyAppliedTypingAttributes = attributes
            #if os(macOS)
                (textView as? ReadingMacTextView)?.setInlineCodeBoundary(
                    inside: attributes[.yoursCodeStyle] as? String == "inline", publish: false)
                textView?.didChangeText()
                textView?.needsDisplay = true
                (textView as? ReadingMacTextView)?.updateEmptyQuoteBar()
            #else
                textView?.setNeedsDisplay()
            #endif
            isUpdating = false
            publish()
        }
    }
}

#if os(macOS)
    final class ReadingMacTextView: NSTextView {
        var selectionFocusChanged: ((Bool) -> Void)?
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { selectionFocusChanged?(true) }
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted { selectionFocusChanged?(false) }
            return accepted
        }
        override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
            super.drawInsertionPoint(in: visibleInsertionPointRect(rect), color: color, turnedOn: flag)
        }

        func visibleInsertionPointRect(_ rect: NSRect) -> NSRect {
            guard let font = typingAttributes[.font] as? NSFont, rect.height > 0 else { return rect }
            // The reading line box includes mixed-script leading and extra spacing.
            // Use a stable font-sized cursor without changing TextKit's input or selection geometry.
            let metrics = NSFont.systemFont(ofSize: font.pointSize)
            let height = min(rect.height, ceil(metrics.ascender - metrics.descender))
            let paragraph = typingAttributes[.paragraphStyle] as? NSParagraphStyle
            let spacing = (paragraph?.lineSpacing ?? 0) * DocumentTypography.selectionLineSpacingShare
            let offset = max(0, (rect.height - spacing - height) / 2)
            var top = rect.minY + offset
            if let layout = layoutManager, let storage = textStorage {
                let caret = min(selectedRange().location, storage.length)
                let trailingEmptyLine =
                    caret == storage.length
                    && (storage.length == 0 || storage.string.last.map { "\n\u{2028}\u{2029}".contains($0) } == true)
                if trailingEmptyLine, let layout = layout as? CodeLayoutManager,
                    let lineHeight = paragraph?.maximumLineHeight, lineHeight > 0
                {
                    // Empty fragments have no glyph baseline. Use the same canonical
                    // baseline as populated fragments rather than centering the caret.
                    let baseline = rect.minY + layout.stableBaselineOffset(fontSize: font.pointSize, lineHeight: lineHeight)
                    top = max(rect.minY, min(baseline - metrics.ascender, rect.maxY - height))
                } else if !trailingEmptyLine, storage.length > 0 {
                    let character = min(caret, storage.length - 1)
                    let glyph = layout.glyphIndexForCharacter(at: character)
                    let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let baseline = textContainerOrigin.y + line.minY + layout.location(forGlyphAt: glyph).y
                    top = max(rect.minY, min(baseline - metrics.ascender, rect.maxY - height))
                }
            }
            if let point = inlineCodeBoundaryPoint() {
                return NSRect(
                    x: point.x + textContainerOrigin.x, y: point.y + textContainerOrigin.y - height / 2,
                    width: rect.width, height: height)
            }
            return NSRect(x: rect.minX, y: top, width: rect.width, height: height)
        }

        override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
            let original = super.firstRect(forCharacterRange: range, actualRange: actualRange)
            guard range.length == 0, range == selectedRange(), let point = inlineCodeBoundaryPoint(), let window else { return original }
            let local = NSRect(
                x: point.x + textContainerOrigin.x,
                y: point.y + textContainerOrigin.y - original.height / 2, width: original.width, height: original.height)
            return window.convertToScreen(convert(local, to: nil))
        }

        struct InlineCodeBoundary {
            var index: Int
            var inside: Bool
        }

        private(set) var inlineCodeBoundary: InlineCodeBoundary?
        private var composingInlineCodeSide: Bool?

        func discardInlineCodeBoundary() {
            inlineCodeBoundary = nil
            composingInlineCodeSide = nil
        }

        func inlineCodeRange(at index: Int) -> NSRange? {
            guard let storage = textStorage, index >= 0, index <= storage.length else { return nil }
            for probe in [index, index - 1] where probe >= 0 && probe < storage.length {
                var range = NSRange()
                if storage.attribute(
                    .yoursCodeStyle, at: probe, longestEffectiveRange: &range,
                    in: NSRange(location: 0, length: storage.length)) as? String == "inline",
                    index == range.location || index == NSMaxRange(range)
                {
                    return range
                }
            }
            return nil
        }

        @discardableResult func setInlineCodeBoundary(inside: Bool, publish: Bool = true) -> Bool {
            let selection = selectedRange()
            guard selection.length == 0, !hasMarkedText(), inlineCodeRange(at: selection.location) != nil else {
                discardInlineCodeBoundary()
                return false
            }
            inlineCodeBoundary = InlineCodeBoundary(index: selection.location, inside: inside)
            restoreInlineCodeBoundaryTyping()
            needsDisplay = true
            updateInsertionPointStateAndRestartTimer(true)
            if publish { didResolveTypingAttributes?() }
            return true
        }

        func restoreInlineCodeBoundaryTyping() {
            guard let boundary = inlineCodeBoundary, selectedRange() == NSRange(location: boundary.index, length: 0),
                !hasMarkedText(), let storage = textStorage, let range = inlineCodeRange(at: boundary.index)
            else { return }
            let leading = boundary.index == range.location
            let insideIndex = leading ? range.location : NSMaxRange(range) - 1
            let outsideIndex = leading ? range.location - 1 : NSMaxRange(range)
            let hasBodyNeighbor =
                outsideIndex >= 0 && outsideIndex < storage.length
                && storage.attribute(.yoursCodeStyle, at: outsideIndex, effectiveRange: nil) as? String != "inline"
            var attributes = storage.attributes(at: !boundary.inside && hasBodyNeighbor ? outsideIndex : insideIndex, effectiveRange: nil)
            if let original = attributes.removeValue(forKey: .yoursInlineSpacing) as? CGFloat {
                if original == 0 { attributes.removeValue(forKey: .kern) } else { attributes[.kern] = original }
            }
            if !boundary.inside && !hasBodyNeighbor {
                attributes.removeValue(forKey: .yoursCodeStyle)
                attributes.removeValue(forKey: .yoursCodeLanguage)
                attributes.removeValue(forKey: .yoursSyntaxColor)
                attributes.removeValue(forKey: .backgroundColor)
                let role = attributes[.yoursParagraphStyle] as? String ?? "body"
                let emphasis = attributes[.yoursInlineEmphasis] as? Int ?? 0
                let context = EnvironmentValues().fontResolutionContext
                NativeTextAttributes.setFont(
                    DocumentTypography.font(for: role, emphasis: emphasis, context: context).resolve(in: context).ctFont,
                    emphasis: emphasis, role: role, in: &attributes)
            }
            attributes.removeValue(forKey: .attachment)
            attributes.removeValue(forKey: .yoursRenderedContent)
            attributes.removeValue(forKey: .yoursTable)
            typingAttributes = attributes
        }

        /// Container coordinates for the two visual stops at a single text index.
        func inlineCodeBoundaryPoint() -> CGPoint? {
            guard let boundary = inlineCodeBoundary, selectedRange() == NSRange(location: boundary.index, length: 0),
                let range = inlineCodeRange(at: boundary.index), let storage = textStorage,
                let layout = layoutManager as? CodeLayoutManager, let container = textContainer
            else { return nil }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let surfaces = layout.inlineCodeBackgroundRects(forGlyphRange: glyphs, in: container)
            let leading = boundary.index == range.location
            guard let surface = leading ? surfaces.first : surfaces.last,
                let font = storage.attribute(.font, at: leading ? range.location : NSMaxRange(range) - 1, effectiveRange: nil) as? NSFont
            else { return nil }
            let padding = font.pointSize * DocumentTypography.inlineCodePaddingRatio
            let margin = font.pointSize * DocumentTypography.inlineCodeMarginRatio
            let x =
                leading
                ? (boundary.inside ? surface.minX + padding : surface.minX - margin)
                : (boundary.inside ? surface.maxX - padding : surface.maxX + margin)
            let glyph = leading ? glyphs.location : NSMaxRange(glyphs) - 1
            let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = line.minY + layout.location(forGlyphAt: glyph).y
            let metrics = NSFont.systemFont(ofSize: font.pointSize)
            let height = ceil(metrics.ascender - metrics.descender)
            return CGPoint(x: x, y: baseline - metrics.ascender + height / 2)
        }

        private func moveAcrossInlineCodeBoundary(right: Bool, sender: Any?) {
            guard selectedRange().length == 0, !hasMarkedText() else {
                discardInlineCodeBoundary()
                if right { super.moveRight(sender) } else { super.moveLeft(sender) }
                return
            }
            let index = selectedRange().location
            if let range = inlineCodeRange(at: index) {
                let leading = index == range.location
                let inside = inlineCodeBoundary?.inside ?? (typingAttributes[.yoursCodeStyle] as? String == "inline")
                if (right && leading && !inside) || (!right && !leading && !inside) {
                    setInlineCodeBoundary(inside: true)
                    return
                }
                if (right && !leading && inside) || (!right && leading && inside) {
                    setInlineCodeBoundary(inside: false)
                    return
                }
            }
            discardInlineCodeBoundary()
            if right { super.moveRight(sender) } else { super.moveLeft(sender) }
            if let range = inlineCodeRange(at: selectedRange().location) {
                let leading = selectedRange().location == range.location
                setInlineCodeBoundary(inside: right ? !leading : leading)
            }
        }

        override func moveRight(_ sender: Any?) { moveAcrossInlineCodeBoundary(right: true, sender: sender) }
        override func moveLeft(_ sender: Any?) { moveAcrossInlineCodeBoundary(right: false, sender: sender) }
        override func moveForward(_ sender: Any?) { moveRight(sender) }
        override func moveBackward(_ sender: Any?) { moveLeft(sender) }

        override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
            if let boundary = inlineCodeBoundary, charRange != NSRange(location: boundary.index, length: 0) { discardInlineCodeBoundary() }
            super.setSelectedRange(charRange, affinity: affinity, stillSelecting: flag)
            if flag { selectionTrackingChanged?() }
        }

        override func insertText(_ insertString: Any, replacementRange: NSRange) {
            restoreInlineCodeBoundaryTyping()
            let side = composingInlineCodeSide ?? inlineCodeBoundary?.inside
            composingInlineCodeSide = nil
            super.insertText(insertString, replacementRange: replacementRange)
            if let side, !hasMarkedText() { setInlineCodeBoundary(inside: side) }
        }

        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            restoreInlineCodeBoundaryTyping()
            // Marked text moves the native selection before commit. Preserve the
            // logical side independently of that temporary UTF-16 position.
            let side = composingInlineCodeSide ?? inlineCodeBoundary?.inside
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            if hasMarkedText(), let storage = textStorage {
                let attributes = typingAttributes
                NativeTextAttributes.layoutInlineCodeSpacing(storage, around: markedRange())
                typingAttributes = attributes
            }
            composingInlineCodeSide = side
        }

        override func unmarkText() {
            let side = composingInlineCodeSide
            super.unmarkText()
            composingInlineCodeSide = nil
            if let side { setInlineCodeBoundary(inside: side) }
        }

        override func keyDown(with event: NSEvent) {
            if !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                || [125, 126, 115, 119].contains(event.keyCode)
            {
                discardInlineCodeBoundary()
            }
            super.keyDown(with: event)
        }

        var selectionFinished: (() -> Void)?
        var selectionTrackingChanged: (() -> Void)?
        var dismissControlMenus: (() -> Void)?
        override func menu(for event: NSEvent) -> NSMenu? {
            dismissControlMenus?()
            return super.menu(for: event)
        }
        var suppressSlash: ((Bool) -> Void)?

        private final class QuoteDecorationView: NSView {
            weak var owner: ReadingMacTextView?

            override var isFlipped: Bool { true }
            override var isOpaque: Bool { false }
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
            override func draw(_ dirtyRect: NSRect) {
                NSColor.clear.setFill()
                dirtyRect.fill(using: .copy)
                owner?.drawQuoteDecorations()
            }
        }

        private var quoteDecorationView: QuoteDecorationView?
        private var taskTrackingArea: NSTrackingArea?
        private var isHoveringEmptyTask = false {
            didSet {
                if isHoveringEmptyTask != oldValue { needsDisplay = true }
            }
        }
        var exitTrailingCode: (() -> Bool)?
        var didResolveTypingAttributes: (() -> Void)?
        var toggleTask: ((Int) -> Bool)?
        var toggleEmptyTask: (() -> Bool)?
        var copyStructured: ((Bool) -> Bool)?
        var pasteStructured: (() -> Bool)?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            installQuoteDecorationView()
        }
        override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
            super.init(frame: frameRect, textContainer: container)
            installQuoteDecorationView()
        }
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            installQuoteDecorationView()
        }
        private func installQuoteDecorationView() {
            guard quoteDecorationView == nil else { return }
            let decoration = QuoteDecorationView(frame: bounds)
            decoration.owner = self
            decoration.autoresizingMask = [.width, .height]
            decoration.setAccessibilityElement(false)
            addSubview(decoration)
            quoteDecorationView = decoration
        }
        override func copy(_ sender: Any?) { if copyStructured?(false) != true { super.copy(sender) } }
        override func cut(_ sender: Any?) { if copyStructured?(true) != true { super.cut(sender) } }
        override func paste(_ sender: Any?) {
            suppressSlash?(true)
            defer { suppressSlash?(false) }
            if pasteStructured?() != true { super.paste(sender) }
        }
        func emptyQuoteBarDrawingRect() -> CGRect? {
            let selection = selectedRange()
            let source = string as NSString
            let insertion = min(selection.location, source.length)
            let paragraph = source.paragraphRange(for: NSRange(location: insertion, length: 0))
            guard selection.length == 0,
                source.substring(with: paragraph).trimmingCharacters(in: .newlines).isEmpty,
                typingAttributes[.yoursQuote] as? Bool == true,
                let layout = layoutManager as? CodeLayoutManager,
                let container = textContainer
            else {
                return nil
            }
            if paragraph.location < (textStorage?.length ?? 0),
                textStorage?.attribute(.yoursQuote, at: paragraph.location, effectiveRange: nil) as? Bool == true
            {
                return nil
            }
            let font = typingAttributes[.font] as? NSFont ?? .systemFont(ofSize: DocumentTypography.bodySize)
            return layout.emptyQuoteBarRect(at: insertion, font: font, in: container).offsetBy(
                dx: textContainerOrigin.x,
                dy: textContainerOrigin.y
            )
        }
        func emptyTaskMarkerDrawingRect() -> CGRect? {
            let selection = selectedRange()
            let source = string as NSString
            let insertion = min(selection.location, source.length)
            let paragraph = source.paragraphRange(for: NSRange(location: insertion, length: 0))
            guard selection.length == 0,
                source.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                typingAttributes[.yoursParagraphStyle] as? String == "task",
                typingAttributes[.yoursTaskChecked] is Bool,
                let layout = layoutManager as? CodeLayoutManager,
                let container = textContainer
            else { return nil }
            if paragraph.location < (textStorage?.length ?? 0),
                layout.taskMarkerIndex(in: paragraph) != nil
            {
                return nil
            }
            let font =
                typingAttributes[.font] as? NSFont
                ?? .systemFont(ofSize: DocumentTypography.bodySize * DocumentTypography.readingScale)
            return layout.emptyTaskMarkerRect(
                at: insertion,
                font: font,
                quoted: typingAttributes[.yoursQuote] as? Bool == true,
                in: container
            ).offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        }
        fileprivate func updateEmptyQuoteBar() {
            if let layout = layoutManager as? CodeLayoutManager {
                layout.emptyLineHeadIndent =
                    string.isEmpty
                        && typingAttributes[.yoursQuote] as? Bool == true
                    ? DocumentTypography.quoteIndent
                    : 0
            }
            quoteDecorationView?.needsDisplay = true
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            quoteDecorationView?.needsDisplay = true
            if let layout = layoutManager as? CodeLayoutManager, let container = textContainer {
                layout.drawEmptyListMarker(
                    selection: selectedRange(), attributes: typingAttributes, origin: textContainerOrigin, in: container)
            }
            guard let layout = layoutManager as? CodeLayoutManager,
                let rect = emptyTaskMarkerDrawingRect()
            else { return }
            layout.drawTaskMarker(
                checked: typingAttributes[.yoursTaskChecked] as? Bool ?? false,
                hovered: isHoveringEmptyTask,
                in: rect
            )
        }
        private func drawQuoteDecorations() {
            guard let layout = layoutManager as? CodeLayoutManager,
                let container = textContainer
            else { return }
            let origin = textContainerOrigin
            let localVisible = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphs = layout.glyphRange(forBoundingRect: localVisible, in: container)
            let emptyBar = emptyQuoteBarDrawingRect()
            let mergedEmptyBar = layout.drawQuoteBars(
                forGlyphRange: glyphs,
                at: origin,
                trailingEmptyBar: emptyBar
            )
            if let rect = emptyBar, !mergedEmptyBar {
                NSColor.labelColor.withAlphaComponent(0.22).setFill()
                layout.fill(rect, radius: 1)
            }
        }
        var editLink: (() -> Void)?
        var refreshTables: (() -> Void)?
        override func accessibilityChildren() -> [Any]? {
            (super.accessibilityChildren() ?? []) + subviews.filter { $0 !== quoteDecorationView }
        }
        override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
            guard let storage = textStorage, let layout = layoutManager as? CodeLayoutManager else { return nil }
            let source = storage.string as NSString
            var actions: [NSAccessibilityCustomAction] = []
            var location = 0
            while location < storage.length {
                let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
                if let marker = layout.taskMarkerIndex(in: paragraph) {
                    let checked = storage.attribute(.yoursTaskChecked, at: marker, effectiveRange: nil) as? Bool ?? false
                    let text = source.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = checked ? L10n.markIncomplete(text) : L10n.markComplete(text)
                    actions.append(
                        NSAccessibilityCustomAction(name: name) { [weak self] in
                            self?.toggleTask?(marker) ?? false
                        })
                }
                let next = NSMaxRange(paragraph)
                if next <= location { break }
                location = next
            }
            return actions.isEmpty ? nil : actions
        }
        override var textContainerOrigin: NSPoint {
            // AppKit compensates for negative horizontal code fragments and for
            // the reserved header above a tall document's first glyph. Both
            // offsets belong to the code viewport, not the document origin.
            NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        }

        override func layout() {
            super.layout()
            quoteDecorationView?.frame = bounds
            refreshTables?()
            window?.invalidateCursorRects(for: self)
        }
        override func resetCursorRects() {
            super.resetCursorRects()
            if let layout = layoutManager as? CodeLayoutManager,
                let rect = emptyTaskMarkerDrawingRect()
            {
                addCursorRect(layout.taskMarkerHitRect(for: rect), cursor: .pointingHand)
            }
            guard let layout = layoutManager as? CodeLayoutManager, let container = textContainer,
                let storage = textStorage, storage.length > 0
            else { return }
            layout.ensureLayout(for: container)
            let origin = textContainerOrigin
            let localVisible = visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphs = layout.glyphRange(forBoundingRect: localVisible, in: container)
            let visible = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let source = storage.string as NSString
            var location = source.paragraphRange(for: NSRange(location: visible.location, length: 0)).location
            let end = min(storage.length, NSMaxRange(visible))
            while location < end {
                let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
                if let marker = layout.taskMarkerIndex(in: paragraph), let rect = layout.taskMarkerHitRect(at: marker) {
                    addCursorRect(rect.offsetBy(dx: origin.x, dy: origin.y), cursor: .pointingHand)
                }
                let next = NSMaxRange(paragraph)
                if next <= location { break }
                location = next
            }
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let taskTrackingArea { removeTrackingArea(taskTrackingArea) }
            let trackingArea = NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(trackingArea)
            taskTrackingArea = trackingArea
        }
        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            updateHoveredTask(with: event)
            updateHoveredLink(at: convert(event.locationInWindow, from: nil))
            cursorUpdate(with: event)
        }
        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            updateHoveredTask(with: event)
            updateHoveredLink(at: convert(event.locationInWindow, from: nil))
            cursorUpdate(with: event)
        }
        private func prepareCodeMovement(down: Bool) {
            guard !hasMarkedText(), let layout = layoutManager as? CodeLayoutManager, let container = textContainer else { return }
            let selection = selectedRange()
            layout.prepareCodeVerticalMovement(from: down ? NSMaxRange(selection) : selection.location, down: down, in: container)
        }

        override func moveUp(_ sender: Any?) {
            prepareCodeMovement(down: false)
            super.moveUp(sender)
        }
        override func moveDown(_ sender: Any?) {
            prepareCodeMovement(down: true)
            super.moveDown(sender)
        }
        override func moveUpAndModifySelection(_ sender: Any?) {
            prepareCodeMovement(down: false)
            super.moveUpAndModifySelection(sender)
        }
        override func moveDownAndModifySelection(_ sender: Any?) {
            prepareCodeMovement(down: true)
            super.moveDownAndModifySelection(sender)
        }

        func scrollCode(with event: NSEvent) -> Bool {
            let horizontal =
                event.modifierFlags.contains(.shift) && event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            let verticalDelta = event.modifierFlags.contains(.shift) ? 0 : event.scrollingDeltaY
            let vertical = abs(verticalDelta) >= abs(horizontal)
            if let layout = layoutManager as? CodeLayoutManager, let container = textContainer {
                let point = convert(event.locationInWindow, from: nil)
                let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
                if let id = layout.scrollableCode(at: local, in: container, vertical: vertical) {
                    if vertical {
                        layout.scrollCodeVertically(id: id, delta: -verticalDelta, in: container, showIndicator: true)
                    } else {
                        layout.scrollCode(id: id, delta: -horizontal, in: container, showIndicator: true)
                    }
                    needsDisplay = true
                    refreshTables?()
                    return true
                }
            }
            return false
        }

        override func scrollWheel(with event: NSEvent) {
            if scrollCode(with: event) { return }
            super.scrollWheel(with: event)
            refreshTables?()
        }

        override func cursorUpdate(with event: NSEvent) {
            // This text view also receives tracking events below SwiftUI overlays.
            // Let the foreground control win instead of overwriting its hand cursor.
            if let cursor = PointingHandRegionView.cursor(at: event.locationInWindow, in: window) {
                cursor.set()
                return
            }
            let point = convert(event.locationInWindow, from: nil)
            if let header = subviews.compactMap({ $0 as? CodeHeaderHostingView }).first(where: { $0.frame.contains(point) }) {
                header.cursor(at: header.convert(point, from: self)).set()
            } else if taskMarker(at: event) != nil || isEmptyTaskMarker(at: event) || linkRange(at: point) != nil {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.iBeam.set()
            }
        }
        override func mouseExited(with event: NSEvent) {
            (layoutManager as? CodeLayoutManager)?.hoveredLinkRange = nil
            (layoutManager as? CodeLayoutManager)?.hoveredTaskMarker = nil
            isHoveringEmptyTask = false
            super.mouseExited(with: event)
        }
        override func didChangeText() {
            (layoutManager as? CodeLayoutManager)?.clearLinkHover()
            super.didChangeText()
        }

        func updateHoveredLink(at point: CGPoint) {
            (layoutManager as? CodeLayoutManager)?.hoveredLinkRange = linkRange(at: point)
        }

        private func linkRange(at point: CGPoint) -> NSRange? {
            guard let layout = layoutManager as? CodeLayoutManager, let textContainer, let storage = textStorage else { return nil }
            let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            layout.ensureLayout(for: textContainer)
            let glyph = layout.glyphIndex(for: local, in: textContainer)
            guard glyph < layout.numberOfGlyphs,
                layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).contains(local)
            else { return nil }
            let index = layout.characterIndexForGlyph(at: glyph)
            var range = NSRange()
            guard index < storage.length,
                storage.attribute(.link, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil
            else { return nil }
            return range
        }
        private func updateHoveredTask(with event: NSEvent) {
            guard let layout = layoutManager as? CodeLayoutManager else { return }
            let marker = taskMarker(at: event)
            layout.hoveredTaskMarker = marker
            isHoveringEmptyTask = isEmptyTaskMarker(at: event)
            if marker != nil || isHoveringEmptyTask { NSCursor.pointingHand.set() }
        }
        private func taskMarker(at event: NSEvent) -> Int? {
            guard let layout = layoutManager as? CodeLayoutManager, let textContainer else { return nil }
            let point = convert(event.locationInWindow, from: nil)
            let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            return layout.taskMarkerCharacter(at: local, in: textContainer)
        }
        private func isEmptyTaskMarker(at event: NSEvent) -> Bool {
            guard let layout = layoutManager as? CodeLayoutManager,
                let marker = emptyTaskMarkerDrawingRect()
            else { return false }
            let point = convert(event.locationInWindow, from: nil)
            return layout.taskMarkerHitRect(for: marker).contains(point)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if !event.modifierFlags.intersection([.command, .control]).isEmpty { discardInlineCodeBoundary() }
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers == "k", selectedRange().length > 0
            {
                editLink?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
        override func mouseDown(with event: NSEvent) {
            discardInlineCodeBoundary()
            let point = convert(event.locationInWindow, from: nil)
            if isEmptyTaskMarker(at: event), toggleEmptyTask?() == true {
                window?.makeFirstResponder(self)
                return
            }
            if let layoutManager, let textContainer {
                let local = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
                if let layout = layoutManager as? CodeLayoutManager, let storage = textStorage, storage.length > 0 {
                    var range = NSRange()
                    if let code = storage.attribute(.yoursCodeStyle, at: storage.length - 1, effectiveRange: &range) as? String,
                        code.hasPrefix("block:")
                    {
                        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                        if local.y > layout.codeBackgroundRect(forGlyphRange: glyphs, in: textContainer).maxY,
                            exitTrailingCode?() == true
                        {
                            window?.makeFirstResponder(self)
                            needsDisplay = true
                            return
                        }
                    }
                }
                if let layout = layoutManager as? CodeLayoutManager,
                    let marker = layout.taskMarkerCharacter(at: local, in: textContainer),
                    toggleTask?(marker) == true
                {
                    window?.makeFirstResponder(self)
                    return
                }
            }
            super.mouseDown(with: event)
            let click = convert(event.locationInWindow, from: nil)
            resolveInlineCodeTypingAttributes(at: CGPoint(x: click.x - textContainerOrigin.x, y: click.y - textContainerOrigin.y))
            selectionFinished?()
            resolveEmptyParagraphTypingAttributes()
        }

        func resolveInlineCodeTypingAttributes(at point: CGPoint) {
            guard selectedRange().length == 0, !hasMarkedText(),
                let range = inlineCodeRange(at: selectedRange().location),
                let layout = layoutManager as? CodeLayoutManager, let container = textContainer
            else { return }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let inside = layout.inlineCodeBackgroundRects(forGlyphRange: glyphs, in: container).contains { $0.contains(point) }
            setInlineCodeBoundary(inside: inside)
        }

        func resolveEmptyParagraphTypingAttributes() {
            // AppKit inherits attributes from the preceding character at a boundary.
            // An existing empty paragraph owns its format, including a body newline
            // directly after code. Resolve this only after a mouse selection, so
            // explicit toolbar formatting and keyboard continuation remain intact.
            if selectedRange().length == 0, !hasMarkedText(), let storage = textStorage {
                let source = storage.string as NSString
                let paragraph = source.paragraphRange(for: NSRange(location: min(selectedRange().location, source.length), length: 0))
                if paragraph.length > 0,
                    source.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    typingAttributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
                    didResolveTypingAttributes?()
                }
            }
        }
    }

    /// Native caret autoscroll and trackpad elasticity must never move the whole document sideways.
    final class ReadingClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var bounds = super.constrainBoundsRect(proposedBounds)
            bounds.origin.x = 0
            return bounds
        }
    }

    private final class ReadingScrollView: NSScrollView {
        override func scrollWheel(with event: NSEvent) {
            if (documentView as? ReadingMacTextView)?.scrollCode(with: event) == true { return }
            super.scrollWheel(with: event)
        }

        override func tile() {
            super.tile()
            guard let view = documentView as? NSTextView else { return }
            let inset = max(32, (contentSize.width - DocumentTypography.readingWidth) / 2)
            if view.textContainerInset.width != inset {
                view.textContainerInset = NSSize(width: inset, height: DocumentTypography.editorTopInset)
            }
        }
    }

    extension NativeRichTextEditor: NSViewRepresentable {
        func makeNSView(context: Context) -> NSScrollView {
            let scroll = ReadingScrollView()
            scroll.contentView = ReadingClipView()
            scroll.horizontalScrollElasticity = .none
            scroll.hasHorizontalScroller = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            let view = ReadingMacTextView(frame: scroll.contentView.bounds)
            view.selectionFocusChanged = { [weak coordinator = context.coordinator] focused in
                coordinator?.updateRenderedSelectionFocus(focused)
            }
            view.exitTrailingCode = { [weak coordinator = context.coordinator] in coordinator?.exitTrailingCode() ?? false }
            view.didResolveTypingAttributes = { [weak coordinator = context.coordinator] in coordinator?.publishSelection() }
            view.copyStructured = { [weak coordinator = context.coordinator] cut in coordinator?.copyStructured(cut: cut) ?? false }
            view.pasteStructured = { [weak coordinator = context.coordinator] in coordinator?.pasteStructured() ?? false }
            view.linkTextAttributes = NativeTextAttributes.linkTextAttributes
            view.displaysLinkToolTips = true
            #if os(iOS)
                view.tintColor = AppTheme.nativeAccent
            #endif
            #if os(iOS)
                view.moveLeftFromListStart = { [weak coordinator = context.coordinator] in coordinator?.moveLeftFromListStart() ?? false }
                view.backspaceAtParagraphStart = { [weak coordinator = context.coordinator] in
                    coordinator?.backspaceAtParagraphStart() ?? false
                }
            #endif
            view.suppressSlash = { [weak coordinator = context.coordinator] value in coordinator?.suppressSlashTrigger = value }
            #if os(macOS)
                view.dismissControlMenus = { [weak coordinator = context.coordinator] in coordinator?.dismissRootControls() }
                view.selectionFinished = { [weak coordinator = context.coordinator] in coordinator?.controlsAfterSelection() }
                view.selectionTrackingChanged = { [weak coordinator = context.coordinator] in
                    coordinator?.updateRenderedSelectionDuringTracking()
                }
            #endif
            view.refreshTables = { [weak coordinator = context.coordinator] in
                coordinator?.refreshTables()
                coordinator?.refreshControlPosition()
            }
            view.editLink = { [weak coordinator = context.coordinator] in coordinator?.parent.onEditLink() }
            view.toggleTask = { [weak coordinator = context.coordinator] index in coordinator?.toggleTask(at: index) ?? false }
            view.toggleEmptyTask = { [weak coordinator = context.coordinator] in coordinator?.toggleEmptyTask() ?? false }
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.autoresizingMask = [.width]
            view.minSize = .zero
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.replaceTextContainer(CodeTextContainer(size: view.textContainer?.size ?? .zero))
            view.textContainer?.replaceLayoutManager(CodeLayoutManager())
            (view.layoutManager as? CodeLayoutManager)?.codeDisplayView = view
            view.textContainer?.widthTracksTextView = true
            scroll.documentView = view
            view.isRichText = true
            view.usesRolloverButtonForSelection = false
            view.allowsUndo = true
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.textContainerInset = NSSize(width: 32, height: DocumentTypography.editorTopInset)
            view.setAccessibilityLabel(L10n.string("note.body.accessibility_label"))
            view.setAccessibilityIdentifier("note-editor")
            view.textStorage?.setAttributedString(NativeTextAttributes.native(text, context: fontContext))
            view.delegate = context.coordinator
            context.coordinator.textView = view
            commandBridge?.openLink = { [weak coordinator = context.coordinator] in coordinator?.presentControlDetail("link") }
            commandBridge?.insertTable = { [weak coordinator = context.coordinator] in coordinator?.presentControlDetail("table") }
            commandBridge?.perform = { [weak coordinator = context.coordinator] action in
                guard let coordinator else { return }
                coordinator.performControlAction(action, range: coordinator.currentSelection)
            }
            context.coordinator.update(self)
            if focusWhenEmpty, text.characters.isEmpty {
                DispatchQueue.main.async { [weak view] in view?.window?.makeFirstResponder(view) }
            }
            return scroll
        }

        func updateNSView(_ nsView: NSScrollView, context: Context) { context.coordinator.update(self) }
        static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) { coordinator.dismissControls() }
    }

    extension NativeRichTextEditor.Coordinator: NSTextViewDelegate {
        func updateRenderedSelectionDuringTracking() {
            guard let textView else { return }
            renderedContents.updateSelection(in: textView, tracking: true)
        }

        func updateRenderedSelectionFocus(_ focused: Bool) {
            renderedContents.updateSelectionEmphasis(focused)
        }
        func textDidEndEditing(_ notification: Notification) { dismissRootControls() }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            intercept(range: affectedCharRange, replacement: replacementString)
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let controlKeys = [
                "moveUp:": "up", "moveDown:": "down", "insertNewline:": "return", "insertTab:": "tab", "cancelOperation:": "escape",
            ]
            if let key = controlKeys[NSStringFromSelector(selector)], handleControlKey(key) { return true }
            if selector == #selector(NSResponder.moveLeft(_:)) || selector == #selector(NSResponder.moveBackward(_:)) {
                if moveLeftFromListStart() { return true }
            }
            if selector == #selector(NSResponder.deleteBackward(_:)), backspaceAtParagraphStart() { return true }
            if selector == #selector(NSResponder.deleteBackward(_:)),
                textView.string.isEmpty,
                textView.selectedRange() == NSRange(location: 0, length: 0)
            {
                // AppKit does not ask shouldChangeTextIn for a no-op deletion at the
                // beginning of an empty document. Route the command through the same
                // contextual edit so an empty heading/quote/code block can return to body.
                if exitEmptyQuote() { return true }
                return !intercept(range: textView.selectedRange(), replacement: "")
            }
            if selector == #selector(NSResponder.insertBacktab(_:)) {
                return !intercept(range: textView.selectedRange(), replacement: "\u{19}")
            }
            if selector == #selector(NSResponder.insertTab(_:)) {
                return !intercept(range: textView.selectedRange(), replacement: "\t")
            }
            if selector == #selector(NSResponder.insertLineBreak(_:)) {
                textView.insertText("\u{2028}", replacementRange: textView.selectedRange())
                return true
            }
            return false
        }
        func textDidChange(_ notification: Notification) {
            restoreEmptyQuoteTypingAttributesFromPreviousValue()
            if let attributes = pendingTypingAttributesAfterInlineDeletion {
                textView?.typingAttributes = attributes
                pendingTypingAttributesAfterInlineDeletion = nil
            }
            let affected = pendingNativeEditRange
            pendingNativeEditRange = nil
            publish(around: affected)
            controlsAfterTyping()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            if let previous = notification.userInfo?["NSOldSelectedCharacterRange"] as? NSValue,
                previous.rangeValue.length > 0, let textView,
                previous.rangeValue != textView.selectedRange()
            {
                // Native selection invalidation can leave fractional-pixel edges
                // around our custom line metrics. Repaint the viewport when a
                // highlighted range changes; caret-only movement stays incremental.
                textView.setNeedsDisplay(textView.visibleRect)
            }
            (textView as? ReadingMacTextView)?.updateEmptyQuoteBar()
            publishSelection()
            controlsAfterSelection()
        }
    }
#else
    private final class ReadingTextView: UITextView, UIGestureRecognizerDelegate {
        private lazy var codePan = UIPanGestureRecognizer(target: self, action: #selector(scrollCodeHorizontally(_:)))
        var suppressSlash: ((Bool) -> Void)?
        private var panningCodeID: String?
        private var panningCodeVertically = false

        func installCodeScrolling() {
            codePan.delegate = self
            addGestureRecognizer(codePan)
            panGestureRecognizer.require(toFail: codePan)
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === codePan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
            let velocity = codePan.velocity(in: self)
            guard let layout = layoutManager as? CodeLayoutManager else { return false }
            panningCodeVertically = abs(velocity.y) >= abs(velocity.x)
            let point = codePan.location(in: self)
            panningCodeID = layout.scrollableCode(
                at: CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top), in: textContainer,
                vertical: panningCodeVertically)
            return panningCodeID != nil
        }

        @objc private func scrollCodeHorizontally(_ recognizer: UIPanGestureRecognizer) {
            guard let id = panningCodeID, let layout = layoutManager as? CodeLayoutManager else { return }
            if panningCodeVertically {
                layout.scrollCodeVertically(id: id, delta: -recognizer.translation(in: self).y, in: textContainer, showIndicator: true)
            } else {
                layout.scrollCode(id: id, delta: -recognizer.translation(in: self).x, in: textContainer, showIndicator: true)
            }
            recognizer.setTranslation(.zero, in: self)
            setNeedsDisplay()
            refreshTables?()
            if recognizer.state == .ended || recognizer.state == .cancelled { panningCodeID = nil }
        }

        var exitEmptyQuote: (() -> Bool)?
        var copyStructured: ((Bool) -> Bool)?
        var pasteStructured: (() -> Bool)?
        override func copy(_ sender: Any?) { if copyStructured?(false) != true { super.copy(sender) } }
        override func cut(_ sender: Any?) { if copyStructured?(true) != true { super.cut(sender) } }
        override func paste(_ sender: Any?) {
            suppressSlash?(true)
            defer { suppressSlash?(false) }
            if pasteStructured?() != true { super.paste(sender) }
        }
        var controlKey: ((String) -> Bool)?
        var moveLeftFromListStart: (() -> Bool)?
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if markedTextRange == nil, presses.count == 1, let key = presses.first?.key {
                let keys: [UIKeyboardHIDUsage: String] = [
                    .keyboardUpArrow: "up", .keyboardDownArrow: "down", .keyboardReturnOrEnter: "return", .keyboardEscape: "escape",
                    .keyboardTab: "tab",
                ]
                if let name = keys[key.keyCode], controlKey?(name) == true { return }
            }
            if markedTextRange == nil, presses.count == 1, let key = presses.first?.key,
                key.keyCode == .keyboardUpArrow || key.keyCode == .keyboardDownArrow,
                let layout = layoutManager as? CodeLayoutManager
            {
                let down = key.keyCode == .keyboardDownArrow
                layout.prepareCodeVerticalMovement(
                    from: down ? NSMaxRange(selectedRange) : selectedRange.location,
                    down: down, in: textContainer)
            }
            if presses.count == 1, let key = presses.first?.key, key.keyCode == .keyboardLeftArrow,
                key.modifierFlags.isEmpty, moveLeftFromListStart?() == true
            {
                return
            }
            super.pressesBegan(presses, with: event)
        }
        var backspaceAtParagraphStart: (() -> Bool)?
        override func deleteBackward() {
            if backspaceAtParagraphStart?() == true { return }
            if text.isEmpty, selectedRange == NSRange(location: 0, length: 0), exitEmptyQuote?() == true { return }
            super.deleteBackward()
        }
        override func draw(_ rect: CGRect) {
            super.draw(rect)
            if let layout = layoutManager as? CodeLayoutManager {
                layout.drawEmptyListMarker(
                    selection: selectedRange, attributes: typingAttributes,
                    origin: CGPoint(x: textContainerInset.left, y: textContainerInset.top), in: textContainer)
            }
            let source = text as NSString
            let insertion = min(selectedRange.location, source.length)
            let paragraph = source.paragraphRange(for: NSRange(location: insertion, length: 0))
            if selectedRange.length == 0,
                source.substring(with: paragraph).trimmingCharacters(in: .newlines).isEmpty,
                typingAttributes[.yoursQuote] as? Bool == true,
                paragraph.location >= textStorage.length
                    || textStorage.attribute(.yoursQuote, at: paragraph.location, effectiveRange: nil) as? Bool != true,
                let layout = layoutManager as? CodeLayoutManager
            {
                let font = typingAttributes[.font] as? UIFont ?? .systemFont(ofSize: DocumentTypography.bodySize)
                UIColor.label.withAlphaComponent(0.22).setFill()
                layout.fill(
                    layout.emptyQuoteBarRect(at: insertion, font: font, in: textContainer).offsetBy(
                        dx: textContainerInset.left,
                        dy: textContainerInset.top
                    ), radius: 1)
            }
            if let layout = layoutManager as? CodeLayoutManager,
                let marker = emptyTaskMarkerDrawingRect()
            {
                layout.drawTaskMarker(
                    checked: typingAttributes[.yoursTaskChecked] as? Bool ?? false,
                    hovered: false,
                    in: marker
                )
            }
        }
        var refreshTables: (() -> Void)?
        var toggleTask: ((Int) -> Bool)?
        var toggleEmptyTask: (() -> Bool)?
        private func emptyTaskMarkerDrawingRect() -> CGRect? {
            let source = text as NSString
            let insertion = min(selectedRange.location, source.length)
            let paragraph = source.paragraphRange(for: NSRange(location: insertion, length: 0))
            guard selectedRange.length == 0,
                source.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                typingAttributes[.yoursParagraphStyle] as? String == "task",
                typingAttributes[.yoursTaskChecked] is Bool,
                let layout = layoutManager as? CodeLayoutManager
            else { return nil }
            if paragraph.location < textStorage.length, layout.taskMarkerIndex(in: paragraph) != nil { return nil }
            let font =
                typingAttributes[.font] as? UIFont
                ?? .systemFont(ofSize: DocumentTypography.bodySize * DocumentTypography.readingScale)
            return layout.emptyTaskMarkerRect(
                at: insertion,
                font: font,
                quoted: typingAttributes[.yoursQuote] as? Bool == true,
                in: textContainer
            ).offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
        }
        @objc func tappedTask(_ recognizer: UITapGestureRecognizer) {
            let point = recognizer.location(in: self)
            if let layout = layoutManager as? CodeLayoutManager,
                let marker = emptyTaskMarkerDrawingRect(),
                layout.taskMarkerHitRect(for: marker).contains(point)
            {
                _ = toggleEmptyTask?()
                setNeedsDisplay()
                return
            }
            let local = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
            guard let layout = layoutManager as? CodeLayoutManager,
                let marker = layout.taskMarkerCharacter(at: local, in: textContainer)
            else { return }
            _ = toggleTask?(marker)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if gestureRecognizer === codePan { return true }
            guard gestureRecognizer is UITapGestureRecognizer,
                let layout = layoutManager as? CodeLayoutManager
            else { return true }
            let point = touch.location(in: self)
            if let marker = emptyTaskMarkerDrawingRect(), layout.taskMarkerHitRect(for: marker).contains(point) {
                return true
            }
            let local = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
            return layout.taskMarkerCharacter(at: local, in: textContainer) != nil
        }

        private func refreshTaskAccessibilityActions() {
            let source = textStorage.string as NSString
            guard textStorage.length > 0, let layout = layoutManager as? CodeLayoutManager else {
                accessibilityCustomActions = nil
                return
            }
            var actions: [UIAccessibilityCustomAction] = []
            var location = 0
            while location < textStorage.length {
                let paragraph = source.paragraphRange(for: NSRange(location: location, length: 0))
                if let marker = layout.taskMarkerIndex(in: paragraph) {
                    let checked = textStorage.attribute(.yoursTaskChecked, at: marker, effectiveRange: nil) as? Bool ?? false
                    let text = source.substring(with: paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = checked ? L10n.markIncomplete(text) : L10n.markComplete(text)
                    actions.append(
                        UIAccessibilityCustomAction(name: name) { [weak self] _ in
                            self?.toggleTask?(marker) ?? false
                        })
                }
                let next = NSMaxRange(paragraph)
                if next <= location { break }
                location = next
            }
            accessibilityCustomActions = actions.isEmpty ? nil : actions
        }

        override func layoutSubviews() {
            let inset = max(24, (bounds.width - DocumentTypography.readingWidth) / 2)
            if textContainerInset.left != inset {
                textContainerInset = UIEdgeInsets(top: DocumentTypography.editorTopInset, left: inset, bottom: 40, right: inset)
            }
            super.layoutSubviews()
            // Wide code fragments scroll inside their block, never the whole document.
            if contentSize.width != bounds.width { contentSize.width = bounds.width }
            refreshTables?()
            refreshTaskAccessibilityActions()
        }
    }

    extension NativeRichTextEditor: UIViewRepresentable {
        func makeUIView(context: Context) -> UITextView {
            let storage = NSTextStorage()
            let layout = CodeLayoutManager()
            storage.addLayoutManager(layout)
            let container = CodeTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            container.widthTracksTextView = true
            layout.addTextContainer(container)
            let view = ReadingTextView(frame: .zero, textContainer: container)
            layout.codeDisplayView = view
            view.installCodeScrolling()
            view.controlKey = { [weak coordinator = context.coordinator] key in coordinator?.handleControlKey(key) ?? false }
            view.exitEmptyQuote = { [weak coordinator = context.coordinator] in coordinator?.exitEmptyQuote() ?? false }
            view.copyStructured = { [weak coordinator = context.coordinator] cut in coordinator?.copyStructured(cut: cut) ?? false }
            view.pasteStructured = { [weak coordinator = context.coordinator] in coordinator?.pasteStructured() ?? false }
            view.linkTextAttributes = NativeTextAttributes.linkTextAttributes
            #if os(iOS)
                view.tintColor = AppTheme.nativeAccent
            #endif
            #if os(iOS)
                view.moveLeftFromListStart = { [weak coordinator = context.coordinator] in coordinator?.moveLeftFromListStart() ?? false }
                view.backspaceAtParagraphStart = { [weak coordinator = context.coordinator] in
                    coordinator?.backspaceAtParagraphStart() ?? false
                }
            #endif
            view.suppressSlash = { [weak coordinator = context.coordinator] value in coordinator?.suppressSlashTrigger = value }
            #if os(macOS)
                view.dismissControlMenus = { [weak coordinator = context.coordinator] in coordinator?.dismissRootControls() }
                view.selectionFinished = { [weak coordinator = context.coordinator] in coordinator?.controlsAfterSelection() }
            #endif
            view.refreshTables = { [weak coordinator = context.coordinator] in
                coordinator?.refreshTables()
                coordinator?.refreshControlPosition()
            }
            view.toggleTask = { [weak coordinator = context.coordinator] index in coordinator?.toggleTask(at: index) ?? false }
            view.toggleEmptyTask = { [weak coordinator = context.coordinator] in coordinator?.toggleEmptyTask() ?? false }
            let tap = UITapGestureRecognizer(target: view, action: #selector(ReadingTextView.tappedTask(_:)))
            tap.delegate = view
            tap.cancelsTouchesInView = true
            view.addGestureRecognizer(tap)
            view.font = .preferredFont(forTextStyle: .body)
            view.adjustsFontForContentSizeCategory = true
            view.textContainerInset = UIEdgeInsets(top: DocumentTypography.editorTopInset, left: 8, bottom: 40, right: 8)
            view.allowsEditingTextAttributes = true
            view.smartQuotesType = .no
            view.smartDashesType = .no
            view.accessibilityLabel = L10n.string("note.body.accessibility_label")
            view.accessibilityIdentifier = "note-editor"
            view.attributedText = NativeTextAttributes.native(text, context: fontContext)
            view.delegate = context.coordinator
            context.coordinator.textView = view
            commandBridge?.openLink = { [weak coordinator = context.coordinator] in coordinator?.presentControlDetail("link") }
            commandBridge?.insertTable = { [weak coordinator = context.coordinator] in coordinator?.presentControlDetail("table") }
            commandBridge?.perform = { [weak coordinator = context.coordinator] action in
                guard let coordinator else { return }
                coordinator.performControlAction(action, range: coordinator.currentSelection)
            }
            context.coordinator.update(self)
            if focusWhenEmpty, text.characters.isEmpty {
                DispatchQueue.main.async { [weak view] in view?.becomeFirstResponder() }
            }
            return view
        }
        func updateUIView(_ uiView: UITextView, context: Context) { context.coordinator.update(self) }
        static func dismantleUIView(_ uiView: UITextView, coordinator: Coordinator) { coordinator.dismissControls() }
    }

    extension NativeRichTextEditor.Coordinator: UITextViewDelegate {
        func textView(_ textView: UITextView, editMenuForTextInRanges ranges: [NSValue], suggestedActions: [UIMenuElement]) -> UIMenu? {
            return formattingMenu(ranges: ranges, suggestedActions: suggestedActions)
        }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            return formattingMenu(ranges: [NSValue(range: range)], suggestedActions: suggestedActions)
        }

        private func formattingMenu(ranges: [NSValue], suggestedActions: [UIMenuElement]) -> UIMenu {
            guard ranges.count == 1, !hasMarkedText else { return UIMenu(children: suggestedActions) }
            controlsAfterSelection()
            let expectedRevision = revision
            let range = ranges[0].rangeValue
            let actions = controls.state.items.map { item in
                UIAction(
                    title: item.title, image: UIImage(systemName: item.symbol), attributes: item.enabled ? [] : .disabled,
                    state: item.mixed ? .mixed : item.active ? .on : .off
                ) { [weak self] _ in
                    guard let self, self.revision == expectedRevision else { return }
                    if item.id == "link" {
                        self.presentControlDetail("link", range: range)
                    } else {
                        self.performControlAction(item.action, range: range)
                    }
                }
            }
            let formatting = UIMenu(title: L10n.string("format.menu"), identifier: .format, children: actions)
            var replaced = false
            func replacingSystemFormatting(_ element: UIMenuElement) -> UIMenuElement {
                guard let menu = element as? UIMenu else { return element }
                if menu.identifier == .format || menu.identifier == .textStyle {
                    replaced = true
                    return formatting
                }
                return menu.replacingChildren(menu.children.map(replacingSystemFormatting))
            }
            var children = suggestedActions.map(replacingSystemFormatting)
            if !replaced { children.append(formatting) }
            return UIMenu(children: children)
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            return intercept(range: range, replacement: text)
        }
        func textViewDidChange(_ textView: UITextView) {
            restoreEmptyQuoteTypingAttributesFromPreviousValue()
            if let attributes = pendingTypingAttributesAfterInlineDeletion {
                textView.typingAttributes = attributes
                pendingTypingAttributesAfterInlineDeletion = nil
            }
            let affected = pendingNativeEditRange
            pendingNativeEditRange = nil
            publish(around: affected)
            controlsAfterTyping()
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            textView.setNeedsDisplay()
            publishSelection()
            controlsAfterSelection()
        }
    }
#endif
