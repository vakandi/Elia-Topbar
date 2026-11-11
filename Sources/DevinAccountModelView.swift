import SwiftUI
import AppKit
import EliaTopBarKit

// MARK: - Catalog cache (in-memory, 10 minutes — never persisted, the payload
// is ~470 KB and UserDefaults is the wrong place for it)

private enum DevinCatalogCache {
    static var families: [DevinModelFamily]?
    static var fetchedAt: Date?
    static let ttl: TimeInterval = 10 * 60

    static var fresh: [DevinModelFamily]? {
        guard let families, let fetchedAt,
              Date().timeIntervalSince(fetchedAt) < ttl else { return nil }
        return families
    }
}

// MARK: - View

/// Devin CLI model picker: shows the logged-in account, its last-known
/// quota, and the model catalog. Account switching is deliberately absent —
/// it is a manual `devin-reset` operation; this window only reads what
/// `devin auth status` / `devin models list` report and writes the chosen
/// model into ~/.config/devin/config.json on Apply.
struct DevinAccountModelView: View {
    let agentName: String
    let currentModel: String
    var onClose: () -> Void
    var onApply: (DevinAccount, DevinModelVariant) -> Void

    @State private var account: DevinAccount?
    @State private var families: [DevinModelFamily] = []
    @State private var loadError: String?
    @State private var catalogStale = false
    @State private var loading = true

    @State private var selectedModelUID: String = ""
    @State private var showAllModels = false

    private var selectedVariant: DevinModelVariant? {
        families.lazy.flatMap(\.variants).first { $0.modelUID == selectedModelUID }
    }

    private var freePairs: [(DevinModelFamily, DevinModelVariant)] {
        families.flatMap { family in
            family.variants.filter(\.isFree).map { (family, $0) }
        }
    }

    private var lowCostPairs: [(DevinModelFamily, DevinModelVariant)] {
        families.flatMap { family in
            family.variants.filter { $0.isLowCost && !$0.isFree }.map { (family, $0) }
        }
    }

    private var otherPairs: [(DevinModelFamily, DevinModelVariant)] {
        families.flatMap { family in
            family.variants.filter { !$0.isFree && !$0.isLowCost }.map { (family, $0) }
        }
    }

