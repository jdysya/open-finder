import Foundation

extension PluginExecution: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case runtime
        case entry
        case protocolVersion
        case endpointConfigurationKey
        case tokenSecretKey
    }

    public init(from decoder: Decoder) throws {
        do {
            self = try Self.decode(from: decoder)
        } catch let error as OpenFinderError {
            throw error
        } catch {
            throw OpenFinderError.invalidPluginManifest("Malformed execution descriptor: \(error.localizedDescription)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .process(let runtime, let entry):
            try container.encode("process", forKey: .type)
            try container.encode(runtime, forKey: .runtime)
            try container.encode(entry, forKey: .entry)
        case .http(let protocolVersion, let endpointConfigurationKey, let tokenSecretKey):
            try container.encode("http", forKey: .type)
            try container.encode(protocolVersion, forKey: .protocolVersion)
            try container.encode(endpointConfigurationKey, forKey: .endpointConfigurationKey)
            try container.encode(tokenSecretKey, forKey: .tokenSecretKey)
        }
    }

    private static func decode(from decoder: Decoder) throws -> Self {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "process":
            guard !container.contains(.protocolVersion),
                  !container.contains(.endpointConfigurationKey),
                  !container.contains(.tokenSecretKey) else {
                throw OpenFinderError.invalidPluginManifest("Process execution cannot declare HTTP fields")
            }
            return .process(
                runtime: try container.decode(PluginRuntime.self, forKey: .runtime),
                entry: try container.decode(String.self, forKey: .entry)
            )
        case "http":
            guard !container.contains(.runtime), !container.contains(.entry) else {
                throw OpenFinderError.invalidPluginManifest("HTTP execution cannot declare process fields")
            }
            return .http(
                protocolVersion: try container.decode(Int.self, forKey: .protocolVersion),
                endpointConfigurationKey: try container.decode(String.self, forKey: .endpointConfigurationKey),
                tokenSecretKey: try container.decode(String.self, forKey: .tokenSecretKey)
            )
        default:
            throw OpenFinderError.invalidPluginManifest("Unknown execution type \(type)")
        }
    }
}

extension PluginManifest: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case version
        case description
        case author
        case runtime
        case entry
        case execution
        case actions
        case permissions
        case configuration
    }

    public var runtime: PluginRuntime {
        guard case .process(let runtime, _) = execution else {
            preconditionFailure("HTTP plugin manifests do not have a process runtime")
        }
        return runtime
    }

    public var entry: String {
        guard case .process(_, let entry) = execution else {
            preconditionFailure("HTTP plugin manifests do not have a process entry")
        }
        return entry
    }

    public init(
        schemaVersion: Int,
        id: String,
        name: String,
        version: String,
        description: String?,
        author: String?,
        runtime: PluginRuntime,
        entry: String,
        actions: [PluginActionManifest],
        permissions: PluginPermissions,
        configuration: [PluginConfigField]
    ) {
        self.init(
            schemaVersion: schemaVersion,
            id: id,
            name: name,
            version: version,
            description: description,
            author: author,
            execution: .process(runtime: runtime, entry: entry),
            actions: actions,
            permissions: permissions,
            configuration: configuration
        )
    }

    public init(from decoder: Decoder) throws {
        do {
            self = try Self.decode(from: decoder)
        } catch let error as OpenFinderError {
            throw error
        } catch {
            throw OpenFinderError.invalidPluginManifest("Malformed manifest: \(error.localizedDescription)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(author, forKey: .author)
        try container.encode(actions, forKey: .actions)
        try container.encode(permissions, forKey: .permissions)
        try container.encode(configuration, forKey: .configuration)
        switch execution {
        case .process(let runtime, let entry):
            try container.encode(runtime, forKey: .runtime)
            try container.encode(entry, forKey: .entry)
        case .http:
            try container.encode(execution, forKey: .execution)
        }
    }

    public func validate() throws {
        guard Set(permissions.keychainSecrets).count == permissions.keychainSecrets.count,
              Set(permissions.localSecrets).count == permissions.localSecrets.count else {
            throw OpenFinderError.invalidPluginManifest("Secret permission keys must be unique")
        }
        guard Set(permissions.keychainSecrets).isDisjoint(with: permissions.localSecrets) else {
            throw OpenFinderError.invalidPluginManifest("Secret permission storage must be unambiguous")
        }
        switch (schemaVersion, execution) {
        case (1, .process):
            return
        case (1, .http):
            throw OpenFinderError.invalidPluginManifest("Schema version 1 requires top-level runtime and entry")
        case (2, .process):
            throw OpenFinderError.invalidPluginManifest("Schema version 2 requires HTTP execution")
        case (2, .http(let protocolVersion, let endpointConfigurationKey, let tokenSecretKey)):
            guard protocolVersion == 1 else {
                throw OpenFinderError.invalidPluginManifest("Unsupported HTTP protocol version \(protocolVersion)")
            }
            guard !endpointConfigurationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenFinderError.invalidPluginManifest("HTTP endpoint configuration key must not be empty")
            }
            guard !tokenSecretKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OpenFinderError.invalidPluginManifest("HTTP token secret key must not be empty")
            }
            guard configuration.contains(where: { $0.key == endpointConfigurationKey }) else {
                throw OpenFinderError.invalidPluginManifest("Missing HTTP endpoint configuration field \(endpointConfigurationKey)")
            }
            guard permissions.storage(for: tokenSecretKey) != nil else {
                throw OpenFinderError.invalidPluginManifest("Missing HTTP token secret permission \(tokenSecretKey)")
            }
        default:
            throw OpenFinderError.invalidPluginManifest("Unsupported manifest schema version \(schemaVersion)")
        }
    }

    private static func decode(from decoder: Decoder) throws -> Self {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let execution: PluginExecution
        switch schemaVersion {
        case 1:
            guard !container.contains(.execution) else {
                throw OpenFinderError.invalidPluginManifest("Schema version 1 cannot mix runtime/entry with execution")
            }
            guard container.contains(.runtime), container.contains(.entry) else {
                throw OpenFinderError.invalidPluginManifest("Schema version 1 requires top-level runtime and entry")
            }
            execution = .process(
                runtime: try container.decode(PluginRuntime.self, forKey: .runtime),
                entry: try container.decode(String.self, forKey: .entry)
            )
        case 2:
            guard !container.contains(.runtime), !container.contains(.entry) else {
                throw OpenFinderError.invalidPluginManifest("Schema version 2 cannot mix execution with runtime/entry")
            }
            guard container.contains(.execution) else {
                throw OpenFinderError.invalidPluginManifest("Schema version 2 requires HTTP execution")
            }
            execution = try container.decode(PluginExecution.self, forKey: .execution)
        default:
            throw OpenFinderError.invalidPluginManifest("Unsupported manifest schema version \(schemaVersion)")
        }

        let manifest = Self(
            schemaVersion: schemaVersion,
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            version: try container.decode(String.self, forKey: .version),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            author: try container.decodeIfPresent(String.self, forKey: .author),
            execution: execution,
            actions: try container.decode([PluginActionManifest].self, forKey: .actions),
            permissions: try container.decode(PluginPermissions.self, forKey: .permissions),
            configuration: try container.decode([PluginConfigField].self, forKey: .configuration)
        )
        try manifest.validate()
        return manifest
    }
}
