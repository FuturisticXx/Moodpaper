import CoreLocation
import EventKit
import XCTest
@testable import Moodpaper

final class RuntimeTransitionScenarioTests: XCTestCase {
    func testDuplicateHorizonInstanceDetectionIgnoresCurrentProcess() {
        let duplicates = AppDelegate.duplicateHorizonProcessIDs(
            snapshots: [
                .init(processIdentifier: 101, bundleIdentifier: "com.2DaMax.Moodpaper"),
                .init(processIdentifier: 202, bundleIdentifier: "com.2DaMax.Moodpaper"),
                .init(processIdentifier: 303, bundleIdentifier: "com.example.Other")
            ],
            currentProcessID: 202,
            currentBundleIdentifier: "com.2DaMax.Moodpaper"
        )

        XCTAssertEqual(duplicates, [101])
    }

    func testDuplicateHorizonInstanceTerminationIsDisabledDuringXCTest() {
        XCTAssertFalse(
            AppDelegate.shouldTerminateDuplicateInstances(
                environment: ["XCTestConfigurationFilePath": "/tmp/HorizonTests.xctestconfiguration"]
            )
        )
        XCTAssertTrue(AppDelegate.shouldTerminateDuplicateInstances(environment: [:]))
    }
}