    private var cliMissing: Bool { !DevinCLI.hasCLI() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            banner
            usageStrip
            modelSection
            Spacer(minLength: 0)
            Divider().opacity(0.5)
            footer
        }
        .padding(16)
        .frame(width: 640)
        .frame(maxHeight: 660)
        .task { await reload() }
    }

    // MARK: Banner

    private var banner: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 19, weight: .medium))
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text("Devin CLI").font(.system(size: 15, weight: .semibold))
                if cliMissing {
                    Text("Devin CLI not found")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.65))
                } else {
                    Text(account?.email ?? "No account logged in")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if let plan = account?.plan {
                Text(plan.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.white.opacity(0.12), in: Capsule())
            }

            if cliMissing {
                Button("Locate…") { locateBinary() }
                    .font(.system(size: 10, weight: .medium))
            }

            if let usage = account?.usage {
                DevinQuotaRing(percent: usage.dailyRemainingPct, size: 44)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 84)
        .foregroundColor(.white)
        .background(
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.12, blue: 0.20),
                         Color(red: 0.20, green: 0.17, blue: 0.33)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    // MARK: Usage strip (current account, last-known snapshot)

    @ViewBuilder
    private var usageStrip: some View {
        if let account {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Usage — \(account.email)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if let fetched = account.usage?.fetchedAtEpoch {
                        Text("last known \(fetchedAgo(fetched))")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                }
                if let usage = account.usage {
                    DevinQuotaBar(label: "Daily", percent: usage.dailyRemainingPct)
                    DevinQuotaBar(label: "Weekly", percent: usage.weeklyRemainingPct)
                    HStack(spacing: 12) {
                        Text("daily resets \(DevinTime.until(Date(timeIntervalSince1970: usage.dailyResetAt)))")
                        Text("weekly resets \(DevinTime.until(Date(timeIntervalSince1970: usage.weeklyResetAt)))")
                    }
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                } else {
                    Text("No usage snapshot yet for this account.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        } else if let loadError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(loadError).font(.caption).foregroundColor(.secondary)
                Button("Retry") { Task { await reload() } }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private func fetchedAgo(_ epoch: Double) -> String {
        let secs = max(0, Date().timeIntervalSince1970 - epoch)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60)) min ago" }
        if secs < 86400 { return "\(Int(secs / 3600)) h ago" }
        return "\(Int(secs / 86400)) d ago"
    }

    // MARK: Models

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Models")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                if let account {
                    Text("for \(account.email)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if catalogStale {
                    Text("could not refresh")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                }
            }

            if cliMissing {
                missingCLIBlock
            } else if families.isEmpty {
                if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading models…").font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    Text("No models returned.").font(.caption).foregroundColor(.secondary)
                }
            } else {
                if !freePairs.isEmpty {
                    Text("Free on this account")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.green)
                    ForEach(freePairs, id: \.1.id) { pair in
                        DevinModelRow(
                            family: pair.0, variant: pair.1,
                            selected: selectedModelUID == pair.1.modelUID
                        ) { selectedModelUID = pair.1.modelUID }
                    }
                }

                if !lowCostPairs.isEmpty {
                    Text("Low cost")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.orange)
                    ForEach(lowCostPairs, id: \.1.id) { pair in
                        DevinModelRow(
                            family: pair.0, variant: pair.1,
                            selected: selectedModelUID == pair.1.modelUID
                        ) { selectedModelUID = pair.1.modelUID }
                    }
                }

                DisclosureGroup(isExpanded: $showAllModels) {
                    ForEach(otherPairs, id: \.1.id) { pair in
                        DevinModelRow(
                            family: pair.0, variant: pair.1,
                            selected: selectedModelUID == pair.1.modelUID
                        ) { selectedModelUID = pair.1.modelUID }
                    }
                } label: {
                    Text("All models (\(otherPairs.count))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var missingCLIBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Install the Devin CLI, then locate it:")
                .font(.caption).foregroundColor(.secondary)
            Text("curl -fsSL https://cli.devin.ai/install.sh | sh")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Button("Locate…") { locateBinary() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let variant = selectedVariant {
                    Text("devin → agent.model = \(variant.modelUID)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Devin CLI default")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let account {
                    Text(account.email)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                Button("Apply") {
                    guard let account, let variant = selectedVariant else { return }
                    onApply(account, variant)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(account == nil || selectedVariant == nil)
            }
        }
    }

    // MARK: Actions

    private func reload() async {
        loading = true
        loadError = nil
        do {
            account = try await Task.detached {
                try DevinCLI.currentAccount()
            }.value
        } catch {
            loadError = sanitized(error.localizedDescription)
        }

        if cliMissing {
            loading = false
            return
        }

        if let cached = DevinCatalogCache.fresh {
            families = cached
        } else {
            do {
                families = try await DevinCLI.loadCatalog()
                DevinCatalogCache.families = families
                DevinCatalogCache.fetchedAt = Date()
                catalogStale = false
            } catch {
                catalogStale = true
                // Keep the previous catalog on screen — never blank the
                // window the user is about to use.
            }
        }

        if selectedModelUID.isEmpty {
            // What the CLI will actually run next wins over the last pick
            // EliaTopBar saved — the config file is the source of truth.
            selectedModelUID = DevinConfig.currentModel()
                ?? UserDefaults.standard.string(forKey: "devin.model")
                ?? ""
        }
        if selectedVariant == nil, let firstFree = freePairs.first {
            selectedModelUID = firstFree.1.modelUID
        }
        loading = false
    }

    /// Errors may carry the email and phase names; secret-shaped lines are
    /// dropped before display.
    private func sanitized(_ text: String) -> String {
        let lines = text.split(separator: "\n").suffix(3).map(String.init).filter { line in
            let lower = line.lowercased()
            return !(lower.contains("token") || lower.contains("cookie")
                     || lower.contains("password") || lower.contains("authorization"))
        }
        return lines.joined(separator: "\n")
    }

    private func locateBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Locate the devin binary"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "devin.binaryPath")
        Task { await reload() }
    }
}
