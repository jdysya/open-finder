import AppKit
import OpenFinderCore

struct FileIconDescriptor: Equatable {
    let systemImageName: String
    let tintName: String

    static func descriptor(for item: FileItem) -> FileIconDescriptor {
        if item.kind == .directory {
            return .init(systemImageName: "folder.fill", tintName: "blue")
        }
        if item.kind == .package {
            return .init(systemImageName: "shippingbox.fill", tintName: "brown")
        }
        let ext = (item.fileExtension ?? URL(fileURLWithPath: item.name).pathExtension).lowercased()
        if imageExtensions.contains(ext) || item.mimeType?.hasPrefix("image/") == true {
            return .init(systemImageName: "photo.fill", tintName: "purple")
        }
        if videoExtensions.contains(ext) || item.mimeType?.hasPrefix("video/") == true {
            return .init(systemImageName: "film.fill", tintName: "pink")
        }
        if audioExtensions.contains(ext) || item.mimeType?.hasPrefix("audio/") == true {
            return .init(systemImageName: "music.note", tintName: "indigo")
        }
        if archiveExtensions.contains(ext) {
            return .init(systemImageName: "archivebox.fill", tintName: "orange")
        }
        if ext == "pdf" || item.mimeType == "application/pdf" {
            return .init(systemImageName: "doc.richtext.fill", tintName: "red")
        }
        if spreadsheetExtensions.contains(ext) {
            return .init(systemImageName: "tablecells.fill", tintName: "green")
        }
        if presentationExtensions.contains(ext) {
            return .init(systemImageName: "rectangle.on.rectangle.fill", tintName: "orange")
        }
        if codeExtensions.contains(ext) {
            return .init(systemImageName: "curlybraces", tintName: "teal")
        }
        if textExtensions.contains(ext) || item.mimeType?.hasPrefix("text/") == true {
            return .init(systemImageName: "doc.text.fill", tintName: "cyan")
        }
        return .init(systemImageName: "doc.fill", tintName: "secondary")
    }

    var tintColor: NSColor {
        switch tintName {
        case "blue": .systemBlue
        case "brown": .systemBrown
        case "purple": .systemPurple
        case "pink": .systemPink
        case "indigo": .systemIndigo
        case "orange": .systemOrange
        case "red": .systemRed
        case "green": .systemGreen
        case "teal": .systemTeal
        case "cyan": .systemCyan
        default: .secondaryLabelColor
        }
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "svg", "tiff", "bmp"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aiff", "flac", "ogg"]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "iso"]
    private static let spreadsheetExtensions: Set<String> = ["csv", "tsv", "xls", "xlsx", "numbers"]
    private static let presentationExtensions: Set<String> = ["ppt", "pptx", "key"]
    private static let codeExtensions: Set<String> = ["swift", "js", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "h", "m", "mm", "cpp", "hpp", "cs", "php", "sh", "zsh", "json", "yaml", "yml", "xml", "sql", "html", "css"]
    private static let textExtensions: Set<String> = ["txt", "md", "markdown", "rtf", "log"]
}
