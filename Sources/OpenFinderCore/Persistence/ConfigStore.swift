import Foundation

public struct AppConfiguration: Codable, Hashable, Sendable {
    public var defaultShowHiddenFiles: Bool
    public var confirmBeforePermanentDelete: Bool
    public var maxConcurrentTasks: Int
    public var python3Path: String?
    public var nodePath: String?

    public init(defaultShowHiddenFiles: Bool = false, confirmBeforePermanentDelete: Bool = true, maxConcurrentTasks: Int = 2, python3Path: String? = nil, nodePath: String? = nil) {
        self.defaultShowHiddenFiles = defaultShowHiddenFiles
        self.confirmBeforePermanentDelete = confirmBeforePermanentDelete
        self.maxConcurrentTasks = maxConcurrentTasks
        self.python3Path = python3Path
        self.nodePath = nodePath
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
