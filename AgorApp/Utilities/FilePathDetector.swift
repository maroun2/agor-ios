import Foundation

struct DetectedFilePath {
    let path: String
    let range: Range<String.Index>
    let isImage: Bool

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "ico"]

    var fileExtension: String {
        path.components(separatedBy: ".").last?.lowercased() ?? ""
    }
}

enum FilePathDetector {
    // Matches file paths like: path/to/file.ext, ./file.ext, @path/to/file.ext
    // Must contain at least one slash or start with @ and have an extension
    // The leading "/" is part of the match: an absolute path used to be captured
    // from its second component onward, which silently turned it into a bogus
    // worktree-relative path that no lookup could recover.
    private static let pathPattern = #"(?:@|\.\/|\/)?(?:[\w\-\.]+\/)+[\w\-\.]+\.\w{2,10}"#

    // Matches "Saved X", "Created X", "Wrote X", "Written to X" patterns
    private static let actionPattern = #"(?:Saved|Created|Wrote|Written to)\s+([\w\-\.\/]+\.\w{2,10})"#

    // Matches bare filenames like file.ext (no slash required, extension >= 2 chars)
    private static let bareFilePattern = #"\b[\w\-]+\.\w{2,10}\b"#

    // URL pattern to exclude matches inside URLs
    private static let urlPattern = #"https?://\S+"#

    // Extensions that are domain TLDs, not file extensions
    private static let nonFileExtensions: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "co", "us", "uk", "eu",
        "live", "site", "info", "biz", "me", "ai", "gg", "tv", "fm"
    ]

    /// Detect file paths in text, optionally resolving partial names against a known file list.
    static func detect(in text: String, knownFiles: [String] = []) -> [DetectedFilePath] {
        var results: [DetectedFilePath] = []
        var seenPaths = Set<String>()

        // Build filename→fullPath lookup (only for unambiguous names)
        let filenameLookup = buildFilenameLookup(from: knownFiles)

        // Compute URL ranges to exclude matches inside URLs
        let urlRanges = findURLRanges(in: text)

        // Direct path matches (contains slash)
        if let regex = try? NSRegularExpression(pattern: pathPattern, options: []) {
            let nsRange = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: nsRange)
            for match in matches {
                if let range = Range(match.range, in: text) {
                    guard !overlapsURL(range, urlRanges: urlRanges) else { continue }
                    var path = String(text[range])
                    if path.hasPrefix("@") { path = String(path.dropFirst()) }
                    if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
                    let resolved = resolveToKnownFile(path, knownFiles: knownFiles, lookup: filenameLookup)
                    guard !seenPaths.contains(resolved) else { continue }
                    seenPaths.insert(resolved)
                    let ext = resolved.components(separatedBy: ".").last?.lowercased() ?? ""
                    results.append(DetectedFilePath(
                        path: resolved,
                        range: range,
                        isImage: DetectedFilePath.imageExtensions.contains(ext)
                    ))
                }
            }
        }

        // Action pattern matches (Saved file.png, etc.)
        if let regex = try? NSRegularExpression(pattern: actionPattern, options: []) {
            let nsRange = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: nsRange)
            for match in matches where match.numberOfRanges > 1 {
                if let pathRange = Range(match.range(at: 1), in: text) {
                    guard !overlapsURL(pathRange, urlRanges: urlRanges) else { continue }
                    let path = String(text[pathRange])
                    let resolved = resolveToKnownFile(path, knownFiles: knownFiles, lookup: filenameLookup)
                    guard !seenPaths.contains(resolved) else { continue }
                    seenPaths.insert(resolved)
                    let ext = resolved.components(separatedBy: ".").last?.lowercased() ?? ""
                    results.append(DetectedFilePath(
                        path: resolved,
                        range: pathRange,
                        isImage: DetectedFilePath.imageExtensions.contains(ext)
                    ))
                }
            }
        }

        // Bare filename matches — only resolve when there's exactly one match in known files
        if !knownFiles.isEmpty, let regex = try? NSRegularExpression(pattern: bareFilePattern, options: []) {
            let nsRange = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: nsRange)
            for match in matches {
                if let range = Range(match.range, in: text) {
                    guard !overlapsURL(range, urlRanges: urlRanges) else { continue }
                    let name = String(text[range])
                    let ext = name.components(separatedBy: ".").last?.lowercased() ?? ""
                    // Skip domain TLDs
                    guard !nonFileExtensions.contains(ext) else { continue }
                    // Skip if already captured by path/action patterns
                    guard !seenPaths.contains(name) else { continue }
                    // Only link if unambiguous single match in known files
                    if let fullPath = filenameLookup[name.lowercased()], !seenPaths.contains(fullPath) {
                        seenPaths.insert(fullPath)
                        let fullExt = fullPath.components(separatedBy: ".").last?.lowercased() ?? ""
                        results.append(DetectedFilePath(
                            path: fullPath,
                            range: range,
                            isImage: DetectedFilePath.imageExtensions.contains(fullExt)
                        ))
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

    private static func buildFilenameLookup(from knownFiles: [String]) -> [String: String] {
        var counts: [String: Int] = [:]
        var mapping: [String: String] = [:]
        for path in knownFiles {
            let name = (path.components(separatedBy: "/").last ?? path).lowercased()
            counts[name, default: 0] += 1
            mapping[name] = path
        }
        return mapping.filter { counts[$0.key] == 1 }
    }

    private static func resolveToKnownFile(_ path: String, knownFiles: [String], lookup: [String: String]) -> String {
        resolve(path, knownFiles: knownFiles, lookup: lookup)
    }

    /// Map a path as written in a message onto a real worktree-relative path.
    ///
    /// Messages quote paths in whatever form the agent used: absolute
    /// (`/Users/me/code/proj/src/main.swift`), prefixed with the worktree or
    /// repo directory, or bare. The daemon only accepts paths relative to the
    /// worktree root, so the leading part has to come off — but cutting it by
    /// guesswork is what produced "file not found" on paths the chat displayed
    /// correctly.
    ///
    /// This takes the *longest* trailing run of components that identifies
    /// exactly one known file. Trying longest-first is what keeps ambiguous
    /// basenames (`index.ts`, `README.md`) honest: `api/index.ts` wins over a
    /// coin flip between five files named `index.ts`. Falls back to a unique
    /// basename, and finally returns the path untouched.
    static func resolve(_ path: String, knownFiles: [String], lookup: [String: String]? = nil) -> String {
        guard !knownFiles.isEmpty else { return path }
        if knownFiles.contains(path) { return path }

        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if knownFiles.contains(trimmed) { return trimmed }

        let components = trimmed.split(separator: "/").map(String.init)
        // start = 0 is the whole path; each step drops one leading component,
        // so the first unique match found is the most specific one.
        for start in components.indices {
            let candidate = components[start...].joined(separator: "/")
            if knownFiles.contains(candidate) { return candidate }
            let matches = knownFiles.filter { $0.hasSuffix("/" + candidate) }
            if matches.count == 1 { return matches[0] }
        }

        let name = (components.last ?? trimmed).lowercased()
        let byName = lookup ?? buildFilenameLookup(from: knownFiles)
        if let resolved = byName[name] { return resolved }
        return path
    }
}
