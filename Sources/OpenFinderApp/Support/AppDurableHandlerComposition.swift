import Foundation
import OpenFinderCore

enum AppDurableHandlerCompositionError: Error, Equatable, LocalizedError, Sendable {
    case duplicateTaskHandler(AppDurableHandlerComposition.TaskKey)
    case missingTaskHandler(AppDurableHandlerComposition.TaskKey)
    case unexpectedTaskHandler(AppDurableHandlerComposition.TaskKey)
    case missingDependency(
        AppDurableHandlerComposition.TaskKey,
        AppDurableHandlerComposition.Dependency
    )
    case unexpectedDependency(
        AppDurableHandlerComposition.TaskKey,
        AppDurableHandlerComposition.Dependency
    )
    case duplicateResultHandler(String)
    case missingResultHandler(String)
    case unexpectedResultHandler(String)
    case duplicateRenderer(String)
    case missingRenderer(String)
    case unexpectedRenderer(String)

    var errorDescription: String? {
        switch self {
        case .duplicateTaskHandler(let key):
            "Duplicate durable task handler \(key.description)."
        case .missingTaskHandler(let key):
            "Missing durable task handler \(key.description)."
        case .unexpectedTaskHandler(let key):
            "Unexpected durable task handler \(key.description)."
        case .missingDependency(let key, let dependency):
            "Durable task handler \(key.description) is missing dependency \(dependency.rawValue)."
        case .unexpectedDependency(let key, let dependency):
            "Durable task handler \(key.description) has unexpected dependency \(dependency.rawValue)."
        case .duplicateResultHandler(let schema):
            "Duplicate plugin result handler \(schema)."
        case .missingResultHandler(let schema):
            "Missing plugin result handler \(schema)."
        case .unexpectedResultHandler(let schema):
            "Unexpected plugin result handler \(schema)."
        case .duplicateRenderer(let schema):
            "Duplicate plugin renderer \(schema)."
        case .missingRenderer(let schema):
            "Missing plugin renderer \(schema)."
        case .unexpectedRenderer(let schema):
            "Unexpected plugin renderer \(schema)."
        }
    }
}

struct AppDurableHandlerComposition: Sendable {
    struct TaskKey: Hashable, Sendable, CustomStringConvertible {
        let handlerID: String
        let payloadVersion: Int

        var description: String { "\(handlerID)@\(payloadVersion)" }
    }

    enum Dependency: String, Hashable, Sendable {
        case pluginResolver
        case credentialResolver
        case pluginExecutionCoordinator
        case fileSourceRegistry
        case transferCoordinator
    }

    struct TaskRegistration: Sendable {
        let handler: TaskHandler
        let dependencies: Set<Dependency>

        init(handler: TaskHandler, dependencies: Set<Dependency>) {
            self.handler = handler
            self.dependencies = dependencies
        }

        var key: TaskKey {
            TaskKey(handlerID: handler.handlerID, payloadVersion: handler.payloadVersion)
        }
    }

    private static let approvedDependencies: [TaskKey: Set<Dependency>] = [
        .init(
            handlerID: DurableTaskHandlerID.pluginExecute.rawValue,
            payloadVersion: 1
        ): [.pluginResolver, .credentialResolver, .pluginExecutionCoordinator],
        .init(
            handlerID: DurableTaskHandlerID.transferCopy.rawValue,
            payloadVersion: 1
        ): [.fileSourceRegistry, .transferCoordinator],
        .init(
            handlerID: DurableTaskHandlerID.transferMove.rawValue,
            payloadVersion: 1
        ): [.fileSourceRegistry, .transferCoordinator],
    ]

    private static let approvedResultSchemas = Set([
        MediaAnalysisDocument.schemaIdentifier
    ])

    private let taskRegistrations: [TaskRegistration]
    let registeredTaskKeys: Set<TaskKey>
    let registeredResultSchemas: Set<String>
    let registeredRendererSchemas: Set<String>

    init(
        taskRegistrations: [TaskRegistration],
        resultHandlers: [PluginResultHandler],
        rendererEntries: [PluginRendererCatalog.Entry]
    ) throws {
        let taskGroups = Dictionary(grouping: taskRegistrations, by: \.key)
        if let duplicate = taskGroups.first(where: { $0.value.count != 1 })?.key {
            throw AppDurableHandlerCompositionError.duplicateTaskHandler(duplicate)
        }
        let taskKeys = Set(taskGroups.keys)
        if let missing = Set(Self.approvedDependencies.keys).subtracting(taskKeys).first {
            throw AppDurableHandlerCompositionError.missingTaskHandler(missing)
        }
        if let unexpected = taskKeys.subtracting(Self.approvedDependencies.keys).first {
            throw AppDurableHandlerCompositionError.unexpectedTaskHandler(unexpected)
        }
        for registration in taskRegistrations {
            let expected = Self.approvedDependencies[registration.key] ?? []
            if let missing = expected.subtracting(registration.dependencies).first {
                throw AppDurableHandlerCompositionError.missingDependency(
                    registration.key,
                    missing
                )
            }
            if let unexpected = registration.dependencies.subtracting(expected).first {
                throw AppDurableHandlerCompositionError.unexpectedDependency(
                    registration.key,
                    unexpected
                )
            }
        }

        let resultGroups = Dictionary(grouping: resultHandlers, by: \.schemaID)
        if let duplicate = resultGroups.first(where: { $0.value.count != 1 })?.key {
            throw AppDurableHandlerCompositionError.duplicateResultHandler(duplicate)
        }
        let resultSchemas = Set(resultGroups.keys)
        if let missing = Self.approvedResultSchemas.subtracting(resultSchemas).first {
            throw AppDurableHandlerCompositionError.missingResultHandler(missing)
        }
        if let unexpected = resultSchemas.subtracting(Self.approvedResultSchemas).first {
            throw AppDurableHandlerCompositionError.unexpectedResultHandler(unexpected)
        }

        let rendererGroups = Dictionary(grouping: rendererEntries, by: \.resultSchemaID)
        if let duplicate = rendererGroups.first(where: { $0.value.count != 1 })?.key {
            throw AppDurableHandlerCompositionError.duplicateRenderer(duplicate)
        }
        let rendererSchemas = Set(rendererGroups.keys)
        if let missing = Self.approvedResultSchemas.subtracting(rendererSchemas).first {
            throw AppDurableHandlerCompositionError.missingRenderer(missing)
        }
        if let unexpected = rendererSchemas.subtracting(Self.approvedResultSchemas).first {
            throw AppDurableHandlerCompositionError.unexpectedRenderer(unexpected)
        }

        self.taskRegistrations = taskRegistrations
        registeredTaskKeys = taskKeys
        registeredResultSchemas = resultSchemas
        registeredRendererSchemas = rendererSchemas
    }

    func makeTaskHandlerRegistry() async throws -> TaskHandlerRegistry {
        let registry = TaskHandlerRegistry()
        for registration in taskRegistrations {
            try await registry.register(registration.handler)
        }
        return registry
    }
}

enum AppDurableHandlerReadiness: Equatable, Sendable {
    case checking
    case ready
    case unavailable(String)
}
