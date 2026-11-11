import Foundation

// MARK: - Pool models (devin-reset --json list)

public struct DevinUsageSnapshot: Decodable, Hashable {
    public let dailyRemainingPct: Int
    public let weeklyRemainingPct: Int
    public let dailyResetAt: Double
    public let weeklyResetAt: Double
    public let fetchedAtEpoch: Double?

    public init(dailyRemainingPct: Int, weeklyRemainingPct: Int,
                dailyResetAt: Double, weeklyResetAt: Double,
                fetchedAtEpoch: Double? = nil) {
        self.dailyRemainingPct = dailyRemainingPct
        self.weeklyRemainingPct = weeklyRemainingPct
        self.dailyResetAt = dailyResetAt
        self.weeklyResetAt = weeklyResetAt
        self.fetchedAtEpoch = fetchedAtEpoch
    }

    enum CodingKeys: String, CodingKey {
        case dailyRemainingPct = "daily_remaining_pct"
        case weeklyRemainingPct = "weekly_remaining_pct"
        case dailyResetAt = "daily_reset_at"
        case weeklyResetAt = "weekly_reset_at"
        case fetchedAtEpoch = "fetched_at_epoch"
    }
}

public struct DevinAccount: Decodable, Identifiable, Hashable {
    public let email: String
    public let name: String?
    public let plan: String?
    public let checked: String?
    public let lastUsedEpoch: Double?
    public let lastMintEpoch: Double?
    public let uses: Int?
    public let usage: DevinUsageSnapshot?

    public var id: String { email }

    public init(email: String, name: String? = nil, plan: String? = nil, checked: String? = nil,
                lastUsedEpoch: Double? = nil, lastMintEpoch: Double? = nil,
                uses: Int? = nil, usage: DevinUsageSnapshot? = nil) {
        self.email = email
        self.name = name
        self.plan = plan
        self.checked = checked
        self.lastUsedEpoch = lastUsedEpoch
        self.lastMintEpoch = lastMintEpoch
        self.uses = uses
        self.usage = usage
    }

    enum CodingKeys: String, CodingKey {
        case email, name, plan, checked, uses, usage
        case lastUsedEpoch = "last_used_epoch"
        case lastMintEpoch = "last_mint_epoch"
    }
}

public struct DevinPool: Decodable {
    public let current: String?
    public let accounts: [DevinAccount]

    public init(current: String?, accounts: [DevinAccount]) {
        self.current = current
        self.accounts = accounts
    }
}

// MARK: - Cached state (reset_state.json, fallback path only)

/// Mirrors ~/.local/share/devin/reset_state.json. This file is a usage cache,
/// not the account pool — it is only read when devin-reset is absent.
public struct DevinCachedState: Decodable {
    public struct Identity: Decodable {
        public let name: String?
        public let plan: String?
    }
    public struct Usage: Decodable {
        public let dailyRemainingPct: Int?
        public let weeklyRemainingPct: Int?
        public let dailyResetAt: Double?
        public let weeklyResetAt: Double?
        public let fetchedAt: String?

        enum CodingKeys: String, CodingKey {
            case dailyRemainingPct = "daily_remaining_pct"
            case weeklyRemainingPct = "weekly_remaining_pct"
            case dailyResetAt = "daily_reset_at"
            case weeklyResetAt = "weekly_reset_at"
            case fetchedAt = "fetched_at"
        }

        /// Python writes ISO datetimes; Swift wants epochs. This conversion
        /// exists only on this fallback path — the helper emits epochs.
        public func withEpochs() -> DevinUsageSnapshot? {
            guard let d = dailyRemainingPct, let w = weeklyRemainingPct,
                  let dr = dailyResetAt, let wr = weeklyResetAt else { return nil }
            return DevinUsageSnapshot(
                dailyRemainingPct: d, weeklyRemainingPct: w,
                dailyResetAt: dr, weeklyResetAt: wr,
                fetchedAtEpoch: fetchedAt.flatMap(DevinCachedState.epoch(from:))
            )
        }
    }
    public struct Entry: Decodable {
        public let lastUsed: String?
        public let lastMint: String?
        public let uses: Int?
        public let identity: Identity?
        public let usage: Usage?

        enum CodingKeys: String, CodingKey {
            case uses, identity, usage
            case lastUsed = "last_used"
            case lastMint = "last_mint"
        }
    }

    public let accounts: [String: Entry]

    public init(accounts: [String: Entry]) {
        self.accounts = accounts
    }

    public static func epoch(from iso: String) -> Double? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: iso) { return date.timeIntervalSince1970 }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: iso) { return date.timeIntervalSince1970 }
        // Python's datetime.now().isoformat() writes local time with NO
        // offset, which ISO8601DateFormatter rejects. These two cover it.
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            if let date = f.date(from: iso) { return date.timeIntervalSince1970 }
        }
        return nil
    }
}

// MARK: - Status derivation (one place, every badge reads it)

public enum DevinAccountStatus: Equatable {
    case active
    case available
    case dailyReached(reset: Date)
    case weeklyReached(reset: Date)
    case stale(checked: Date?)
    case unknown
}

