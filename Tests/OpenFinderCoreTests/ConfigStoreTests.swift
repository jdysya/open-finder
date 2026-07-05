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
    }
}
