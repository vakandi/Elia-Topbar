import Foundation

/// Parses a voice transcript into (agent, command).
///
/// Pure logic on purpose: this lives in `EliaTopBarKit` so it can be tested
/// without a microphone, which is the only way to pin the behaviour that
/// matters most — never firing at the wrong agent.
///
/// The vocabulary is the live subworker roster (`GET /status`). Roster names
/// are hyphenated ("mirorpay-community-organic"), and nobody says that out
/// loud, so every agent contributes several spoken aliases:
///
/// - the full name, hyphen turned into a space ("mirorpay community organic")
/// - its first segment ("mirorpay")
/// - the same for every hyphen-separated segment
///
/// "Ok Mirorpay" is therefore ambiguous between two agents on purpose: the
/// parser refuses to guess and hands back the candidates instead.
public enum VoiceCommandParser {

    /// Result of parsing one transcript.
    public struct Parsed: Equatable {
        /// The roster entry that was matched, or nil when nothing matched
        /// (or the match was ambiguous).
        public var agent: String?
        /// The spoken instruction, with the wake token and the agent name
        /// removed. Empty when the user only said the wake phrase.
        public var command: String
        /// Best candidates when the match was ambiguous. The UI offers these
        /// as click targets; nothing is fired.
        public var candidates: [String]
        /// True when a wake token ("ok", "hey", …) started the transcript.
        public var usedWakeToken: Bool
        /// The score of the best candidate, 0 when nothing matched. The
        /// wake-word detector uses it to tell a real name from a near miss.
        public var score: Double
        /// How many spoken words the winning alias consumed. A longer alias
        /// wins a tie: "Ok Mirorpay Seo" must beat "Ok Mirorpay".
        public var aliasLength: Int
        /// How many characters the winning alias has. A fuzzy match on a
        /// short alias ("so" for "seo") is a near miss, not a name.
        public var aliasCharacters: Int

        public init(agent: String? = nil,
                    command: String = "",
                    candidates: [String] = [],
                    usedWakeToken: Bool = false,
                    score: Double = 0,
                    aliasLength: Int = 0,
                    aliasCharacters: Int = 0) {
            self.agent = agent
            self.command = command
            self.candidates = candidates
            self.usedWakeToken = usedWakeToken
            self.score = score
            self.aliasLength = aliasLength
            self.aliasCharacters = aliasCharacters
        }
    }

    /// Words that can open a wake phrase. Only meaningful in leading position.
    public static let wakeTokens: Set<String> = [
        "ok", "okay", "okey", "hey", "yo", "euh", "er", "alright", "computer",
    ]

    /// Below this score nothing is fired.
    public static let acceptThreshold: Double = 0.7
    /// The winner must beat the runner-up by this much, otherwise it is a guess.
    public static let marginThreshold: Double = 0.05

    // MARK: - Normalisation

