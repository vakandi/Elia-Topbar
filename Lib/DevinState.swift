import Foundation

// MARK: - Account model (the logged-in `devin` account only)

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

// MARK: - Cached state

/// Mirrors ~/.local/share/devin/reset_state.json — a usage cache written by
/// external tooling. Only the current account's entry is ever read from it.
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

// MARK: - CLI calls

public enum DevinCLI {
    public static func hasCLI() -> Bool {
        DevinPaths.locate("devin") != nil
    }

    /// Identity of the logged-in account, straight from `devin auth status`.
    /// This is the ONLY account the app knows about — account switching is a
    /// manual `devin-reset` operation and is deliberately not exposed here.
    public static func currentIdentity() throws -> (email: String, name: String?, plan: String?)? {
        guard let binary = DevinPaths.locate("devin") else { throw DevinError.binaryMissing }
        let result = try DevinProcess.runSync(binary, ["auth", "status"], timeout: 8)
        guard result.status == 0 else { return nil }
        var email: String?, name: String?, plan: String?
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Email:") {
                email = String(trimmed.dropFirst("Email:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Name:") {
                name = String(trimmed.dropFirst("Name:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Plan:") {
                plan = String(trimmed.dropFirst("Plan:".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        guard let email, !email.isEmpty else { return nil }
        return (email, name, plan)
    }

    /// Last-known quota for ONE account, read from the local usage cache.
    /// Only the current account's entry is ever extracted — the file's other
    /// accounts are never surfaced.
    public static func cachedUsage(for email: String) -> DevinUsageSnapshot? {
        guard let data = try? Data(contentsOf: DevinPaths.stateFile),
              let state = try? JSONDecoder().decode(DevinCachedState.self, from: data),
              let entry = state.accounts[email] else { return nil }
        return entry.usage?.withEpochs()
    }

    /// The account card data: auth status identity + cached quota snapshot.
    public static func currentAccount() throws -> DevinAccount? {
        guard let identity = try currentIdentity() else { return nil }
        let cached = try? JSONDecoder().decode(
            DevinCachedState.self,
            from: Data(contentsOf: DevinPaths.stateFile)
        )
        let entry = cached?.accounts[identity.email]
        return DevinAccount(
            email: identity.email,
            name: identity.name ?? entry?.identity?.name,
            plan: identity.plan ?? entry?.identity?.plan,
            lastUsedEpoch: entry?.lastUsed.flatMap(DevinCachedState.epoch(from:)),
            lastMintEpoch: entry?.lastMint.flatMap(DevinCachedState.epoch(from:)),
            uses: entry?.uses,
            usage: entry?.usage?.withEpochs()
        )
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
}