public extension DevinAccount {
    func status(activeEmail: String?, now: Date = Date()) -> DevinAccountStatus {
        if let active = activeEmail, !active.isEmpty,
           email.caseInsensitiveCompare(active) == .orderedSame { return .active }
        guard let usage else { return .unknown }
        if let fetched = usage.fetchedAtEpoch {
            let age = now.timeIntervalSince1970 - fetched
            if age > 24 * 3600 { return .stale(checked: Date(timeIntervalSince1970: fetched)) }
        }
        if usage.weeklyRemainingPct <= 0 {
            return .weeklyReached(reset: Date(timeIntervalSince1970: usage.weeklyResetAt))
        }
        if usage.dailyRemainingPct <= 0 {
            return .dailyReached(reset: Date(timeIntervalSince1970: usage.dailyResetAt))
        }
        return .available
    }

    /// Deterministic order: active first, then available by daily quota
    /// descending, then quota-reached by soonest reset, then stale/unknown,
    /// then email. No jitter between refreshes.
    static func sortPool(_ accounts: [DevinAccount], activeEmail: String?,
                         now: Date = Date()) -> [DevinAccount] {
        func rank(_ a: DevinAccount) -> Int {
            switch a.status(activeEmail: activeEmail, now: now) {
            case .active: return 0
            case .available: return 1
            case .dailyReached, .weeklyReached: return 2
            case .stale, .unknown: return 3
            }
        }
        return accounts.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            switch (a.status(activeEmail: activeEmail, now: now),
                    b.status(activeEmail: activeEmail, now: now)) {
            case (.available, .available):
                let da = a.usage?.dailyRemainingPct ?? -1
                let db = b.usage?.dailyRemainingPct ?? -1
                if da != db { return da > db }
            case (.dailyReached(let xa), .dailyReached(let xb)):
                if xa != xb { return xa < xb }
            case (.weeklyReached(let xa), .weeklyReached(let xb)):
                if xa != xb { return xa < xb }
            case (.stale(let ca), .stale(let cb)):
                if ca != cb { return (ca ?? .distantPast) < (cb ?? .distantPast) }
            default: break
            }
            return a.email.localizedCaseInsensitiveCompare(b.email) == .orderedAscending
        }
    }
}

// MARK: - Catalog models (devin models list --format json)

public struct DevinModelVariant: Decodable, Identifiable, Hashable {
    public let modelUID: String
    public let label: String
    public let description: String?
    public let costSummary: String?
    public let costTier: String?
    public let maxContextTokens: Int?
    public let maxOutputTokens: Int?
    public let isNew: Bool?
    public let isBeta: Bool?

    public var id: String { modelUID }
    public var isFree: Bool { costTier?.caseInsensitiveCompare("Free") == .orderedSame }
    public var isLowCost: Bool { costTier?.caseInsensitiveCompare("Low cost") == .orderedSame }

    /// "262K" / "1M" chip; nil when the catalog does not say.
    public var contextChip: String? {
        guard let tokens = maxContextTokens, tokens > 0 else { return nil }
        if tokens >= 1_000_000 {
            let m = Double(tokens) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
        return "\(tokens / 1000)K"
    }

    public init(modelUID: String, label: String, description: String? = nil,
                costSummary: String? = nil, costTier: String? = nil,
                maxContextTokens: Int? = nil, maxOutputTokens: Int? = nil,
                isNew: Bool? = nil, isBeta: Bool? = nil) {
        self.modelUID = modelUID
        self.label = label
        self.description = description
        self.costSummary = costSummary
        self.costTier = costTier
        self.maxContextTokens = maxContextTokens
        self.maxOutputTokens = maxOutputTokens
        self.isNew = isNew
        self.isBeta = isBeta
    }

    enum CodingKeys: String, CodingKey {
        case label, description
        case modelUID = "model_uid"
        case costSummary = "cost_summary"
        case costTier = "cost_tier"
        case maxContextTokens = "max_context_tokens"
        case maxOutputTokens = "max_output_tokens"
        case isNew = "is_new"
        case isBeta = "is_beta"
    }
}

public struct DevinModelFamily: Decodable, Identifiable, Hashable {
    public let familyLabel: String
    public let familyUID: String?
    public let slug: String
    public let variants: [DevinModelVariant]

    public var id: String { slug }

    public init(familyLabel: String, familyUID: String? = nil, slug: String,
                variants: [DevinModelVariant]) {
        self.familyLabel = familyLabel
        self.familyUID = familyUID
        self.slug = slug
        self.variants = variants
    }