    /// Lowercase, strip diacritics, drop punctuation, collapse whitespace.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: Locale(identifier: "en_US_POSIX"))
        let cleaned = String(folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        })
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    /// One spoken word: its original text and its matchable form.
    struct Token {
        let original: String
        let norm: String
    }

    static func tokenize(_ text: String) -> [Token] {
        text.split(separator: " ", omittingEmptySubsequences: true).compactMap { raw in
            let original = String(raw)
            let norm = normalize(original)
            guard !norm.isEmpty else { return nil }
            return Token(original: original, norm: norm)
        }
    }

    // MARK: - Aliases

    /// Spoken aliases for one roster entry, longest first.
    ///
    /// Hyphen segments shorter than three characters are dropped: nobody says
    /// "Ok Ch Lu Fr" and "fr" would fire at the wrong agent.
    static func aliases(for name: String) -> [[String]] {
        let segments = name.split(separator: "-").map(String.init)
        var out: [[String]] = []
        if segments.count > 1 {
            out.append(segments.map { normalize($0) })
        }
        for segment in segments {
            let n = normalize(segment)
            if n.count >= 3 { out.append([n]) }
        }
        // The whole name said as one word, in case the agent really is that.
        let flat = normalize(name)
        if !flat.isEmpty { out.append([flat]) }
        // Deduplicate, keep the longest first.
        var seen = Set<String>()
        return out
            .filter { !$0.isEmpty && seen.insert($0.joined(separator: " ")).inserted }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Scoring

    /// Score of one alias against the leading spoken words.
    /// Returns nil when the alias does not plausibly match.
    static func score(alias: [String], tokens: [String]) -> Double? {
        guard !alias.isEmpty, !tokens.isEmpty, alias.count <= tokens.count else { return nil }
        let head = Array(tokens.prefix(alias.count))
        if head == alias { return 1.0 }

        if alias.count == 1 {
            let d = levenshtein(alias[0], tokens[0])
            if d == 0 { return 1.0 }
            if d == 1 && alias[0].count >= 4 { return 0.85 }
            if d == 2 && alias[0].count >= 5 { return 0.75 }
            // The user said less than the name: "gilfo" for "gilfoyle".
            if tokens[0].count >= 4 && alias[0].count - tokens[0].count <= 3
                && alias[0].hasPrefix(tokens[0]) {
                return 0.7
            }
            return nil
        }

        // Multi-word alias: the first word must line up, the rest may drift.
        let d0 = levenshtein(alias[0], tokens[0])
        guard d0 <= 1 else { return nil }
        let restAlias = Array(alias.dropFirst())
        let restTokens = Array(tokens.dropFirst().prefix(restAlias.count))
        let dRest = levenshtein(restAlias.joined(separator: " "), restTokens.joined(separator: " "))
        if dRest == 0 { return 0.95 }
        if dRest <= 2 { return 0.8 }
        return nil
    }

    /// Levenshtein distance, capped for speed.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[y.count]
    }

    // MARK: - Parsing

    /// Parse a transcript against the live roster.
    ///
    /// - Parameter requireAgent: when false, a missing agent name is not an
    ///   error — the caller decides where to send the command.
    /// - Parameter wakeTokens: the words that can open a wake phrase.
    public static func parse(_ transcript: String,
                              roster: [String],
                              requireAgent: Bool = true,
                              wakeTokens: Set<String> = VoiceCommandParser.wakeTokens) -> Parsed {
        let tokens = tokenize(transcript)
        guard !tokens.isEmpty else { return Parsed() }

        var index = 0
        var usedWakeToken = false
        if let first = tokens.first, wakeTokens.contains(first.norm) {
            index = 1
            usedWakeToken = true
        }

        let spoken = tokens.map(\.norm)
        let remaining = Array(spoken[index...])

        // Best (score, aliasLength) per roster entry. The name is looked
        // for anywhere in the transcript, not only at the start: "deploy
        // the api for gilfoyle" must still reach gilfoyle.
        struct Hit {
            let name: String
            var score: Double
            var aliasLength: Int
            var aliasCharacters: Int
            var consumed: Int
            var position: Int
        }
        var hits: [Hit] = []
        for name in roster {
            var best: Hit? = nil
            for alias in aliases(for: name) {
                guard alias.count <= remaining.count else { continue }
                let lastStart = usedWakeToken ? remaining.count - alias.count : min(2, remaining.count - alias.count)
                for start in 0...lastStart {
                    let window = Array(remaining[start...])
                    guard let s = score(alias: alias, tokens: window) else { continue }
                    // Consuming more spoken words is decisive: "Ok Mirorpay Seo"
                    // must pick mirorpay-seo over mirorpay-community-organic.
                    let effective = s + 0.05 * Double(max(0, alias.count - 1))
                    // An earlier match wins a tie: "ok gilfoyle and elia"
                    // must keep gilfoyle, not the elia that comes later.
                    if best == nil
                        || effective > best!.score
                        || (effective == best!.score && alias.count > best!.aliasLength)
                        || (effective == best!.score && alias.count == best!.aliasLength && start < best!.position) {
                        best = Hit(name: name,
                                   score: effective,
                                   aliasLength: alias.count,
                                   aliasCharacters: alias.joined(separator: " ").count,
                                   consumed: alias.count,
                                   position: start)
                    }
                }
            }
            if let best { hits.append(best) }
        }

        hits.sort { $0.score > $1.score
            || ($0.score == $1.score && $0.aliasLength > $1.aliasLength)
            || ($0.score == $1.score && $0.aliasLength == $1.aliasLength && $0.position < $1.position) }

        var agent: String?
        let best = hits.first
        let bestScore = best?.score ?? 0
        let bestAliasLength = best?.aliasLength ?? 0
        let bestAliasCharacters = best?.aliasCharacters ?? 0
        let bestPosition = best?.position ?? 0
        let bestConsumed = best?.consumed ?? 0
        if let first = best {
            let runnerUp = hits.filter { $0.name != first.name && $0.position <= first.position }.first?.score ?? 0
            if first.score >= acceptThreshold && (first.score - runnerUp) >= marginThreshold {
                agent = first.name
            }
        }

        // The command keeps every word except the wake token and the matched
        // name, wherever that name was spoken.
        let hasMatch = best != nil
        let matchedStart = hasMatch ? index + bestPosition : -1
        let matchedEnd = hasMatch ? matchedStart + bestConsumed : -1
        var commandTokens: [Token] = []
        for (i, token) in tokens.enumerated() {
            if usedWakeToken && i == 0 { continue }
            if hasMatch && i >= matchedStart && i < matchedEnd { continue }
            commandTokens.append(token)
        }
        let command = commandTokens.map(\.original).joined(separator: " ")

        if agent == nil && requireAgent {
            let candidates = hits.prefix(3).map(\.name)
            return Parsed(agent: nil,
                          command: command,
                          candidates: Array(candidates),
                          usedWakeToken: usedWakeToken,
                          score: bestScore,
                          aliasLength: bestAliasLength,
                          aliasCharacters: bestAliasCharacters)
        }

        return Parsed(agent: agent,
                      command: command,
                      candidates: [],
                      usedWakeToken: usedWakeToken,
                      score: bestScore,
                      aliasLength: bestAliasLength,
                      aliasCharacters: bestAliasCharacters)
    }

    /// The original words of the transcript after the first `skip` tokens.
    static func commandText(_ tokens: [Token], from skip: Int) -> String {
        guard skip < tokens.count else { return "" }
        return tokens[skip...].map(\.original).joined(separator: " ")
    }

    // MARK: - Wake phrase

    /// A resolved name has to be a strong match.
    static let wakeScoreThreshold = 0.85
    /// A fuzzy match only counts on a name long enough to be unambiguous.
    static let wakeFuzzyMinAliasLength = 4
    /// An ambiguous name has to be an exact match, otherwise "okay so…" fires.
    static let wakeExactThreshold = 1.0

    /// Was the wake phrase heard?
    ///
    /// Two ways to say yes:
    /// - a name resolved with a strong score ("ok gilfoyle", "ok gilfoyl");
    /// - an exact but ambiguous name ("ok mirorpay"), where the transcript
    ///   decides which agent it is.
    ///
    /// A near miss never counts: "okay so what time is it" must not wake,
    /// even though "so" is one letter away from the "seo" segment.
    public static func detectWake(_ transcript: String,
                                  roster: [String],
                                  wakeTokens: Set<String> = VoiceCommandParser.wakeTokens) -> Bool {
        // `requireAgent: true` so an ambiguous name still reports its
        // candidates — that is exactly the case the wake phrase must catch.
        let parsed = parse(transcript, roster: roster, requireAgent: true, wakeTokens: wakeTokens)
        guard parsed.usedWakeToken else { return false }
        if parsed.agent != nil {
            if parsed.score >= wakeExactThreshold { return true }
            return parsed.score >= wakeScoreThreshold && parsed.aliasCharacters >= wakeFuzzyMinAliasLength
        }
        if !parsed.candidates.isEmpty {
            return parsed.score >= wakeExactThreshold
        }
        return false
    }
}
