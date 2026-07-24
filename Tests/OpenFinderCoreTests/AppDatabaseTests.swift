import CryptoKit
import Foundation
import GRDB
import XCTest
@testable import OpenFinderCore

final class AppDatabaseTests: XCTestCase {
    func testExistingJSONConfigStoreRoundTripsAtInjectedURL() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDatabaseBaseline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let store = JSONConfigStore(url: url)

        try await store.save(AppConfiguration(defaultShowHiddenFiles: false))

        let loaded = try await store.load()
        XCTAssertFalse(loaded.defaultShowHiddenFiles)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testOpensConfiguredDatabaseAndAppliesPragmas() throws {
        let url = makeDatabaseURL()
        defer { removeDatabase(at: url) }
        let appDatabase = try AppDatabase(url: url)

        try appDatabase.databasePool.write { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA foreign_keys"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "PRAGMA busy_timeout"), 5_000)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA journal_mode"), "wal")
            print("pragma_observable foreign_keys=1 busy_timeout=5000 journal_mode=wal")
        }
    }

    func testMigrationFailurePreservesDatabase() throws {
        let url = makeDatabaseURL()
        defer { removeDatabase(at: url) }
        var configuration = Configuration()
        configuration.journalMode = .wal
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE fixture (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
        }
        try pool.close()
        let before = try Data(contentsOf: url)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("failing") { _ in
            throw FixtureMigrationError.expected
        }

        XCTAssertThrowsError(try AppDatabase(url: url, migrator: migrator))
        let after = try Data(contentsOf: url)
        let beforeHash = sha256(before)
        let afterHash = sha256(after)
        print("migration_failure_fixture_sha256 before=\(beforeHash) after=\(afterHash)")
        XCTAssertEqual(afterHash, beforeHash)
    }

    private func makeDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AppDatabaseTests-\(UUID().uuidString).sqlite")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum FixtureMigrationError: Error {
    case expected
}
