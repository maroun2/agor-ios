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
    private static let hashFragment = #"[0-9a-f]{8}(?:-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?"#

    // Agor desktop board URLs: http(s)://host[/prefix]/b/{boardSlug}/{hash}[/]
    // Captures: group 1 = boardSlug, group 2 = hash (8-char or full UUID).
    //
    // The path prefix is matched lazily rather than anchoring /b/ to the host:
    // when the daemon serves the built UI, every route is under /ui (the web
    // app's basename), so a real production link is /ui/b/slug/hash/ and
    // anchoring at the host missed all of them.
    private static let agorUrlPattern = #"https?://[^\s/]+(?:/[^\s/]+)*?/b/([A-Za-z0-9_-]+)/("# + hashFragment + #")/?"#

    // Agor mobile URLs: http(s)://host[/prefix]/m/session/{uuid}
    // The mobile route carries the full UUID rather than a short hash.
    private static let agorMobileUrlPattern = #"https?://[^\s/]+(?:/[^\s/]+)*?/m/session/("# + hashFragment + #")/?"#

    private static let urlPattern = #"https?://\S+"#

    static func detect(in text: String, knownSessionIds: Set<String>) -> [DetectedSessionLink] {
        var results: [DetectedSessionLink] = []
        var seenHashes = Set<String>()
        // Bare hex inside a URL is almost never a session: a commit link or an
        // asset digest that happens to share eight characters with a session id
        // used to become a session chip. Explicit Agor links are matched by
        // their own patterns above and are unaffected by this.
        let urlRanges = findURLRanges(in: text)

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

        // Agor mobile session URLs — also explicit, no known-id check
        if let regex = try? NSRegularExpression(pattern: agorMobileUrlPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, options: [], range: nsRange)
                where match.numberOfRanges > 1 {
                if let range = Range(match.range, in: text),
                   let hashRange = Range(match.range(at: 1), in: text) {
                    let hash = String(text[hashRange]).lowercased()
                    guard !seenHashes.contains(hash) else { continue }
                    seenHashes.insert(hash)
                    results.append(DetectedSessionLink(hash: hash, range: range))
                }
            }
        }

        // Full UUIDs first
        if let regex = try? NSRegularExpression(pattern: uuidPattern, options: [.caseInsensitive]) {
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, options: [], range: nsRange) {
                if let range = Range(match.range, in: text) {
                    let uuid = String(text[range]).lowercased()
                    guard !overlapsURL(range, urlRanges: urlRanges) else { continue }
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
                    guard !overlapsURL(range, urlRanges: urlRanges) else { continue }
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

    // MARK: - Private Helpers

    private static func findURLRanges(in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: urlPattern, options: []) else { return [] }
        let nsRange = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: nsRange).compactMap {
            Range($0.range, in: text)
        }
    }

    private static func overlapsURL(_ range: Range<String.Index>, urlRanges: [Range<String.Index>]) -> Bool {
        urlRanges.contains { $0.overlaps(range) }
    }
}
