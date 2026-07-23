import Foundation

public enum PluginSource: String, Codable, Hashable, Sendable {
    case builtIn
    case user
    case development
    case unknown

    public var displayName: String {
        switch self {
        case .builtIn: "Built-in"
        case .user: "User"
        case .development: "Development"
        case .unknown: "Unknown"
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .builtIn: 3
        case .user: 2
        case .development: 1
        case .unknown: 0
        }
    }
}

public struct LoadedPlugin: Identifiable, Hashable, Sendable {
    public let id: String
    public let manifest: PluginManifest
    public let directory: URL
    public let source: PluginSource

    public init(
        manifest: PluginManifest,
        directory: URL,
        source: PluginSource = .unknown
    ) {
        self.id = manifest.id
        self.manifest = manifest
        self.directory = directory
        self.source = source
    }
}

public enum PluginLoadDiagnosticKind: String, Codable, Hashable, Sendable {
    case invalidPackage
    case invalidManifest
    case duplicateID
}

public struct PluginLoadDiagnostic: Identifiable, Hashable, Sendable {
    public var id: String {
        [kind.rawValue, source.rawValue, pluginID ?? "", pluginDirectory.path, message]
            .joined(separator: "|")
    }

    public let kind: PluginLoadDiagnosticKind
    public let source: PluginSource
    public let pluginDirectory: URL
    public let pluginID: String?
    public let message: String

    public init(
        kind: PluginLoadDiagnosticKind,
        source: PluginSource,
        pluginDirectory: URL,
        pluginID: String? = nil,
        message: String
    ) {
        self.kind = kind
        self.source = source
        self.pluginDirectory = pluginDirectory
        self.pluginID = pluginID
        self.message = message
    }
}

public struct PluginScanResult: Hashable, Sendable {
    public let loaded: [LoadedPlugin]
    public let diagnostics: [PluginLoadDiagnostic]

    public init(loaded: [LoadedPlugin], diagnostics: [PluginLoadDiagnostic]) {
        self.loaded = loaded
        self.diagnostics = diagnostics
    }
}

public struct PluginRegistry: Sendable {
    private static let supportedPackageExtensions = ["openfinderplugin", "plugin"]

    public init() {}

    /// Compatibility API for callers that require all-or-nothing loading.
    public func scan(directory: URL) throws -> [LoadedPlugin] {
        let result = try scanWithDiagnostics(directory: directory, source: .unknown)
        if let diagnostic = result.diagnostics.first {
            throw OpenFinderError.invalidPluginManifest(diagnostic.message)
        }
        return result.loaded
    }

