import Foundation

public struct VideoFileFingerprint: Codable, Hashable, Sendable {
    public let canonicalPath: String
    public let size: Int64
    public let modificationDate: Date
    public let analyzerVersion: String

    public init(canonicalPath: String, size: Int64, modificationDate: Date, analyzerVersion: String) {
        self.canonicalPath = canonicalPath
        self.size = size
        self.modificationDate = modificationDate
        self.analyzerVersion = analyzerVersion
    }
}

public struct StoredVideoAnalysis: Codable, Hashable, Sendable {
    public let fingerprint: VideoFileFingerprint
    public let result: VideoAnalysisResult
    public let analyzedAt: Date
    public let managedTagNames: [String]

    public init(fingerprint: VideoFileFingerprint, result: VideoAnalysisResult, analyzedAt: Date, managedTagNames: [String] = []) {
        self.fingerprint = fingerprint
        self.result = result
        self.analyzedAt = analyzedAt
        self.managedTagNames = managedTagNames
    }
}

public enum VideoAnalysisStoreError: Error, Equatable, LocalizedError {
    case corruptedStore
    case unsupportedSchemaVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .corruptedStore: "The video analysis result store is corrupted."
        case .unsupportedSchemaVersion(let version): "Unsupported video analysis store version: \(version)"
        }
    }
}

public actor VideoAnalysisResultStore {
    private struct StoreFile: Codable {
        let schemaVersion: Int
        var records: [String: StoredVideoAnalysis]

        static let empty = StoreFile(schemaVersion: 1, records: [:])
    }

    private let directory: URL
    private let indexURL: URL

    public init(directory: URL) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
    }

    public func load(for fingerprint: VideoFileFingerprint) throws -> StoredVideoAnalysis? {
        let store = try readStore()
        guard let stored = store.records[fingerprint.canonicalPath], stored.fingerprint == fingerprint else {
            return nil
        }
        return stored
    }

    public func save(_ stored: StoredVideoAnalysis) throws {
        var store = try readStore()
        store.records[stored.fingerprint.canonicalPath] = stored
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".index-\(UUID().uuidString).tmp")
        do {
            let data = try JSONEncoder.openFinder.encode(store)
            try data.write(to: temporaryURL)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                _ = try FileManager.default.replaceItemAt(indexURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: indexURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func readStore() throws -> StoreFile {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return .empty }
        do {
            let store = try JSONDecoder.openFinder.decode(StoreFile.self, from: Data(contentsOf: indexURL))
            guard store.schemaVersion == 1 else {
                throw VideoAnalysisStoreError.unsupportedSchemaVersion(store.schemaVersion)
            }
            return store
        } catch let error as VideoAnalysisStoreError {
            throw error
        } catch is DecodingError {
            throw VideoAnalysisStoreError.corruptedStore
        }
    }
}
