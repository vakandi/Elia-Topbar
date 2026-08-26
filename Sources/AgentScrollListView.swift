import SwiftUI

struct AgentRowModel {
    let name: String
    let image: NSImage?
    let attributedTitle: NSAttributedString
}

/// Render-only list (no SwiftUI gestures — see AgentListHostingView).
struct AgentScrollListView: View {
    let rows: [AgentRowModel]
    var visibleRows: Int = 5

    private let rowHeight: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.name) { row in
                HStack(spacing: 6) {
                    if let img = row.image {
                        Image(nsImage: img).resizable().frame(width: 16, height: 16)
                    }
                    AttributedText(attributedString: row.attributedTitle)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if rows.count > 1 {
                Divider().padding(.leading, 8)
            }
        }
        .frame(width: 300, height: CGFloat(min(rows.count, max(visibleRows, 1))) * rowHeight)
    }
}

/// Hosting view that swallows mouseDown (so the parent menu stays predictable)
/// and reports which row was hit, top row = index 0.
final class AgentListHostingView: NSHostingView<AgentScrollListView> {
    var rowHeight: CGFloat = 26
    var onClickAt: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = Int(p.y / max(rowHeight, 1))
        onClickAt?(idx)
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
