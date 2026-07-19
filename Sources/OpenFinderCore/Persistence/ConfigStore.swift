import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct AppConfiguration: Codable, Hashable, Sendable {
    public var defaultShowHiddenFiles: Bool
    public var confirmBeforePermanentDelete: Bool
    public var maxConcurrentTasks: Int
    public var python3Path: String?
    public var nodePath: String?
    public var pluginConfigurationValues: [String: [String: String]]
    public var localPluginSecrets: [String: [String: String]]
    public var videoAnalyzerLegacyServerTokenCleared: Bool

    public init(
        defaultShowHiddenFiles: Bool = false,
        confirmBeforePermanentDelete: Bool = true,
        maxConcurrentTasks: Int = 2,
        python3Path: String? = nil,
        nodePath: String? = nil,
        pluginConfigurationValues: [String: [String: String]] = [:],
        localPluginSecrets: [String: [String: String]] = [:],
        videoAnalyzerLegacyServerTokenCleared: Bool = false
    ) {
        self.defaultShowHiddenFiles = defaultShowHiddenFiles
        self.confirmBeforePermanentDelete = confirmBeforePermanentDelete
        self.maxConcurrentTasks = maxConcurrentTasks
        self.python3Path = python3Path
        self.nodePath = nodePath
        self.pluginConfigurationValues = pluginConfigurationValues
        self.localPluginSecrets = localPluginSecrets
        self.videoAnalyzerLegacyServerTokenCleared = videoAnalyzerLegacyServerTokenCleared
    }

    private enum CodingKeys: String, CodingKey {
        case defaultShowHiddenFiles
        case confirmBeforePermanentDelete
        case maxConcurrentTasks
        case python3Path
        case nodePath
        case pluginConfigurationValues
        case localPluginSecrets
        case videoAnalyzerLegacyServerTokenCleared
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            defaultShowHiddenFiles: try container.decodeIfPresent(Bool.self, forKey: .defaultShowHiddenFiles) ?? false,
            confirmBeforePermanentDelete: try container.decodeIfPresent(Bool.self, forKey: .confirmBeforePermanentDelete) ?? true,
            maxConcurrentTasks: try container.decodeIfPresent(Int.self, forKey: .maxConcurrentTasks) ?? 2,
            python3Path: try container.decodeIfPresent(String.self, forKey: .python3Path),
            nodePath: try container.decodeIfPresent(String.self, forKey: .nodePath),
            pluginConfigurationValues: try container.decodeIfPresent([String: [String: String]].self, forKey: .pluginConfigurationValues) ?? [:],
            localPluginSecrets: try container.decodeIfPresent([String: [String: String]].self, forKey: .localPluginSecrets) ?? [:],
            videoAnalyzerLegacyServerTokenCleared: try container.decodeIfPresent(
                Bool.self,
                forKey: .videoAnalyzerLegacyServerTokenCleared
            ) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultShowHiddenFiles, forKey: .defaultShowHiddenFiles)
        try container.encode(confirmBeforePermanentDelete, forKey: .confirmBeforePermanentDelete)
        try container.encode(maxConcurrentTasks, forKey: .maxConcurrentTasks)
        try container.encodeIfPresent(python3Path, forKey: .python3Path)
        try container.encodeIfPresent(nodePath, forKey: .nodePath)
        try container.encode(pluginConfigurationValues, forKey: .pluginConfigurationValues)
        try container.encode(localPluginSecrets, forKey: .localPluginSecrets)
        try container.encode(
            videoAnalyzerLegacyServerTokenCleared,
            forKey: .videoAnalyzerLegacyServerTokenCleared
        )
    }
}

public protocol AppConfigurationStore: Sendable {
    func load() async throws -> AppConfiguration
    func save(_ configuration: AppConfiguration) async throws
}

public actor JSONConfigStore: AppConfigurationStore {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() async throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppConfiguration() }
        return try JSONDecoder.openFinder.decode(AppConfiguration.self, from: Data(contentsOf: url))
    }

    public func save(_ configuration: AppConfiguration) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writeAtomicallySecured(JSONEncoder.openFinder.encode(configuration), to: url)
    }

    private static func writeAtomicallySecured(_ data: Data, to destination: URL) throws {
        #if canImport(Darwin)
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporary) }
        }

        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { throw posixError() }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        let renameResult = temporary.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard renameResult == 0 else { throw posixError() }
        shouldRemoveTemporary = false
        #else
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        #endif
    }

    #if canImport(Darwin)
    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(Darwin.errno))
    }
    #endif
}
