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

// MARK: - Window accessor (disables the close button while a switch runs —
// killing devin-reset between logout and write can leave the CLI credential-less)

private struct DevinWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

// MARK: - View

/// Devin CLI account & model chooser: which account is logged in, how much
/// quota each one has left, and which model the agent should run. Account
/// switching shells out to `devin-reset`; nothing credential-shaped ever
/// crosses into this process.
struct DevinAccountModelView: View {
    let agentName: String
    let currentModel: String
    var onClose: () -> Void
    var onApply: (DevinAccount, DevinModelVariant) -> Void

    private static let phaseOrder = ["resolve", "mint", "logout", "identity", "write", "verify"]

    @State private var pool: DevinPool?
    @State private var families: [DevinModelFamily] = []
    @State private var poolError: String?
    @State private var catalogStale = false
    @State private var loading = true

    @State private var selectedAccountEmail: String = ""
    @State private var selectedModelUID: String = ""
    @State private var search = ""
    @State private var showAllModels = false

    @State private var switching = false
    @State private var switchPhases: [String: Bool] = [:]
    @State private var switchError: String?
    @State private var alsoUpdateApp = true
    @State private var showDeadConfirm = false
    @State private var window: NSWindow?

    private var activeEmail: String? { pool?.current }

    private var selectedAccount: DevinAccount? {
        pool?.accounts.first { $0.email.caseInsensitiveCompare(selectedAccountEmail) == .orderedSame }
    }

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

    private var activeAccount: DevinAccount? {
        guard let activeEmail else { return nil }
        return pool?.accounts.first {
            $0.email.caseInsensitiveCompare(activeEmail) == .orderedSame
        }
    }

