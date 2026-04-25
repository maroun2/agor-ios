import Foundation

struct DetectedSessionLink {
    let hash: String
    let range: Range<String.Index>
    /// Board slug extracted from an Agor URL (e.g. "deepgrove" from /b/deepgrove/04e1e6ef).
    /// Non-nil only for URL-detected links.
    var boardSlug: String? = nil
}

enum SessionLinkDetector {
    // Matches 8-char hex (short session IDs), full UUIDs, or session: prefixed
    private static let shortHashPattern = #"\b[0-9a-f]{8}\b"#
    private static let uuidPattern = #"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#
    private static let prefixedPattern = #"session[:\s]+([0-9a-f]{8})"#
    // Matches Agor board URLs: http(s)://host/b/{boardSlug}/{hash}
    // Captures: group 1 = boardSlug, group 2 = hash (8-char or full UUID)
    private static let agorUrlPattern = #"https?://[^\s/]+/b/([A-Za-z0-9_-]+)/([0-9a-f]{8}(?:-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?)\b"#

    static func detect(in text: String, knownSessionIds: Set<String>) -> [DetectedSessionLink] {
        var results: [DetectedSessionLink] = []
        var seenHashes = Set<String>()

        // Agor board URLs first — explicit links, no knownSessionIds check required
        if let regex = try? NSRegularExpression(pattern: agorUrlPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, options: [], range: nsRange)
                where match.numberOfRanges > 2 {
                if let range = Range(match.range, in: text),
                   let slugRange = Range(match.range(at: 1), in: text),
                   let hashRange = Range(match.range(at: 2), in: text) {
                    let boardSlug = String(text[slugRange])
                    let hash = String(text[hashRange]).lowercased()
                    guard !seenHashes.contains(hash) else { continue }
                    seenHashes.insert(hash)
                    results.append(DetectedSessionLink(hash: hash, range: range, boardSlug: boardSlug))
                }
            }
        }

        // Full UUIDs first
        if let regex = try? NSRegularExpression(pattern: uuidPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, options: [], range: nsRange) {
                if let range = Range(match.range, in: text) {
                    let uuid = String(text[range]).lowercased()
                    guard knownSessionIds.contains(uuid), !seenHashes.contains(uuid) else { continue }
                    seenHashes.insert(uuid)
                    results.append(DetectedSessionLink(hash: uuid, range: range))
                }
            }
        }

        // Prefixed session mentions
        if let regex = try? NSRegularExpression(pattern: prefixedPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, options: [], range: nsRange) where match.numberOfRanges > 1 {
                if let range = Range(match.range, in: text),
                   let hashRange = Range(match.range(at: 1), in: text) {
                    let hash = String(text[hashRange]).lowercased()
                    guard !seenHashes.contains(hash) else { continue }
                    seenHashes.insert(hash)
                    results.append(DetectedSessionLink(hash: hash, range: range))
                }
            }
        }

        // Short hashes — only match if they resolve to a known session
        if let regex = try? NSRegularExpression(pattern: shortHashPattern, options: []) {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, options: [], range: nsRange) {
                if let range = Range(match.range, in: text) {
                    let hash = String(text[range])
                    guard !seenHashes.contains(hash) else { continue }
                    // Check if any known session ID starts with this hash
                    if knownSessionIds.contains(where: { $0.hasPrefix(hash) }) {
                        seenHashes.insert(hash)
                        results.append(DetectedSessionLink(hash: hash, range: range))
                    }
                }
            }
        }

        return results
    }
}
