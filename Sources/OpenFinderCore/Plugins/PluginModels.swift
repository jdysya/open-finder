import Foundation

public enum PluginRuntime: Hashable, Sendable {
    case shell
    case python3(minimumVersion: String? = nil)
    case node(minimumVersion: String? = nil)

    public var typeName: String {
        switch self {
        case .shell: "shell"
        case .python3: "python3"
        case .node: "node"
        }
    }
}

extension PluginRuntime: Codable {
    private enum CodingKeys: String, CodingKey { case type, minimumVersion }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            switch single {
            case "shell": self = .shell
            case "python3": self = .python3(minimumVersion: nil)
            case "node": self = .node(minimumVersion: nil)
            default: throw OpenFinderError.invalidPluginManifest("Unknown runtime \(single)")
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let minimumVersion = try container.decodeIfPresent(String.self, forKey: .minimumVersion)
        switch type {
        case "shell": self = .shell
        case "python3": self = .python3(minimumVersion: minimumVersion)
        case "node": self = .node(minimumVersion: minimumVersion)
        default: throw OpenFinderError.invalidPluginManifest("Unknown runtime \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(typeName, forKey: .type)
        switch self {
        case .shell: break
        case .python3(let minimumVersion), .node(let minimumVersion):
            try container.encodeIfPresent(minimumVersion, forKey: .minimumVersion)
        }
    }
}

public enum PluginExecution: Hashable, Sendable {
    case process(runtime: PluginRuntime, entry: String)
    case http(protocolVersion: Int, endpointConfigurationKey: String, tokenSecretKey: String)
}

public struct PluginManifest: Identifiable, Hashable, Sendable {
    public let schemaVersion: Int
    public let id: String
    public let name: String
    public let version: String
    public let description: String?
    public let author: String?
    public let execution: PluginExecution
    public let actions: [PluginActionManifest]
    public let permissions: PluginPermissions
    public let configuration: [PluginConfigField]

    public init(
        schemaVersion: Int,
        id: String,
        name: String,
        version: String,
        description: String?,
        author: String?,
        execution: PluginExecution,
        actions: [PluginActionManifest],
        permissions: PluginPermissions,
        configuration: [PluginConfigField]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.execution = execution
        self.actions = actions
        self.permissions = permissions
        self.configuration = configuration
    }
}

public struct PluginActionManifest: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let category: String?
    public let selection: PluginSelectionRule
    public let match: PluginMatchRule?
    public let output: PluginActionOutput?

    public init(id: String, title: String, category: String?, selection: PluginSelectionRule, match: PluginMatchRule?, output: PluginActionOutput?) {
        self.id = id
        self.title = title
        self.category = category
        self.selection = selection
        self.match = match
        self.output = output
    }
}

public struct PluginSelectionRule: Codable, Hashable, Sendable {
    public let minItems: Int
    public let maxItems: Int?
    public let allowDirectories: Bool

    public init(minItems: Int = 0, maxItems: Int? = nil, allowDirectories: Bool = true) {
        self.minItems = minItems
        self.maxItems = maxItems
        self.allowDirectories = allowDirectories
    }
}

public enum PluginMatchMode: String, Codable, Hashable, Sendable {
    case all
    case any
}

public struct PluginMatchRule: Codable, Hashable, Sendable {
    public let extensions: [String]
    public let uttypes: [String]
    public let mimePrefixes: [String]
    public let matchMode: PluginMatchMode

    public init(extensions: [String] = [], uttypes: [String] = [], mimePrefixes: [String] = [], matchMode: PluginMatchMode = .all) {
        self.extensions = extensions
        self.uttypes = uttypes
        self.mimePrefixes = mimePrefixes
        self.matchMode = matchMode
    }
}

public struct PluginActionOutput: Codable, Hashable, Sendable {
    public let resultType: String?
    public let canCopyToClipboard: Bool

    public init(resultType: String?, canCopyToClipboard: Bool) {
        self.resultType = resultType
        self.canCopyToClipboard = canCopyToClipboard
    }
}

public struct PluginNetworkPermission: Codable, Hashable, Sendable {
    public let required: Bool
    public let hosts: [String]

    public init(required: Bool = false, hosts: [String] = []) {
        self.required = required
        self.hosts = hosts
    }
}

public struct PluginPermissions: Codable, Hashable, Sendable {
    public let readFiles: String
    public let writeFiles: String
    public let network: PluginNetworkPermission
    public let clipboardWrite: Bool
    public let clipboardRead: Bool
    public let keychainSecrets: [String]
    public let localSecrets: [String]
    public let remoteAccounts: Bool
    public let runExternalCommands: Bool

    public static let none = PluginPermissions(readFiles: "none", writeFiles: "none", network: .init(), clipboardWrite: false, clipboardRead: false, keychainSecrets: [], remoteAccounts: false, runExternalCommands: false)

