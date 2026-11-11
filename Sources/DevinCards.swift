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

// MARK: - Status dot

struct DevinStatusDot: View {
    let status: DevinAccountStatus
    let checked: String?

    private var color: Color {
        if checked == "dead" { return .red }
        switch status {
        case .active: return .green
        case .available: return .green
        case .dailyReached, .weeklyReached: return .orange
        case .stale, .unknown: return .gray
        }
    }

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}

// MARK: - Account card

struct DevinAccountCard: View {
    let account: DevinAccount
    let status: DevinAccountStatus
    let selected: Bool
    let switching: Bool
    let onSelect: () -> Void

    private var footline: String {
        let uses = account.uses.map { "\($0) uses" } ?? "never used"
        switch status {
        case .active:
            return "ACTIVE · \(uses)"
        case .available:
            return "Available · \(uses)"
        case .dailyReached(let reset):
            return "Daily quota reached · resets \(Self.until(reset))"
        case .weeklyReached(let reset):
            return "Weekly quota reached · resets \(Self.until(reset))"
        case .stale(let checked):
            if let checked {
                let days = Int(Date().timeIntervalSince(checked) / 86400)
                return "Usage unknown · checked \(days <= 0 ? "today" : "\(days) d ago")"
            }
            return "Usage unknown"
        case .unknown:
            return "Usage unknown · \(uses)"
        }
    }

    static func until(_ date: Date) -> String {
        let secs = max(0, date.timeIntervalSinceNow)
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        if h >= 24 { return "in \(h / 24)d \(h % 24)h" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(m)m"
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(String(account.email.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor.opacity(0.16), in: Circle())
                    Text(account.email)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    if status == .active {
                        Text("ACTIVE")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.green.opacity(0.18), in: Capsule())
                            .foregroundColor(.green)
                    }
                    DevinStatusDot(status: status, checked: account.checked)
                }

                if let usage = account.usage {
                    DevinQuotaBar(label: "D", percent: usage.dailyRemainingPct)
                    DevinQuotaBar(label: "W", percent: usage.weeklyRemainingPct)
                }

                Text(footline)
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 104, alignment: .top)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color.primary.opacity(selected ? 0.075 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(selected || status == .active
                            ? Color.accentColor.opacity(status == .active ? 0.9 : 0.55)
                            : .clear,
                            lineWidth: status == .active ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(switching)
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