    private var sortedAccounts: [DevinAccount] {
        guard let pool else { return [] }
        var list = DevinAccount.sortPool(pool.accounts, activeEmail: pool.current)
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            list = list.filter {
                $0.email.lowercased().contains(needle)
                    || ($0.name ?? "").lowercased().contains(needle)
            }
        }
        return list
    }

    private var cliMissing: Bool { !DevinCLI.hasCLI() }
    private var helperMissing: Bool { !DevinCLI.hasHelper() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            banner
            accountSection
            if let selectedAccount { usageStrip(selectedAccount) }
            modelSection
            Spacer(minLength: 0)
            Divider().opacity(0.5)
            footer
        }
        .padding(16)
        .frame(width: 640)
        .frame(maxHeight: 660)
        .overlay {
            if switching { progressOverlay }
        }
        .background(DevinWindowAccessor { window = $0 })
        .task { await reload() }
        .onChange(of: switching) { isSwitching in
            window?.standardWindowButton(.closeButton)?.isEnabled = !isSwitching
        }
        .alert("Switch to a dead account?", isPresented: $showDeadConfirm) {
            Button("Switch anyway") { Task { await performSwitch() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The checker marked \(selectedAccount?.email ?? "this account") as dead. The switch may fail.")
        }
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
                    Text(activeAccount?.email ?? "No account logged in")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if let plan = activeAccount?.plan {
                Text(plan.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.white.opacity(0.12), in: Capsule())
            }

            if cliMissing {
                Button("Locate…") { locateBinary() }
                    .font(.system(size: 10, weight: .medium))
            }

            if let usage = activeAccount?.usage {
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

    // MARK: Accounts

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Accounts")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                if let pool {
                    Text("\(pool.accounts.count) accounts")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                }
                Spacer()
                if (pool?.accounts.count ?? 0) > 8 {
                    TextField("Search", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .frame(width: 150)
                }
                Button("Refresh") { Task { await reload() } }
                    .font(.system(size: 11))
                    .disabled(loading || switching)
            }

            if cliMissing {
                missingCLIBlock
            } else if let poolError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(poolError).font(.caption).foregroundColor(.secondary)
                    Button("Retry") { Task { await reload() } }.buttonStyle(.link).font(.caption)
                }
            } else if pool == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading accounts…").font(.caption).foregroundColor(.secondary)
                }
            } else if sortedAccounts.isEmpty {
                Text(search.isEmpty ? "No accounts found." : "No account matches “\(search)”.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(sortedAccounts) { account in
                            let status = account.status(activeEmail: activeEmail)
                            DevinAccountCard(
                                account: account,
                                status: status,
                                selected: account.email.caseInsensitiveCompare(selectedAccountEmail) == .orderedSame,
                                switching: switching
                            ) {
                                selectedAccountEmail = account.email
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            if helperMissing {
                Text("devin-reset not found — showing cached usage only. Switching is disabled.")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
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
            HStack(spacing: 8) {
                Button("Locate…") { locateBinary() }
                if let cached = try? loadCachedOnly() {
                    Text("\(cached.accounts.count) cached accounts")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private func loadCachedOnly() throws -> DevinPool {
        let data = try Data(contentsOf: DevinPaths.stateFile)
        let state = try JSONDecoder().decode(DevinCachedState.self, from: data)
        return DevinPool(current: nil, accounts: state.accounts.keys.sorted().map {
            DevinAccount(email: $0)
        })
    }

    // MARK: Usage strip (selected account)

    private func usageStrip(_ account: DevinAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Usage — \(account.email)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if let fetched = account.usage?.fetchedAtEpoch {
                    Text("fetched \(fetchedAgo(fetched))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
            if let usage = account.usage {
                DevinQuotaBar(label: "Daily", percent: usage.dailyRemainingPct)
                DevinQuotaBar(label: "Weekly", percent: usage.weeklyRemainingPct)
                HStack(spacing: 12) {
                    Text("daily resets \(DevinAccountCard.until(Date(timeIntervalSince1970: usage.dailyResetAt)))")
                    Text("weekly resets \(DevinAccountCard.until(Date(timeIntervalSince1970: usage.weeklyResetAt)))")
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            } else {
                Text("No usage snapshot for this account yet — it has never been minted.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
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
                if let account = selectedAccount {
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
                Text("The catalog comes from `devin models list` — install the CLI to see it.")
                    .font(.caption).foregroundColor(.secondary)
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
                if let selected = selectedAccount, activeEmail != nil,
                   selected.email.caseInsensitiveCompare(activeEmail ?? "") != .orderedSame {
                    Text("Catalog is read from the active account. Switch to see another plan's models.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

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

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let variant = selectedVariant {
                    Text("\(agentName) → devin-cli/\(variant.modelUID)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("Devin CLI default")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("Also update Devin.app")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Toggle("", isOn: $alsoUpdateApp).labelsHidden().controlSize(.small)
            }

            HStack {
                if let switchError {
                    Text(switchError)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .disabled(switching)
                Button(helperMissing ? "Switch unavailable" : "Switch account") {
                    guard let account = selectedAccount else { return }
                    if account.checked == "dead" {
                        showDeadConfirm = true
                    } else {
                        Task { await performSwitch() }
                    }
                }
                .disabled(switching || helperMissing || selectedAccount == nil
                          || selectedAccount?.email.caseInsensitiveCompare(activeEmail ?? "\u{0}") == .orderedSame)
                Button("Apply") {
                    guard let account = selectedAccount, let variant = selectedVariant else { return }
                    onApply(account, variant)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(switching || selectedAccount == nil || selectedVariant == nil)
            }
        }
    }

    // MARK: Progress overlay

    private var progressOverlay: some View {
        ZStack {
            Color.black.opacity(0.001)
            VStack(alignment: .leading, spacing: 10) {
                Text("Switching account…")
                    .font(.system(size: 13, weight: .semibold))
                ForEach(Self.phaseOrder, id: \.self) { phase in
                    let done = switchPhases[phase] == true
                    let active = !done && Self.phaseOrder.prefix { $0 != phase }
                        .allSatisfy { switchPhases[$0] == true }
                        && Self.phaseOrder.contains(phase)
                    HStack(spacing: 8) {
                        Image(systemName: done ? "checkmark.circle.fill" : (active ? "circle.dotted" : "circle"))
                            .foregroundColor(done ? .green : (active ? Color.accentColor : .secondary))
                            .font(.system(size: 11))
                        Text(phase.capitalized)
                            .font(.system(size: 11))
                            .foregroundColor(done || active ? .primary : .secondary)
                    }
                }
                Text("Do not close this window")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .frame(width: 240)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 12)
        }
    }

    // MARK: Actions

    private func reload() async {
        loading = true
        poolError = nil
        do {
            pool = try await DevinCLI.loadPool()
        } catch {
            poolError = sanitized(error.localizedDescription)
            // Fall back to whatever the state file alone can tell us.
            pool = try? loadCachedOnly()
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

        if selectedAccountEmail.isEmpty {
            selectedAccountEmail = pool?.current
                ?? UserDefaults.standard.string(forKey: "devin.account")
                ?? pool?.accounts.first?.email
                ?? ""
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

    private func performSwitch() async {
        guard let account = selectedAccount, !switching else { return }
        switching = true
        switchPhases = [:]
        switchError = nil
        defer { switching = false }
        do {
            try await DevinCLI.switchAccount(to: account.email, alsoUpdateApp: alsoUpdateApp) { event in
                Task { @MainActor in
                    guard let phase = event.phase else { return }
                    switchPhases[phase] = event.ok ?? true
                }
            }
            // The helper's `current` changed: re-read the pool, then the
            // catalog because the plan may differ.
            DevinCatalogCache.families = nil
            DevinCatalogCache.fetchedAt = nil
            await reload()
        } catch {
            switchError = sanitized(error.localizedDescription)
        }
    }

    /// AppLog may carry the email and phase names, never a token. Helper
    /// stderr is truncated and secret-shaped lines are dropped.
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
        panel.message = "Locate the devin binary (or devin-reset helper)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.lastPathComponent
        if name == "devin-reset" || url.pathExtension == "py" {
            UserDefaults.standard.set(url.path, forKey: "devin.helperPath")
        } else {
            UserDefaults.standard.set(url.path, forKey: "devin.binaryPath")
        }
        Task { await reload() }
    }
}
