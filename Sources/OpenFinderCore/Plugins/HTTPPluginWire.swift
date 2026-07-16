import Foundation

enum HTTPPluginWire {
    static func health(_ data: Data) throws -> HTTPPluginHealth {
        try requireKeys(data, required: ["schemaVersion", "protocolVersion", "status"],
                        optional: ["pluginID", "pluginVersion", "runtime", "checks"])
        let value = try decode(HTTPPluginHealth.self, data)
        guard value.schemaVersion == 1, value.protocolVersion == 1,
              ["ready", "degraded", "unavailable"].contains(value.status)
        else { throw HTTPPluginError.invalidResponse("health schema or status") }
        if value.runtime != nil { try requireNestedKeys(data, key: "runtime", required: ["name", "version"]) }
        try requireObjectArrayKeys(data, key: "checks", required: ["id", "status", "message"], optional: ["remediation"])
        return value
    }

    static func capabilities(_ data: Data) throws -> HTTPPluginCapabilities {
        try requireKeys(data, required: ["schemaVersion", "protocolVersion", "pluginID", "pluginVersion",
                                         "actions", "features", "limits"])
        let value = try decode(HTTPPluginCapabilities.self, data)
        try requireNestedKeys(data, key: "features", required: ["sse", "polling", "cancellation", "fileArtifacts"])
        try requireNestedKeys(data, key: "limits", required: ["maxRequestBytes", "terminalRetentionSeconds",
                                                                "maxEventsPerJob", "maxQueuedJobs"])
        try requireObjectArrayKeys(data, key: "actions", required: ["id"])
        guard value.schemaVersion == 1, value.protocolVersion == 1,
              !value.pluginID.isEmpty, !value.pluginVersion.isEmpty,
              value.limits.maxRequestBytes > 0, value.limits.maxEventsPerJob > 0,
              value.limits.maxQueuedJobs > 0, value.limits.terminalRetentionSeconds > 0
        else { throw HTTPPluginError.invalidResponse("capabilities schema") }
        return value
    }

    static func snapshot(_ data: Data, taskID: UUID) throws -> HTTPPluginSnapshot {
        try requireKeys(data, required: ["schemaVersion", "taskID", "state", "createdAt", "updatedAt",
                                         "startedAt", "finishedAt", "lastEventID", "resultAvailable"],
                        optional: ["progress"])
        let value = try decode(HTTPPluginSnapshot.self, data)
        guard value.schemaVersion == 1, value.taskID == taskID, value.lastEventID >= 0 else {
            throw HTTPPluginError.invalidResponse("job snapshot identity")
        }
        guard value.resultAvailable == value.state.isTerminal else {
            throw HTTPPluginError.invalidResponse("job snapshot terminal availability")
        }
        if let progress = value.progress {
            let progressData = try nestedObjectData(data, key: "progress")
            _ = try HTTPPluginEvent.decode(progressData, sseEventID: progress.eventID,
                                           sseEventType: "progress", expectedTaskID: taskID)
            guard progress.eventID <= value.lastEventID else {
                throw HTTPPluginError.invalidResponse("job snapshot progress cursor")
            }
        }
        return value
    }

    static func result(_ data: Data, taskID: UUID) throws -> HTTPPluginEvent {
        struct Identity: Decodable { let eventID: Int; let type: String }
        let identity = try decode(Identity.self, data)
        guard identity.type == "result" else { throw HTTPPluginError.invalidResponse("terminal result type") }
        return try HTTPPluginEvent.decode(data, sseEventID: identity.eventID,
                                          sseEventType: identity.type, expectedTaskID: taskID)
    }

    static func serverError(_ data: Data, status: Int, token: String) -> HTTPPluginError {
        do {
            try requireKeys(data, required: ["schemaVersion", "code", "message", "retryable"])
            let value = try decode(HTTPPluginErrorEnvelope.self, data)
            guard value.schemaVersion == 1, !value.code.isEmpty else {
                return .invalidResponse("error envelope schema")
            }
            return .server(status: status, code: value.code,
                           message: HTTPPluginRedactor.message(value.message, token: token), retryable: value.retryable)
        } catch {
            return .invalidResponse("error envelope")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder.openFinder.decode(type, from: data) }
        catch { throw HTTPPluginError.invalidResponse("malformed JSON") }
    }

    private static func requireKeys(_ data: Data, required: Set<String>, optional: Set<String> = []) throws {
        let object: [String: Any]
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HTTPPluginError.invalidResponse("JSON object required")
            }
            object = value
        } catch let error as HTTPPluginError { throw error }
        catch { throw HTTPPluginError.invalidResponse("malformed JSON") }
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw HTTPPluginError.invalidResponse("unexpected JSON shape")
        }
    }

    private static func nestedObjectData(_ data: Data, key: String) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nested = object[key] as? [String: Any] else {
            throw HTTPPluginError.invalidResponse("missing nested object")
        }
        return try JSONSerialization.data(withJSONObject: nested)
    }

    private static func requireNestedKeys(
        _ data: Data, key: String, required: Set<String>, optional: Set<String> = []
    ) throws {
        try requireKeys(try nestedObjectData(data, key: key), required: required, optional: optional)
    }

    private static func requireObjectArrayKeys(
        _ data: Data, key: String, required: Set<String>, optional: Set<String> = []
    ) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let raw = object[key] else { return }
        guard let values = raw as? [[String: Any]] else {
            throw HTTPPluginError.invalidResponse("\(key) array required")
        }
        for value in values {
            try requireKeys(try JSONSerialization.data(withJSONObject: value), required: required, optional: optional)
        }
    }
}