    /// Scans every plugin independently so one invalid package cannot hide valid siblings.
    public func scanWithDiagnostics(
        directory: URL,
        source: PluginSource
    ) throws -> PluginScanResult {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return PluginScanResult(loaded: [], diagnostics: [])
        }
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var loaded: [LoadedPlugin] = []
        var diagnostics: [PluginLoadDiagnostic] = []
        for pluginURL in children {
            let manifestURL = pluginURL.appendingPathComponent("manifest.json")
            let hasManifest = FileManager.default.fileExists(atPath: manifestURL.path)
            guard Self.supportedPackageExtensions.contains(pluginURL.pathExtension.lowercased()) else {
                if hasManifest {
                    diagnostics.append(.init(
                        kind: .invalidPackage,
                        source: source,
                        pluginDirectory: pluginURL,
                        message: "\(pluginURL.lastPathComponent): plugin packages must end in .openfinderplugin or .plugin"
                    ))
                }
                continue
            }

            do {
                let values = try pluginURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw OpenFinderError.invalidPluginManifest(
                        "\(pluginURL.lastPathComponent): plugin package must be a real directory, not a file or symbolic link"
                    )
                }
                guard hasManifest else {
                    throw OpenFinderError.invalidPluginManifest(
                        "\(pluginURL.lastPathComponent): missing manifest.json"
                    )
                }
                let manifestValues = try manifestURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard manifestValues.isRegularFile == true,
                      manifestValues.isSymbolicLink != true else {
                    throw OpenFinderError.invalidPluginManifest(
                        "\(pluginURL.lastPathComponent): manifest.json must be a regular file, not a symbolic link"
                    )
                }
                let data = try Data(contentsOf: manifestURL)
                let manifest = try JSONDecoder.openFinder.decode(PluginManifest.self, from: data)
                try manifest.validate()
                try Self.validateProcessEntry(for: manifest, in: pluginURL)
                loaded.append(LoadedPlugin(manifest: manifest, directory: pluginURL, source: source))
            } catch {
                diagnostics.append(.init(
                    kind: .invalidManifest,
                    source: source,
                    pluginDirectory: pluginURL,
                    message: Self.diagnosticMessage(for: error, pluginURL: pluginURL)
                ))
            }
        }

        return PluginScanResult(
            loaded: loaded.sorted {
                $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
            },
            diagnostics: diagnostics
        )
    }

    public func resolveCatalog(from scanResults: [PluginScanResult]) -> PluginScanResult {
        let allPlugins = scanResults.flatMap(\.loaded)
        var diagnostics = scanResults.flatMap(\.diagnostics)
        var winners: [LoadedPlugin] = []

        for (pluginID, candidates) in Dictionary(grouping: allPlugins, by: \.id) {
            let ordered = candidates.sorted { lhs, rhs in
                if lhs.source.priority != rhs.source.priority {
                    return lhs.source.priority > rhs.source.priority
                }
                return lhs.directory.path.localizedStandardCompare(rhs.directory.path) == .orderedAscending
            }
            guard let winner = ordered.first else { continue }
            winners.append(winner)
            for ignored in ordered.dropFirst() {
                diagnostics.append(.init(
                    kind: .duplicateID,
                    source: ignored.source,
                    pluginDirectory: ignored.directory,
                    pluginID: pluginID,
                    message: "Duplicate plugin ID \(pluginID) ignored; \(winner.source.displayName) package \(winner.directory.lastPathComponent) has priority."
                ))
            }
        }

        return PluginScanResult(
            loaded: winners.sorted {
                let comparison = $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            },
            diagnostics: diagnostics.sorted {
                $0.pluginDirectory.path.localizedStandardCompare($1.pluginDirectory.path) == .orderedAscending
            }
        )
    }

    private static func validateProcessEntry(for manifest: PluginManifest, in pluginURL: URL) throws {
        guard case .process(_, let entry) = manifest.execution else { return }
        guard !entry.isEmpty, !entry.hasPrefix("/") else {
            throw OpenFinderError.invalidPluginManifest(
                "\(pluginURL.lastPathComponent): process entry must be a relative path"
            )
        }
        let packageRoot = pluginURL.resolvingSymlinksInPath().standardizedFileURL
        let entryURL = pluginURL.appendingPathComponent(entry).resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = packageRoot.path.hasSuffix("/") ? packageRoot.path : packageRoot.path + "/"
        guard entryURL.path.hasPrefix(rootPrefix) else {
            throw OpenFinderError.invalidPluginManifest(
                "\(pluginURL.lastPathComponent): process entry escapes the plugin package"
            )
        }
        let values = try entryURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw OpenFinderError.invalidPluginManifest(
                "\(pluginURL.lastPathComponent): process entry does not name a regular file"
            )
        }
    }

    private static func diagnosticMessage(for error: Error, pluginURL: URL) -> String {
        if case OpenFinderError.invalidPluginManifest(let message) = error {
            return message.hasPrefix(pluginURL.lastPathComponent)
                ? message
                : "\(pluginURL.lastPathComponent): \(message)"
        }
        return "\(pluginURL.lastPathComponent): \(error.localizedDescription)"
    }
}
