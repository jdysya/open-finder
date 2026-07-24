import Foundation
import XCTest
@testable import OpenFinderCore

final class ConfigStoreTests: XCTestCase {
    func testDecodesConfigurationWrittenBeforePluginConfigurationFieldExisted() throws {
        let json = """
        {
          "confirmBeforePermanentDelete" : false,
          "defaultShowHiddenFiles" : true,
          "maxConcurrentTasks" : 4,
          "python3Path" : "/usr/bin/python3"
        }
        """

        let configuration = try JSONDecoder.openFinder.decode(AppConfiguration.self, from: Data(json.utf8))

        XCTAssertTrue(configuration.defaultShowHiddenFiles)
        XCTAssertFalse(configuration.confirmBeforePermanentDelete)
        XCTAssertEqual(configuration.maxConcurrentTasks, 4)
        XCTAssertEqual(configuration.python3Path, "/usr/bin/python3")
        XCTAssertEqual(configuration.pluginConfigurationValues, [:])
        XCTAssertEqual(configuration.localPluginSecrets, [:])
    }

    func testLocalPluginSecretsRoundTripAndClearOutsideGenericConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderLocalPluginSecrets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONConfigStore(url: root.appendingPathComponent("config.json"))
        var configuration = AppConfiguration(
            pluginConfigurationValues: ["fixture.plugin": ["serverURL": "http://127.0.0.1:8765"]],
            localPluginSecrets: ["fixture.plugin": ["serverToken": "fixture-local-value"]]
        )

        try await store.save(configuration)
        let loaded = try await store.load()

        XCTAssertEqual(loaded.localPluginSecrets["fixture.plugin"]?["serverToken"], "fixture-local-value")
        XCTAssertNil(loaded.pluginConfigurationValues["fixture.plugin"]?["serverToken"])

        configuration.localPluginSecrets["fixture.plugin"] = nil
        try await store.save(configuration)
        let cleared = try await store.load()
        XCTAssertEqual(cleared.localPluginSecrets, [:])
    }

    func testConfigFileIsMode0600OnCreateAndAtomicOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenFinderConfigMode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.json")
        let store = JSONConfigStore(url: url)

        try await store.save(AppConfiguration(defaultShowHiddenFiles: false))
        XCTAssertEqual(try permissions(of: url), 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try await store.save(AppConfiguration(defaultShowHiddenFiles: true))

        XCTAssertEqual(try permissions(of: url), 0o600)
        let overwritten = try await store.load()
        XCTAssertTrue(overwritten.defaultShowHiddenFiles)
        let siblingNames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(siblingNames, ["config.json"])
    }

    private func permissions(of url: URL) throws -> Int {
        let value = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        return value.intValue & 0o777
    }
}
