import SwiftUI

struct AgentRowModel {
    let name: String
    let image: NSImage?
    let attributedTitle: NSAttributedString
}

/// Independently scrollable agent list embedded as an NSMenuItem view.
/// Only this list scrolls under the mouse — the rest of the dropdown stays put.
struct AgentScrollListView: View {
    let rows: [AgentRowModel]
    var visibleRows: Int = 5
    /// Row tap → the agent's full details menu.
    var onPick: (String) -> Void

    private let rowHeight: CGFloat = 26

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(rows, id: \.name) { row in
                    RowButton(model: row, rowHeight: rowHeight) {
                        onPick(row.name)
                    }
                    if row.name != rows.last?.name {
                        Divider().padding(.leading, 8)
                    }
                }
            }
        }
        .frame(width: 300, height: CGFloat(min(rows.count, max(visibleRows, 1))) * rowHeight)
    }

    private struct RowButton: View {
        let model: AgentRowModel
        let rowHeight: CGFloat
        var onPick: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 6) {
                if let img = model.image {
                    Image(nsImage: img).resizable().frame(width: 16, height: 16)
                }
                AttributedText(attributedString: model.attributedTitle)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .background(hovering ? Color.accentColor.opacity(0.25) : Color.clear)
            .onTapGesture { onPick() }
        }
    }
}

/// Minimal NSAttributedString renderer for menu-style rows.
struct AttributedText: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(labelWithAttributedString: attributedString)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.attributedStringValue = attributedString
    }
}
