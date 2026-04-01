import Foundation

struct FileListItem: Codable, Identifiable {
    let path: String
    let title: String
    var size: Int?
    let lastModified: String
    var isText: Bool?
    var mimeType: String?

    var id: String { path }

    var fileName: String {
        path.components(separatedBy: "/").last ?? path
    }

    var parentDirectory: String {
        let components = path.components(separatedBy: "/")
        return components.count > 1 ? components.dropLast().joined(separator: "/") : ""
    }

    var fileExtension: String {
        fileName.components(separatedBy: ".").last?.lowercased() ?? ""
    }

    var iconName: String {
        if isImageFile { return "photo" }
        switch fileExtension {
        case "md", "markdown": return "doc.richtext"
        case "json": return "curlybraces"
        case "swift", "ts", "tsx", "js", "jsx", "py", "rb", "go", "rs", "java", "c", "cpp", "h":
            return "chevron.left.forwardslash.chevron.right"
        case "css", "scss", "less": return "paintbrush"
        case "html", "xml", "svg": return "globe"
        case "yaml", "yml", "toml", "ini": return "gearshape"
        case "sh", "bash", "zsh": return "terminal"
        case "sql": return "cylinder"
        default: return "doc"
        }
    }

    var isImageFile: Bool {
        ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico"].contains(fileExtension)
    }

    var formattedSize: String {
        guard let size else { return "—" }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return "\(size / 1024) KB" }
        return String(format: "%.1f MB", Double(size) / (1024 * 1024))
    }

    enum CodingKeys: String, CodingKey {
        case path, title, size, isText, mimeType
        case lastModified
    }
}

struct FileDetail: Codable {
    let path: String
    let title: String
    var size: Int?
    let lastModified: String
    var isText: Bool?
    var mimeType: String?
    var content: String?
    var encoding: String?

    enum CodingKeys: String, CodingKey {
        case path, title, size, isText, mimeType, content, encoding
        case lastModified
    }
}
