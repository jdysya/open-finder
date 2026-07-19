import AppKit
import OpenFinderCore

func revealPluginDirectory(_ plugin: LoadedPlugin) {
    NSWorkspace.shared.activateFileViewerSelecting([plugin.directory])
}

func pluginSelectionSummary(_ rule: PluginSelectionRule) -> String {
    let count: String
    if let maxItems = rule.maxItems, maxItems == rule.minItems {
        count = "\(rule.minItems) item(s)"
    } else if let maxItems = rule.maxItems {
        count = "\(rule.minItems)-\(maxItems) item(s)"
    } else {
        count = "\(rule.minItems)+ item(s)"
    }
    return rule.allowDirectories ? "Selection: \(count), files or folders" : "Selection: \(count), files only"
}

func pluginMatchSummary(_ match: PluginMatchRule?) -> String {
    guard let match else { return "Appears for any matching selection count." }
    var parts: [String] = []
    if !match.extensions.isEmpty {
        parts.append("extensions: " + match.extensions.map { ".\($0)" }.joined(separator: ", "))
    }
    if !match.uttypes.isEmpty {
        parts.append("types: " + match.uttypes.joined(separator: ", "))
    }
    if !match.mimePrefixes.isEmpty {
        parts.append("MIME: " + match.mimePrefixes.joined(separator: ", "))
    }
    return parts.isEmpty ? "No file-type restrictions." : "Appears for \(parts.joined(separator: "; "))."
}

func pluginPermissionRows(_ permissions: PluginPermissions) -> [String] {
    var rows = [
        "Read files: \(permissions.readFiles)",
        "Write files: \(permissions.writeFiles)"
    ]
    if permissions.runExternalCommands { rows.append("Can run external commands") }
    if permissions.clipboardRead { rows.append("Can read clipboard") }
    if permissions.clipboardWrite { rows.append("Can write clipboard") }
    if permissions.network.required {
        rows.append("Network: \(permissions.network.hosts.isEmpty ? "allowed" : permissions.network.hosts.joined(separator: ", "))")
    }
    if !permissions.keychainSecrets.isEmpty {
        rows.append("Keychain secrets: \(permissions.keychainSecrets.joined(separator: ", "))")
    }
    if !permissions.localSecrets.isEmpty {
        rows.append("Secured local config secrets: \(permissions.localSecrets.joined(separator: ", "))")
    }
    if permissions.remoteAccounts { rows.append("Can access configured remote accounts") }
    return rows
}
