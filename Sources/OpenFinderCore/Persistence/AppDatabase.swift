import Foundation
import GRDB

public enum AppDatabaseError: Error, Equatable {
    case destructiveMigrationPolicy
    case futureSchema
    case databaseValidationFailed
}

public final class AppDatabase {
    public static let currentSchemaVersion = 3
    public let databasePool: DatabasePool

    public convenience init(
        url: URL,
        migrator: DatabaseMigrator = AppDatabase.applicationMigrator(),
        busyTimeout: TimeInterval = 5
    ) throws {
        guard !migrator.eraseDatabaseOnSchemaChange else {
            throw AppDatabaseError.destructiveMigrationPolicy
        }

        try Self.validateExistingDatabase(at: url, migrator: migrator, busyTimeout: busyTimeout)

        var migrationConfiguration = Configuration()
        migrationConfiguration.foreignKeysEnabled = true
        migrationConfiguration.busyMode = .timeout(busyTimeout)
        let migrationQueue = try DatabaseQueue(path: url.path, configuration: migrationConfiguration)
        try migrator.migrate(migrationQueue)
        try migrationQueue.close()

        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.foreignKeysEnabled = true
        configuration.busyMode = .timeout(busyTimeout)

        let databasePool = try DatabasePool(path: url.path, configuration: configuration)
        self.init(databasePool: databasePool)
    }

    public init(
        databasePool: DatabasePool,
        migrator: DatabaseMigrator = AppDatabase.applicationMigrator()
    ) throws {
        guard !migrator.eraseDatabaseOnSchemaChange else {
            throw AppDatabaseError.destructiveMigrationPolicy
        }

        self.databasePool = databasePool
        try databasePool.read { db in
            try Self.validateSchema(db, migrator: migrator)
        }
        try migrator.migrate(databasePool)
    }

    public static func applicationMigrator(
        upToSchemaVersion: Int = AppDatabase.currentSchemaVersion
    ) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        if upToSchemaVersion >= 1 {
            migrator.registerMigration("openfinder.001.task-storage") { db in
                try db.execute(sql: Self.taskStorageMigration)
            }
        }
        if upToSchemaVersion >= 2 {
            migrator.registerMigration("openfinder.002.artifact-media-storage") { db in
                try db.execute(sql: Self.artifactMediaStorageMigration)
            }
        }
        if upToSchemaVersion >= 3 {
            migrator.registerMigration("openfinder.003.task-lineage-foreign-keys") { db in
                try db.execute(sql: Self.taskLineageForeignKeysMigration)
            }
        }
        return migrator
    }

    private init(databasePool: DatabasePool) {
        self.databasePool = databasePool
    }

    private static func validateExistingDatabase(
        at url: URL,
        migrator: DatabaseMigrator,
        busyTimeout: TimeInterval
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else { return }

        do {
            var configuration = Configuration()
            configuration.readonly = true
            configuration.foreignKeysEnabled = true
            configuration.busyMode = .timeout(busyTimeout)
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            defer { try? queue.close() }
            try queue.read { db in
                guard try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" else {
                    throw AppDatabaseError.databaseValidationFailed
                }
                try validateSchema(db, migrator: migrator)
            }
        } catch let error as AppDatabaseError {
            throw error
        } catch {
            throw AppDatabaseError.databaseValidationFailed
        }
    }

    private static func validateSchema(_ db: Database, migrator: DatabaseMigrator) throws {
        if try migrator.hasBeenSuperseded(db) {
            throw AppDatabaseError.futureSchema
        }
        guard try db.tableExists("app_schema_metadata") else { return }
        guard let version = try Int.fetchOne(
            db,
            sql: "SELECT schema_version FROM app_schema_metadata WHERE singleton = 1"
        ), version >= 1 else {
            throw AppDatabaseError.databaseValidationFailed
        }
        guard version <= currentSchemaVersion else {
            throw AppDatabaseError.futureSchema
        }
    }
}
