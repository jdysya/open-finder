import Foundation
import GRDB

public enum AppDatabaseError: Error, Equatable {
    case destructiveMigrationPolicy
}

public final class AppDatabase {
    public let databasePool: DatabasePool

    public convenience init(
        url: URL,
        migrator: DatabaseMigrator = DatabaseMigrator(),
        busyTimeout: TimeInterval = 5
    ) throws {
        guard !migrator.eraseDatabaseOnSchemaChange else {
            throw AppDatabaseError.destructiveMigrationPolicy
        }

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
        migrator: DatabaseMigrator = DatabaseMigrator()
    ) throws {
        guard !migrator.eraseDatabaseOnSchemaChange else {
            throw AppDatabaseError.destructiveMigrationPolicy
        }

        self.databasePool = databasePool
        try migrator.migrate(databasePool)
    }

    private init(databasePool: DatabasePool) {
        self.databasePool = databasePool
    }
}
