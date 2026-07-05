import Foundation

public struct AppConfiguration: Codable, Hashable, Sendable {
    public var defaultShowHiddenFiles: Bool
    public var confirmBeforePermanentDelete: Bool
    public var maxConcurrentTasks: Int
    public var python3Path: String?
    public var nodePath: String?
    public var pluginConfigurationValues: [String: [String: String]]

    public init(
        defaultShowHiddenFiles: Bool = false,
        confirmBeforePermanentDelete: Bool = true,
        maxConcurrentTasks: Int = 2,
        python3Path: String? = nil,
        nodePath: String? = nil,
        pluginConfigurationValues: [String: [String: String]] = [:]
    ) {
        self.defaultShowHiddenFiles = defaultShowHiddenFiles
        self.confirmBeforePermanentDelete = confirmBeforePermanentDelete
        self.maxConcurrentTasks = maxConcurrentTasks
        self.python3Path = python3Path
        self.nodePath = nodePath
        self.pluginConfigurationValues = pluginConfigurationValues
    }

    private enum CodingKeys: String, CodingKey {
        case defaultShowHiddenFiles
        case confirmBeforePermanentDelete
        case maxConcurrentTasks
        case python3Path
        case nodePath
        case pluginConfigurationValues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            defaultShowHiddenFiles: try container.decodeIfPresent(Bool.self, forKey: .defaultShowHiddenFiles) ?? false,
            confirmBeforePermanentDelete: try container.decodeIfPresent(Bool.self, forKey: .confirmBeforePermanentDelete) ?? true,
            maxConcurrentTasks: try container.decodeIfPresent(Int.self, forKey: .maxConcurrentTasks) ?? 2,
            python3Path: try container.decodeIfPresent(String.self, forKey: .python3Path),
            nodePath: try container.decodeIfPresent(String.self, forKey: .nodePath),
            pluginConfigurationValues: try container.decodeIfPresent([String: [String: String]].self, forKey: .pluginConfigurationValues) ?? [:]
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
    }
}

public actor JSONConfigStore {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppConfiguration() }
        return try JSONDecoder.openFinder.decode(AppConfiguration.self, from: Data(contentsOf: url))
    }

    public func save(_ configuration: AppConfiguration) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.openFinder.encode(configuration).write(to: url, options: .atomic)
    }
}
