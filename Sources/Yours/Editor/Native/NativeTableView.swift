import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The attachment reserves document space; native controls draw and edit the cells.
final class TableTextAttachment: NSTextAttachment {
    let table: TableData

    @MainActor init(table: TableData) {
        self.table = table
        super.init(data: nil, ofType: nil)
        bounds = CGRect(x: 0, y: 0, width: 320, height: Self.height(for: table))
        #if os(macOS)
            attachmentCell = TableAttachmentCell(height: Self.height(for: table))
        #endif
    }

    required init?(coder: NSCoder) { nil }

    static func height(for table: TableData) -> CGFloat {
        CGFloat(table.rows.count) * DocumentTypography.tableRowHeight + DocumentTypography.tableControlsHeight
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect,
        glyphPosition position: CGPoint, characterIndex charIndex: Int
    ) -> CGRect {
        let width = textContainer.map { $0.size.width - 2 * $0.lineFragmentPadding } ?? lineFrag.width
        return CGRect(x: 0, y: 0, width: max(1, width), height: Self.height(for: table))
    }
}

#if os(macOS)
    /// TextKit 1 on macOS queries the cell for layout, rather than attachmentBounds.
    private final class TableAttachmentCell: NSTextAttachmentCell {
        nonisolated let tableHeight: CGFloat
        init(height: CGFloat) {
            tableHeight = height
            super.init(textCell: "")
        }
        required init(coder: NSCoder) {
            tableHeight = max(DocumentTypography.tableRowHeight, coder.decodeDouble(forKey: "tableHeight"))
            super.init(coder: coder)
        }
        override func encode(with coder: NSCoder) {
            super.encode(with: coder)
            coder.encode(tableHeight, forKey: "tableHeight")
        }
        nonisolated override func cellSize() -> NSSize { NSSize(width: 320, height: tableHeight) }
        nonisolated override func cellFrame(
            for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
            glyphPosition position: NSPoint, characterIndex charIndex: Int
        ) -> NSRect {
            NSRect(x: 0, y: 0, width: max(1, textContainer.size.width - 2 * textContainer.lineFragmentPadding), height: tableHeight)
        }
        override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {}
    }
#endif

@Observable @MainActor
final class NativeTableModel {
    var table: TableData
    var focusRequest = 0
    var onChange: (TableData) -> Void
    var onExit: () -> Void

    init(table: TableData, onChange: @escaping (TableData) -> Void, onExit: @escaping () -> Void) {
        self.table = table
        self.onChange = onChange
        self.onExit = onExit
    }

    func change(_ edit: (inout TableData) -> Void) {
        var next = table
        edit(&next)
        guard next != table else { return }
        table = next
        onChange(next)
    }
}

struct TableBlockView: View {
    @Environment(\.fontResolutionContext) private var fontContext
    @Bindable var model: NativeTableModel
    private struct Cell: Hashable {
        var row: Int
        var column: Int
    }
    @FocusState private var focusedCell: Cell?
    @State private var isHovering = false
    @State private var activeCell = Cell(row: 0, column: 0)

