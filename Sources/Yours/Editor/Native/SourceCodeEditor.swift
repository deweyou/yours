import SwiftUI

#if os(macOS)
    private typealias SourceColor = NSColor
#else
    private typealias SourceColor = UIColor
#endif

/// Temporary syntax colors never enter source, undo history, or IME marked text.
@MainActor
private enum SourceSyntax {
    static func highlight(_ source: String, kind: RenderedContent.Kind, layout: NSLayoutManager) {
        let whole = NSRange(location: 0, length: source.utf16.count)
        #if os(macOS)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
        #else
            layout.textStorage?.beginEditing()
            layout.textStorage?.addAttribute(.foregroundColor, value: UIColor.label, range: whole)
            defer { layout.textStorage?.endEditing() }
        #endif
        let patterns: [(String, SourceColor)] =
            kind == .mermaid
            ? [
                (
                    #"\b(graph|flowchart|sequenceDiagram|classDiagram|stateDiagram|erDiagram|gantt|pie|mindmap|subgraph|end|direction|participant|actor|Note|loop|alt|else|opt|rect|par|and|critical|break|TD|TB|LR|RL|BT)\b"#,
                    .systemPurple
                ),
                (#"[-=.]+(?:>|o|x)|<[-=.]+"#, .systemBlue),
                (#"\"[^\"\n]*\"|'[^'\n]*'"#, .systemBrown),
                (#"%%[^\n]*"#, .systemGray),
            ]
            : [(#"\\[a-zA-Z]+"#, .systemPurple), (#"[{}_^]"#, .systemBlue), (#"(?<!\\)%[^\n]*"#, .systemGray)]
        for (pattern, color) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in expression.matches(in: source, range: whole) {
                #if os(macOS)
                    layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: match.range)
                #else
                    layout.textStorage?.addAttribute(.foregroundColor, value: color, range: match.range)
                #endif
            }
        }
    }
}

#if os(macOS)
    struct SourceCodeEditor: NSViewRepresentable {
        @Binding var source: String
        let kind: RenderedContent.Kind
        var onCancel: (() -> Void)? = nil
        var onSubmit: (() -> Void)? = nil

        func makeNSView(context: Context) -> NSScrollView { makeEditor() }

        func makeEditor() -> NSScrollView {
            let scroll = SourceScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder
            let view = SourceTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            view.minSize = .zero
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.onCancel = onCancel
            view.onSubmit = onSubmit
            view.kind = kind
            view.isRichText = false
            view.allowsUndo = true
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            view.isContinuousSpellCheckingEnabled = false
            view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            view.textColor = .labelColor
            view.backgroundColor = .textBackgroundColor
            view.textContainerInset = NSSize(width: 10, height: 12)
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            view.string = source
            view.setAccessibilityIdentifier("rendered-source")
            view.setAccessibilityLabel(kind == .mermaid ? "Mermaid" : "LaTeX")
            view.onChange = { source = $0 }
            scroll.documentView = view
            if kind == .mermaid {
                scroll.hasVerticalRuler = true
                scroll.verticalRulerView = SourceLineRuler(scrollView: scroll, orientation: .verticalRuler)
                scroll.rulersVisible = true
            }
            view.refreshSyntax()
            return scroll
        }

        func updateNSView(_ scroll: NSScrollView, context: Context) {
            guard let view = scroll.documentView as? SourceTextView else { return }
            view.onChange = { source = $0 }
            view.onCancel = onCancel
            view.onSubmit = onSubmit
            // Native editing owns composition and its undo stack; do not reset storage on keystrokes.
            if view.string != source, !view.hasMarkedText() {
                view.string = source
                view.refreshSyntax()
            }
        }
    }

    private final class SourceScrollView: NSScrollView {
        override func tile() {
            super.tile()
            guard let view = documentView as? NSTextView else { return }
            // A ruler changes the clip width during initial SwiftUI layout. Keep the
            // document usable even when the representable first receives a zero size.
            let size = contentView.bounds.size
            view.setFrameSize(NSSize(width: max(1, size.width), height: max(view.frame.height, size.height)))
            view.minSize = NSSize(width: 0, height: size.height)
        }
    }

    private final class SourceTextView: NSTextView {
        var onCancel: (() -> Void)?
        var onSubmit: (() -> Void)?
        var kind = RenderedContent.Kind.inlineMath
        var onChange: (String) -> Void = { _ in }
        private var focusedInitially = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window, !focusedInitially {
                focusedInitially = true
                window.makeFirstResponder(self)
            }
        }
        override func didChangeText() {
            super.didChangeText()
            guard !hasMarkedText() else { return }
            refreshSyntax()
            onChange(string)
        }
        override func unmarkText() {
            super.unmarkText()
            refreshSyntax()
            onChange(string)
        }
        func refreshSyntax() {
            if let layoutManager { SourceSyntax.highlight(string, kind: kind, layout: layoutManager) }
            enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
        override func cancelOperation(_ sender: Any?) {
            if let onCancel, !hasMarkedText() { onCancel() } else { super.cancelOperation(sender) }
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                !hasMarkedText(), let onSubmit
            {
                onSubmit()
            } else {
                super.keyDown(with: event)
            }
        }
        override func insertTab(_ sender: Any?) { insertText("    ", replacementRange: selectedRange()) }
        override func insertNewline(_ sender: Any?) {
            guard !hasMarkedText() else {
                super.insertNewline(sender)
                return
            }
            let selection = selectedRange()
            let text = string as NSString
            let paragraph = text.paragraphRange(for: NSRange(location: selection.location, length: 0))
            let prefix = text.substring(with: NSRange(location: paragraph.location, length: selection.location - paragraph.location))
            let indentation = prefix.prefix { $0 == " " || $0 == "\t" }
            insertText("\n" + indentation, replacementRange: selection)
        }
    }

    private final class SourceLineRuler: NSRulerView {
        override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
            super.init(scrollView: scrollView, orientation: orientation)
            ruleThickness = 36
            clipsToBounds = true
        }
        required init(coder: NSCoder) { super.init(coder: coder) }
        override func drawHashMarksAndLabels(in rect: NSRect) {
            guard let view = scrollView?.documentView as? NSTextView, let layout = view.layoutManager
            else { return }
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
            let source = view.string as NSString
            var location = 0
            var number = 1
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor,
            ]
            while location <= source.length {
                let line: NSRect
                if location < source.length {
                    let glyph = layout.glyphIndexForCharacter(at: location)
                    line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                } else {
                    line = layout.extraLineFragmentRect
                }
                let point = convert(NSPoint(x: 0, y: line.minY + view.textContainerOrigin.y + 1), from: view)
                if point.y + line.height >= rect.minY && point.y <= rect.maxY {
                    let label = "\(number)" as NSString
                    label.draw(
                        at: NSPoint(x: ruleThickness - label.size(withAttributes: attributes).width - 8, y: point.y),
                        withAttributes: attributes)
                }
                if location == source.length { break }
                location = NSMaxRange(source.paragraphRange(for: NSRange(location: location, length: 0)))
                number += 1
                if location == source.length && !view.string.hasSuffix("\n") { break }
            }
        }
    }
#else
    struct SourceCodeEditor: UIViewRepresentable {
        @Binding var source: String
        let kind: RenderedContent.Kind
        var onCancel: (() -> Void)? = nil
        var onSubmit: (() -> Void)? = nil
        func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
        func makeUIView(context: Context) -> UITextView {
            let view = SourceMobileTextView(usingTextLayoutManager: false)
            view.onCancel = onCancel
            view.onSubmit = onSubmit
            view.kind = kind
            view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
            view.backgroundColor = .secondarySystemBackground
            view.textColor = .label
            view.autocorrectionType = .no
            view.autocapitalizationType = .none
            view.smartQuotesType = .no
            view.smartDashesType = .no
            view.textContainerInset = UIEdgeInsets(top: 12, left: kind == .mermaid ? 42 : 10, bottom: 12, right: 10)
            view.text = source
            view.delegate = context.coordinator
            view.accessibilityIdentifier = "rendered-source"
            SourceSyntax.highlight(source, kind: kind, layout: view.layoutManager)
            return view
        }
        func updateUIView(_ view: UITextView, context: Context) {
            context.coordinator.parent = self
            if let editor = view as? SourceMobileTextView {
                editor.onCancel = onCancel
                editor.onSubmit = onSubmit
            }
            if view.text != source, view.markedTextRange == nil { view.text = source }
        }
        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: SourceCodeEditor
            init(parent: SourceCodeEditor) { self.parent = parent }
            func textViewDidChange(_ view: UITextView) {
                guard view.markedTextRange == nil else { return }
                parent.source = view.text
                SourceSyntax.highlight(view.text, kind: parent.kind, layout: view.layoutManager)
                view.setNeedsDisplay()
            }
        }
    }
    private final class SourceMobileTextView: UITextView {
        var onCancel: (() -> Void)?
        var onSubmit: (() -> Void)?
        var kind = RenderedContent.Kind.inlineMath
        private var focusedInitially = false
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, !focusedInitially {
                focusedInitially = true
                becomeFirstResponder()
            }
        }
        override var keyCommands: [UIKeyCommand]? {
            var commands = super.keyCommands ?? []
            if onCancel != nil {
                commands.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelSource)))
            }
            if onSubmit != nil { commands.append(UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(submitSource))) }
            return commands
        }
        @objc private func cancelSource() { if markedTextRange == nil { onCancel?() } }
        @objc private func submitSource() { if markedTextRange == nil { onSubmit?() } }
        override func insertText(_ inserted: String) {
            guard markedTextRange == nil else {
                super.insertText(inserted)
                return
            }
            if inserted == "\t" {
                super.insertText("    ")
            } else if inserted == "\n" {
                let string = text as NSString
                let paragraph = string.paragraphRange(for: NSRange(location: selectedRange.location, length: 0))
                let prefix = string.substring(
                    with: NSRange(location: paragraph.location, length: selectedRange.location - paragraph.location))
                super.insertText("\n" + prefix.prefix { $0 == " " || $0 == "\t" })
            } else {
                super.insertText(inserted)
            }
        }
        override func draw(_ rect: CGRect) {
            super.draw(rect)
            guard kind == .mermaid else { return }
            let source = text as NSString
            var location = 0
            var number = 1
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: UIColor.secondaryLabel,
            ]
            while location <= source.length {
                let line =
                    location < source.length
                    ? layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: location), effectiveRange: nil)
                    : layoutManager.extraLineFragmentRect
                let y = line.minY + textContainerInset.top + 1
                if y + line.height >= rect.minY && y <= rect.maxY {
                    let label = "\(number)" as NSString
                    label.draw(at: CGPoint(x: 32 - label.size(withAttributes: attributes).width, y: y), withAttributes: attributes)
                }
                if location == source.length { break }
                location = NSMaxRange(source.paragraphRange(for: NSRange(location: location, length: 0)))
                number += 1
                if location == source.length && !text.hasSuffix("\n") { break }
            }
        }
    }
#endif
