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
    private static let pathPattern = #"(?:@|\.\/)?(?:[\w\-\.]+\/)+[\w\-\.]+\.\w{1,10}"#

    // Matches "Saved X", "Created X", "Wrote X", "Written to X" patterns
    private static let actionPattern = #"(?:Saved|Created|Wrote|Written to)\s+([\w\-\.\/]+\.\w{1,10})"#

    static func detect(in text: String) -> [DetectedFilePath] {
        var results: [DetectedFilePath] = []
        var seenPaths = Set<String>()

        // Direct path matches
        if let regex = try? NSRegularExpression(pattern: pathPattern, options: []) {
            let nsRange = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, options: [], range: nsRange)
            for match in matches {
                if let range = Range(match.range, in: text) {
                    var path = String(text[range])
                    if path.hasPrefix("@") { path = String(path.dropFirst()) }
                    if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
                    guard !seenPaths.contains(path) else { continue }
                    seenPaths.insert(path)
                    let ext = path.components(separatedBy: ".").last?.lowercased() ?? ""
                    results.append(DetectedFilePath(
                        path: path,
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
                    let path = String(text[pathRange])
                    guard !seenPaths.contains(path) else { continue }
                    seenPaths.insert(path)
                    let ext = path.components(separatedBy: ".").last?.lowercased() ?? ""
                    results.append(DetectedFilePath(
                        path: path,
                        range: pathRange,
                        isImage: DetectedFilePath.imageExtensions.contains(ext)
                    ))
                }
            }
        }

        return results
    }
}
