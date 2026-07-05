import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public enum PluginMatcher {
    public static func action(_ action: PluginActionManifest, matches selection: [FileItem]) -> Bool {
        guard selection.count >= action.selection.minItems else { return false }
        if let maxItems = action.selection.maxItems, selection.count > maxItems { return false }
        if !action.selection.allowDirectories, selection.contains(where: { $0.isDirectory }) { return false }
        guard let match = action.match else { return true }
        switch match.matchMode {
        case .all:
            return selection.allSatisfy { fileMatches($0, rule: match) }
        case .any:
            return selection.contains { fileMatches($0, rule: match) }
        }
    }

    public static func actions(in manifest: PluginManifest, matching selection: [FileItem]) -> [PluginActionManifest] {
        manifest.actions.filter { action($0, matches: selection) }
    }

    private static func fileMatches(_ item: FileItem, rule: PluginMatchRule) -> Bool {
        let extensionMatches = rule.extensions.isEmpty || item.fileExtension.map { ext in
            rule.extensions.map { $0.lowercased() }.contains(ext.lowercased())
        } == true
        let utiMatches = rule.uttypes.isEmpty || item.uti.map { uti in
            rule.uttypes.contains { wanted in
                if uti == wanted || uti.hasPrefix(wanted + ".") { return true }
                #if canImport(UniformTypeIdentifiers)
                if #available(macOS 11.0, *), let actual = UTType(uti), let expected = UTType(wanted) {
                    return actual.conforms(to: expected)
                }
                #endif
                return wanted == "public.image" && (item.mimeType?.hasPrefix("image/") == true || ["png", "jpg", "jpeg", "gif", "webp"].contains(item.fileExtension?.lowercased() ?? ""))
            }
        } == true
        let mimeMatches = rule.mimePrefixes.isEmpty || item.mimeType.map { mime in
            rule.mimePrefixes.contains { mime.hasPrefix($0) }
        } == true
        return extensionMatches && utiMatches && mimeMatches
    }
}
