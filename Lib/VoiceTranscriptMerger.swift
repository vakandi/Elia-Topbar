import Foundation

/// Merges the live transcript with the final one.
///
/// The on-device transcriber writes the text down while the user is still
/// talking. Whisper then transcribes only the tail that came after the last
/// settled word, which is fast. The two have to be joined without repeating
/// the overlap.
public enum VoiceTranscriptMerger {

    /// Join the settled text with the freshly transcribed tail.
    public static func merge(committed: String, tail: String) -> String {
        let committedWords = words(committed)
        let tailWords = words(tail)

        if committedWords.isEmpty { return tail.trimmingCharacters(in: .whitespacesAndNewlines) }
        if tailWords.isEmpty { return committed.trimmingCharacters(in: .whitespacesAndNewlines) }

        let left = committedWords.map(normalizeWord)
        let right = tailWords.map(normalizeWord)

        // Whisper heard everything, and more: the tail wins.
        if left.count <= right.count && matches(Array(right.prefix(left.count)), left) {
            return tail.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // The tail repeats the last words of the settled text: drop them.
        let overlap = min(left.count, right.count)
        if overlap > 0 {
            for size in stride(from: overlap, through: 1, by: -1) {
                if matches(Array(right.prefix(size)), Array(left.suffix(size))) {
                    let merged = committedWords + Array(tailWords.dropFirst(size))
                    return merged.joined(separator: " ")
                }
            }
        }

        return (committedWords + tailWords).joined(separator: " ")
    }

    /// Compare two word lists word by word, allowing one small spelling
    /// difference: "ok" and "okay" are the same word for this job.
    static func matches(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) where !similar(left, right) {
            return false
        }
        return true
    }

    /// Two words are the same when they are equal, or when one small
    /// difference apart and long enough for that to be safe.
    ///
    /// "ok" and "okay" are the same word to this job: both transcriptions
    /// describe the same audio, they just spelled it differently.
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        guard shorter.count >= 2, longer.count >= 3 else { return false }
        return distance(shorter, longer) <= 2
    }

    /// Levenshtein distance, capped for speed.
    static func distance(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[y.count]
    }

    /// Split into words, dropping empty ones.
    static func words(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    /// Lowercase and drop everything that is not a letter or a digit.
    static func normalizeWord(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
