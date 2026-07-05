import Foundation

public enum OpenFinderError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedLocation(Location)
    case invalidFileName(String)
    case itemNotFound(String)
    case operationFailed(String)
    case invalidPluginManifest(String)
    case pluginRuntimeUnavailable(String)
    case invalidPluginOutput(String)
    case webDAVUnexpectedStatus(Int, String)
    case missingSecret(String)
    case timeout(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedLocation(let location): "Unsupported location: \(location.displayPath)"
        case .invalidFileName(let name): "Invalid file name: \(name)"
        case .itemNotFound(let path): "Item not found: \(path)"
        case .operationFailed(let message): message
        case .invalidPluginManifest(let message): "Invalid plugin manifest: \(message)"
        case .pluginRuntimeUnavailable(let runtime): "Plugin runtime unavailable: \(runtime)"
        case .invalidPluginOutput(let message): "Invalid plugin output: \(message)"
        case .webDAVUnexpectedStatus(let status, let method): "Unexpected WebDAV status \(status) for \(method)"
        case .missingSecret(let key): "Missing secret: \(key)"
        case .timeout(let message): message
        }
    }
}