    public init(readFiles: String, writeFiles: String, network: PluginNetworkPermission, clipboardWrite: Bool, clipboardRead: Bool, keychainSecrets: [String], remoteAccounts: Bool, runExternalCommands: Bool, localSecrets: [String] = []) {
        self.readFiles = readFiles
        self.writeFiles = writeFiles
        self.network = network
        self.clipboardWrite = clipboardWrite
        self.clipboardRead = clipboardRead
        self.keychainSecrets = keychainSecrets
        self.localSecrets = localSecrets
        self.remoteAccounts = remoteAccounts
        self.runExternalCommands = runExternalCommands
    }

    public var secretKeys: [String] { keychainSecrets + localSecrets }

    public func storage(for key: String) -> PluginSecretStorage? {
        let isKeychain = keychainSecrets.contains(key)
        let isLocal = localSecrets.contains(key)
        guard isKeychain != isLocal else { return nil }
        return isLocal ? .localConfiguration : .keychain
    }

    private enum CodingKeys: String, CodingKey {
        case readFiles
        case writeFiles
        case network
        case clipboardWrite
        case clipboardRead
        case keychainSecrets
        case localSecrets
        case remoteAccounts
        case runExternalCommands
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            readFiles: try container.decode(String.self, forKey: .readFiles),
            writeFiles: try container.decode(String.self, forKey: .writeFiles),
            network: try container.decode(PluginNetworkPermission.self, forKey: .network),
            clipboardWrite: try container.decode(Bool.self, forKey: .clipboardWrite),
            clipboardRead: try container.decode(Bool.self, forKey: .clipboardRead),
            keychainSecrets: try container.decodeIfPresent([String].self, forKey: .keychainSecrets) ?? [],
            remoteAccounts: try container.decode(Bool.self, forKey: .remoteAccounts),
            runExternalCommands: try container.decode(Bool.self, forKey: .runExternalCommands),
            localSecrets: try container.decodeIfPresent([String].self, forKey: .localSecrets) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(readFiles, forKey: .readFiles)
        try container.encode(writeFiles, forKey: .writeFiles)
        try container.encode(network, forKey: .network)
        try container.encode(clipboardWrite, forKey: .clipboardWrite)
        try container.encode(clipboardRead, forKey: .clipboardRead)
        try container.encode(keychainSecrets, forKey: .keychainSecrets)
        try container.encode(localSecrets, forKey: .localSecrets)
        try container.encode(remoteAccounts, forKey: .remoteAccounts)
        try container.encode(runExternalCommands, forKey: .runExternalCommands)
    }
}

public struct PluginConfigField: Codable, Hashable, Sendable {
    public let key: String
    public let type: String
    public let title: String
    public let defaultValue: String?
    public let required: Bool
    public let storage: String?
    public let options: [PluginConfigOption]?

    private enum CodingKeys: String, CodingKey { case key, type, title, defaultValue = "default", required, storage, options }

    public init(key: String, type: String, title: String, defaultValue: String? = nil, required: Bool = false, storage: String? = nil, options: [PluginConfigOption]? = nil) {
        self.key = key
        self.type = type
        self.title = title
        self.defaultValue = defaultValue
        self.required = required
        self.storage = storage
        self.options = options
    }
}

public struct PluginConfigOption: Codable, Hashable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct PluginSecretReference: Codable, Hashable, Sendable {
    public let env: String

    public init(env: String) { self.env = env }
}

public struct PluginInput: Codable, Hashable, Sendable {
    public struct AppInfo: Codable, Hashable, Sendable {
        public let name: String
        public let version: String
        public init(name: String, version: String) { self.name = name; self.version = version }
    }

    public struct Context: Codable, Hashable, Sendable {
        public let activePane: String
        public let currentLocation: Location
        public init(activePane: String, currentLocation: Location) { self.activePane = activePane; self.currentLocation = currentLocation }
    }

    public let schemaVersion: Int
    public let taskID: UUID
    public let actionID: String
    public let app: AppInfo
    public let context: Context
    public let files: [PluginInputFile]
    public let config: [String: String]
    public let secrets: [String: PluginSecretReference]
    public let tempDirectory: String
    public let outputDirectory: String

    public init(schemaVersion: Int, taskID: UUID, actionID: String, app: AppInfo, context: Context, files: [PluginInputFile], config: [String: String], secrets: [String: PluginSecretReference], tempDirectory: String, outputDirectory: String) {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.actionID = actionID
        self.app = app
        self.context = context
        self.files = files
        self.config = config
        self.secrets = secrets
        self.tempDirectory = tempDirectory
        self.outputDirectory = outputDirectory
    }
}

public struct PluginInputFile: Codable, Hashable, Sendable {
    public let path: String
    public let name: String
    public let `extension`: String?
    public let uti: String?
    public let mimeType: String?
    public let size: Int64?
    public let isDirectory: Bool

    public init(item: FileItem) {
        self.path = item.location.localURL?.path ?? item.location.displayPath
        self.name = item.name
        self.extension = item.fileExtension
        self.uti = item.uti
        self.mimeType = item.mimeType
        self.size = item.size
        self.isDirectory = item.isDirectory
    }
}
