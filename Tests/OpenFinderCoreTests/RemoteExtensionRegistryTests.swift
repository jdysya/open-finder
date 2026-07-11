import Foundation
import XCTest
@testable import OpenFinderCore

final class RemoteExtensionRegistryTests: XCTestCase {
    func testWebDAVConnectorPreservesWebDAVEndpoint() throws {
        let connector = try XCTUnwrap(RemoteConnectorRegistry.builtIn.connector(id: .webDAV))

        XCTAssertEqual(connector.providerKind, .webDAV)
        XCTAssertEqual(connector.defaultEndpoint, "https://example.com/dav/")

        let account = try connector.makeAccount(
            name: "Files",
            endpoint: "https://files.example.test/dav/",
            username: "admin",
            secretKeychainRef: "remote.webdav.password",
            allowInsecureHTTP: false
        )

        XCTAssertEqual(account.provider, .webDAV)
        XCTAssertEqual(account.baseURL?.absoluteString, "https://files.example.test/dav/")
    }

    func testKodboxConnectorBuildsNativeProviderConfiguration() throws {
        let registry = RemoteConnectorRegistry.builtIn
        let connector = try XCTUnwrap(registry.connector(id: .kodbox))

        XCTAssertEqual(connector.id, .kodbox)
        XCTAssertEqual(connector.displayName, "Kodbox")
        XCTAssertEqual(connector.providerKind, .kodbox)
        XCTAssertEqual(connector.defaultEndpoint, "https://example.com/")
        XCTAssertFalse(connector.requiresWebDAVEndpoint)

        let accountID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let account = try connector.makeAccount(
            id: accountID,
            name: "Team Kodbox",
            endpoint: "https://box.example.test/",
            username: "admin",
            secretKeychainRef: "remote.kodbox.password",
            allowInsecureHTTP: false
        )

        XCTAssertEqual(account.id, accountID)
        XCTAssertEqual(account.name, "Team Kodbox")
        XCTAssertEqual(account.provider, .kodbox)
        XCTAssertEqual(account.baseURL?.absoluteString, "https://box.example.test/")
        XCTAssertEqual(account.username, "admin")
        XCTAssertEqual(account.secretKeychainRef, "remote.kodbox.password")
        XCTAssertEqual(account.options["connectorID"], "kodbox")
        XCTAssertNil(account.options["allowInsecureHTTP"])
    }

    func testKodboxConnectorRejectsLegacyWebDAVEndpoint() {
        let connector = RemoteConnectorRegistry.builtIn.connector(id: .kodbox)!

        XCTAssertThrowsError(try connector.makeAccount(
            name: "Broken",
            endpoint: "https://box.example.test/index.php/dav/",
            username: "admin",
            secretKeychainRef: "remote.kodbox.password",
            allowInsecureHTTP: false
        )) { error in
            guard case OpenFinderError.operationFailed(let message) = error else {
                return XCTFail("Expected operationFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("server root"))
            XCTAssertTrue(message.contains("index.php/dav"))
        }
    }

    func testKodboxConnectorAllowsLoopbackHTTPOnlyWithExplicitOptIn() throws {
        let connector = RemoteConnectorRegistry.builtIn.connector(id: .kodbox)!

        XCTAssertThrowsError(try connector.makeAccount(
            name: "Local",
            endpoint: "http://127.0.0.1:8080/",
            username: "admin",
            secretKeychainRef: "remote.kodbox.password",
            allowInsecureHTTP: false
        ))

        let localAccount = try connector.makeAccount(
            name: "Local",
            endpoint: "http://127.0.0.1:8080/",
            username: "admin",
            secretKeychainRef: "remote.kodbox.password",
            allowInsecureHTTP: true
        )
        XCTAssertEqual(localAccount.baseURL?.absoluteString, "http://127.0.0.1:8080/")
        XCTAssertEqual(localAccount.options["allowInsecureHTTP"], "true")

        XCTAssertThrowsError(try connector.makeAccount(
            name: "Public HTTP",
            endpoint: "http://box.example.test/",
            username: "admin",
            secretKeychainRef: "remote.kodbox.password",
            allowInsecureHTTP: true
        ))
    }

    func testWebDAVConnectorUsesHostFallbackWhenNameIsBlank() throws {
        let connector = try XCTUnwrap(RemoteConnectorRegistry.builtIn.connector(id: .webDAV))

        let account = try connector.makeAccount(
            name: " ",
            endpoint: "https://files.example.test/dav/",
            username: "",
            secretKeychainRef: nil,
            allowInsecureHTTP: false
        )

        XCTAssertEqual(account.name, "files.example.test")
    }
}