    enum CodingKeys: String, CodingKey {
        case slug, variants
        case familyLabel = "family_label"
        case familyUID = "family_uid"
    }
}

public struct DevinCatalog: Decodable {
    public let families: [DevinModelFamily]
}

// MARK: - Switch events (devin-reset --json-events)

public struct DevinSwitchEvent: Decodable {
    public let event: String
    public let phase: String?
    public let ok: Bool?
    public let detail: String?
    public let email: String?
}

// MARK: - CLI calls

public enum DevinCLI {
    /// The authoritative pool: the helper's --json list. Falls back to the
    /// cached reset_state.json when devin-reset is absent — a usage cache,
    /// never presented as the real pool.
    public static func loadPool() async throws -> DevinPool {
        if let helper = DevinPaths.locate("devin-reset") {
            // `list` is a positional `pick` argument, not a subcommand: the flag
            // must come first, or argparse reads "list" as an email.
            let result = try await DevinProcess.run(
                helper, ["--list", "--json"], timeout: 20
            )
            guard result.status == 0 else {
                throw DevinError.message(result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            return try JSONDecoder().decode(DevinPool.self, from: Data(result.stdout.utf8))
        }
        return try loadCachedPool()
    }

    public static func hasHelper() -> Bool {
        DevinPaths.locate("devin-reset") != nil
    }

    public static func hasCLI() -> Bool {
        DevinPaths.locate("devin") != nil
    }

    private static func loadCachedPool() throws -> DevinPool {
        let data = try Data(contentsOf: DevinPaths.stateFile)
        let state = try JSONDecoder().decode(DevinCachedState.self, from: data)
        let current = try? activeEmailFromAuthStatus()
        let accounts = state.accounts.map { email, entry in
            DevinAccount(
                email: email,
                name: entry.identity?.name,
                plan: entry.identity?.plan,
                checked: nil,
                lastUsedEpoch: entry.lastUsed.flatMap(DevinCachedState.epoch(from:)),
                lastMintEpoch: entry.lastMint.flatMap(DevinCachedState.epoch(from:)),
                uses: entry.uses,
                usage: entry.usage?.withEpochs()
            )
        }.sorted { $0.email.localizedCaseInsensitiveCompare($1.email) == .orderedAscending }
        return DevinPool(current: current, accounts: accounts)
    }

    /// The only text parse in the feature, and only on the fallback path (no
    /// helper). The helper returns `current` as JSON, so the normal path
    /// never scrapes this output.
    public static func activeEmailFromAuthStatus() throws -> String? {
        guard let binary = DevinPaths.locate("devin") else { throw DevinError.binaryMissing }
        let result = try DevinProcess.runSync(binary, ["auth", "status"], timeout: 8)
        guard result.status == 0 else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Email:") else { continue }
            return String(trimmed.dropFirst("Email:".count))
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    public static func loadCatalog() async throws -> [DevinModelFamily] {
        guard let binary = DevinPaths.locate("devin") else { throw DevinError.binaryMissing }
        let result = try await DevinProcess.run(
            binary, ["models", "list", "--format", "json"], timeout: 20
        )
        guard result.status == 0 else { throw DevinError.message(result.stderr) }
        let catalog = try JSONDecoder().decode(DevinCatalog.self, from: Data(result.stdout.utf8))
        return catalog.families
    }

    /// Streams NDJSON phase events while devin-reset switches the account.
    /// There is no cancel: killing the helper between logout and write can
    /// leave the CLI with no credential. `onEvent` fires on a pipe queue —
    /// callers must hop to the main actor before touching UI state.
    public static func switchAccount(
        to email: String,
        alsoUpdateApp: Bool = true,
        onEvent: @escaping @Sendable (DevinSwitchEvent) -> Void
    ) async throws {
        guard let helper = DevinPaths.locate("devin-reset") else { throw DevinError.helperMissing }
        var args = ["--json-events"]
        if !alsoUpdateApp { args.append("--no-app") }
        args.append(email)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = helper
            process.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:"
                + (env["PATH"] ?? "/usr/bin:/bin")
            process.environment = env

            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err

            var buffer = Data()
            var errData = Data()
            var finished = false
            let lock = NSLock()
            let errLock = NSLock()

            // stderr is drained too: the helper is quiet, but a Python
            // traceback longer than the 64 KB pipe buffer would block the
            // child and hang the continuation with no timeout.
            err.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                errLock.lock(); errData.append(chunk); errLock.unlock()
            }

            func finish(_ result: Result<Void, Error>) {
                lock.lock(); defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(with: result)
            }

            out.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard !line.isEmpty,
                          let event = try? JSONDecoder().decode(DevinSwitchEvent.self, from: line)
                    else { continue }
                    onEvent(event)
                    if event.event == "done" { finish(.success(())) }
                    if event.event == "error" {
                        finish(.failure(DevinError.message(event.detail ?? "switch failed")))
                    }
                }
            }

            process.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                let remaining = err.fileHandleForReading.readDataToEndOfFile()
                errLock.lock()
                if !remaining.isEmpty { errData.append(remaining) }
                let tail = String(data: errData, encoding: .utf8) ?? ""
                errLock.unlock()
                if proc.terminationStatus == 0 {
                    finish(.success(()))
                } else {
                    finish(.failure(DevinError.message(tail.isEmpty ? "switch failed" : tail)))
                }
            }

            do { try process.run() } catch { finish(.failure(error)) }
        }
    }
}