    var body: some View {
        VStack(spacing: 0) {
            controls
                .frame(height: DocumentTypography.tableControlsHeight)
            GeometryReader { geometry in
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        VStack(spacing: 0) {
                            ForEach(model.table.rows.indices, id: \.self) { row in
                                HStack(spacing: 0) {
                                    ForEach(model.table.alignments.indices, id: \.self) { column in
                                        cell(row: row, column: column)
                                            .frame(
                                                width: max(140, geometry.size.width / CGFloat(model.table.alignments.count)),
                                                height: DocumentTypography.tableRowHeight
                                            )
                                            .background(row == 0 ? Color.primary.opacity(0.035) : .clear)
                                            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.07)).frame(height: 0.5) }
                                            .overlay(alignment: .trailing) { Rectangle().fill(.primary.opacity(0.07)).frame(width: 0.5) }
                                            .id(Cell(row: row, column: column))
                                    }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: focusedCell) { _, cell in
                        if let cell { reader.scrollTo(cell, anchor: .center) }
                    }
                }
            }
            .overlay { Rectangle().strokeBorder(.primary.opacity(0.10), lineWidth: 0.5) }
        }
        .environment(\.locale, L10n.language.locale)
        .onHover { isHovering = $0 }
        .onChange(of: focusedCell) { _, cell in
            if let cell { activeCell = cell }
        }
        .onAppear { if model.focusRequest > 0 { focusedCell = Cell(row: 0, column: 0) } }
        .onChange(of: model.focusRequest) { _, _ in focusedCell = Cell(row: 0, column: 0) }
        .onChange(of: model.table.rows.count) { _, _ in clampActiveCell() }
        .onChange(of: model.table.alignments.count) { _, _ in clampActiveCell() }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Image(systemName: "tablecells")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Menu("table.title") {
                Button("table.row.insert_below") { insertRow() }
                Button("table.column.insert_right") {
                    let column = activeCell.column
                    model.change { $0.insertColumn(after: column) }
                    focusedCell = Cell(row: activeCell.row, column: column + 1)
                }
                Divider()
                alignmentButton("format.align.left", symbol: "text.alignleft", value: .left)
                alignmentButton("format.align.center", symbol: "text.aligncenter", value: .center)
                alignmentButton("format.align.right", symbol: "text.alignright", value: .right)
                Button("table.continue_typing") {
                    focusedCell = nil
                    model.onExit()
                }
                Divider()
                Button("table.row.delete", role: .destructive) {
                    let row = activeCell.row
                    model.change { $0.removeRow(at: row) }
                    clampActiveCell()
                }
                .disabled(model.table.rows.count <= 1)
                Button("table.column.delete", role: .destructive) {
                    let column = activeCell.column
                    model.change { $0.removeColumn(at: column) }
                    clampActiveCell()
                }
                .disabled(model.table.alignments.count <= 1)
            }
            .accessibilityIdentifier("table-actions")
            Menu {
                alignmentButton("format.align.left", symbol: "text.alignleft", value: .left)
                alignmentButton("format.align.center", symbol: "text.aligncenter", value: .center)
                alignmentButton("format.align.right", symbol: "text.alignright", value: .right)
            } label: {
                Image(systemName: alignmentSymbol)
            }
            .accessibilityLabel("table.column.alignment")
            .accessibilityIdentifier("table-alignment")
            .opacity(focusedCell != nil || isHovering ? 1 : 0)
            .accessibilityHidden(focusedCell == nil && !isHovering)
            Spacer(minLength: 0)
            Button {
                focusedCell = nil
                model.onExit()
            } label: {
                Image(systemName: "arrow.down.to.line")
            }
            .help("table.continue_typing")
            .accessibilityLabel("table.continue_typing")
            .accessibilityIdentifier("table-exit")
            .opacity(focusedCell != nil || isHovering ? 1 : 0)
            .accessibilityHidden(focusedCell == nil && !isHovering)
        }
        .font(.system(size: DocumentTypography.controlFontSize))
        .buttonStyle(.borderless)
        #if os(macOS)
            .menuStyle(.borderlessButton)
        #endif
        .padding(.horizontal, 8)
    }

    private func cell(row: Int, column: Int) -> some View {
        TextField(
            row == 0 ? L10n.string("table.header") : "",
            text: Binding(
                get: {
                    guard model.table.rows.indices.contains(row), model.table.alignments.indices.contains(column) else { return "" }
                    return model.table.rows[row][column]
                },
                set: { value in
                    guard model.table.rows.indices.contains(row), model.table.alignments.indices.contains(column) else { return }
                    model.change { $0.rows[row][column] = value }
                }
            )
        )
        .textFieldStyle(.plain)
        .font(Font(NativeTextAttributes.displayFont(Font.body.weight(row == 0 ? .semibold : .regular).resolve(in: fontContext).ctFont)))
        .foregroundStyle(Color(AppTheme.documentBody))
        .multilineTextAlignment(textAlignment(column))
        .padding(.horizontal, 10)
        .focused($focusedCell, equals: Cell(row: row, column: column))
        .accessibilityLabel(row == 0 ? L10n.tableHeader(column + 1) : L10n.tableCell(row + 1, column + 1))
        .accessibilityIdentifier("table-cell-\(row)-\(column)")
        .onSubmit {
            if row + 1 < model.table.rows.count {
                focusedCell = Cell(row: row + 1, column: column)
            } else {
                focusedCell = nil
                model.onExit()
            }
        }
        .onKeyPress(keys: [.tab], phases: .down) { press in
            move(from: Cell(row: row, column: column), backwards: press.modifiers.contains(.shift))
            return .handled
        }
    }

    private func alignmentButton(_ title: LocalizedStringKey, symbol: String, value: TableAlignment) -> some View {
        Button {
            let column = activeCell.column
            model.change { $0.alignments[column] = value }
        } label: {
            Label(title, systemImage: symbol)
        }
    }

    private var alignmentSymbol: String {
        switch model.table.alignments[min(activeCell.column, model.table.alignments.count - 1)] {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch model.table.alignments[column] {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    private func insertRow() {
        let row = activeCell.row
        model.change { $0.insertRow(after: row) }
        focusedCell = Cell(row: row + 1, column: activeCell.column)
    }

    private func move(from cell: Cell, backwards: Bool) {
        let columns = model.table.alignments.count
        let index = cell.row * columns + cell.column + (backwards ? -1 : 1)
        guard index >= 0 else { return }
        if index >= model.table.rows.count * columns {
            model.change { $0.insertRow(after: $0.rows.count - 1) }
        }
        focusedCell = Cell(row: index / columns, column: index % columns)
    }

    private func clampActiveCell() {
        activeCell.row = min(activeCell.row, model.table.rows.count - 1)
        activeCell.column = min(activeCell.column, model.table.alignments.count - 1)
        // A newly inserted cell may already be the requested focus while the
        // observed active cell still refers to the previous native field.
        if let focusedCell {
            let clamped = Cell(
                row: min(focusedCell.row, model.table.rows.count - 1),
                column: min(focusedCell.column, model.table.alignments.count - 1)
            )
            if clamped != focusedCell { self.focusedCell = clamped }
        }
    }
}
