import Foundation
import XCTest
@testable import OpenFinderCore

final class LocalPluginCredentialStoreTests: XCTestCase {
    func testResolverRoutesLocalReferencesLocallyAndLegacyReferencesToKeychain() throws {
        let keychain = InMemoryKeychainStore()
        let local = LocalPluginCredentialStore(pluginSecrets: [
            "local.plugin": ["serverToken": "fixture-local-value"]
        ])
        let resolver = PluginCredentialResolver(keychainStore: keychain, localStore: local)
        let localReference = PluginCredentialReference.localConfiguration(
            pluginID: "local.plugin", key: "serverToken"
        )
        let legacyReference = PluginCredentialReference.keychain(
            pluginID: "legacy.plugin", key: "apiToken"
        )
        try keychain.setSecret("fixture-keychain-value", for: legacyReference)

        XCTAssertEqual(try resolver.secret(for: localReference), "fixture-local-value")
        XCTAssertEqual(try resolver.secret(for: legacyReference), "fixture-keychain-value")
        XCTAssertNil(try keychain.secret(for: localReference))
    }

    func testDottedPluginIDsAndSecretKeysRemainIsolated() throws {
        let keychain = InMemoryKeychainStore()
        let local = LocalPluginCredentialStore(pluginSecrets: [
            "a.b": ["c": "fixture-first-value"],
            "a": ["b.c": "fixture-second-value"]
        ])
        let resolver = PluginCredentialResolver(keychainStore: keychain, localStore: local)
        let firstReference = PluginCredentialReference.localConfiguration(
            pluginID: "a.b", key: "c"
        )
        let secondReference = PluginCredentialReference.localConfiguration(
            pluginID: "a", key: "b.c"
        )

        XCTAssertNotEqual(firstReference, secondReference)
        XCTAssertEqual(try resolver.secret(for: firstReference), "fixture-first-value")
        XCTAssertEqual(try resolver.secret(for: secondReference), "fixture-second-value")
    }
}
