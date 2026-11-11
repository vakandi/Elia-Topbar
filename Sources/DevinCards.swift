import SwiftUI
import EliaTopBarKit

// MARK: - Quota ring (banner, active account)

struct DevinQuotaRing: View {
    let percent: Int
    var size: CGFloat = 44

    private var color: Color {
        if percent <= 0 { return .red }
        if percent < 40 { return .orange }
        return .green
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: 3.5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, percent))) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(percent)%")
                .font(.system(size: size * 0.26, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Quota bar (account card + usage strip)

struct DevinQuotaBar: View {
    let label: String
    let percent: Int

    private var color: Color {
        if percent <= 0 { return .red }
        if percent < 40 { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(max(0, min(100, percent))) / 100)
                }
            }
            .frame(height: 4)
            Text("\(percent)%")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

// MARK: - Time formatting

enum DevinTime {
    static func until(_ date: Date) -> String {
        let secs = max(0, date.timeIntervalSinceNow)
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        if h >= 24 { return "in \(h / 24)d \(h % 24)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(m)m"
    }
}

// MARK: - Model row

struct DevinModelRow: View {
    let family: DevinModelFamily
    let variant: DevinModelVariant
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundColor(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .font(.system(size: 13))
                Text(variant.label)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                if variant.isNew == true {
                    Text("NEW")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.16), in: Capsule())
                        .foregroundColor(.blue)
                }
                costBadge
                if let chip = variant.contextChip {
                    Text(chip)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(selected ? 0.07 : 0.0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var costBadge: some View {
        if variant.isFree {
            Text("FREE")
                .font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.green.opacity(0.16), in: Capsule())
                .foregroundColor(.green)
        } else if variant.isLowCost {
            Text("LOW COST")
                .font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.orange.opacity(0.16), in: Capsule())
                .foregroundColor(.orange)
        } else if let summary = variant.costSummary, !summary.isEmpty {
            Text(summary)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}
