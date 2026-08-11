import Foundation
import AgentCore

/// SF Symbol names for folder browser rows. Decorative only — callers hide from
/// VoiceOver. Symbols are pinned to the macOS 14 catalog.
enum FolderFileIcon {
    static func systemImage(for entry: FolderFileEntry) -> String {
        if entry.isDirectory { return "folder" }
        let name = entry.name
        if let override = exactNameOverride(name) {
            return override
        }
        return extensionImage(entry.fileExtension)
    }

    private static func exactNameOverride(_ name: String) -> String? {
        let lower = name.lowercased()
        switch lower {
        case "dockerfile":
            return "shippingbox"
        case "makefile", "gnumakefile":
            return "hammer"
        case "package.swift":
            return "swift"
        default:
            break
        }
        if lower.hasPrefix("readme") { return "doc.richtext" }
        if lower.hasPrefix("license") { return "doc.plaintext" }
        if name.hasPrefix(".") {
            switch lower {
            case ".gitignore", ".dockerignore", ".gitattributes", ".gitmodules":
                return "eye.slash"
            default:
                return "gearshape"
            }
        }
        return nil
    }

    private static func extensionImage(_ ext: String) -> String {
        switch ext {
        case "swift":
            return "swift"
        case "js", "jsx":
            return "j.square"
        case "ts", "tsx":
            return "t.square"
        case "py":
            return "p.square"
        case "go":
            return "g.square"
        case "rs":
            return "r.square"
        case "java":
            return "cup.and.saucer"
        case "kt", "kts":
            return "k.square"
        case "c", "h":
            return "c.square"
        case "cpp", "cc", "cxx", "hpp":
            return "plus.forwardslash.minus"
        case "m", "mm":
            return "m.square"
        case "rb":
            return "diamond"
        case "sh", "bash", "zsh", "command", "fish":
            return "terminal"
        case "sql":
            return "cylinder"
        case "html", "htm":
            return "globe"
        case "css", "scss", "sass", "less":
            return "paintbrush"
        case "json":
            return "curlybraces"
        case "yml", "yaml", "toml", "xml", "plist":
            return "list.bullet.rectangle"
        case "md", "markdown", "pdf":
            return "doc.richtext"
        case "log", "txt":
            return "doc.text"
        case "png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp", "heic", "svg":
            return "photo"
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar":
            return "doc.zipper"
        case "":
            return "doc"
        default:
            return "doc"
        }
    }
}
