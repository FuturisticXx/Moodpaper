import XCTest
@testable import Moodpaper

final class UserDefaultsMigrationTests: XCTestCase {
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "HorizonTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testSeedPerDisplayWallpaperIdentifiersUsesLegacyIdentifier() throws {
        defaults.set("/tmp/example.jpg", forKey: "currentWallpaperIdentifier")

        AppDelegate.UserDefaultsMigration.seedPerDisplayWallpaperIdentifiers(
            defaults: defaults,
            screenNames: ["Studio Display", "Projector"]
        )

        let data = try XCTUnwrap(defaults.data(forKey: "currentWallpaperIdentifiersByScreen"))
        let decoded = try JSONDecoder().decode([String: String].self, from: data)

        XCTAssertEqual(decoded["Studio Display"], "/tmp/example.jpg")
        XCTAssertEqual(decoded["Projector"], "/tmp/example.jpg")
    }

    func testSeedPerDisplayWallpaperIdentifiersDoesNotOverwriteExistingData() throws {
        let existing = ["Studio Display": "existing-value"]
        defaults.set(try JSONEncoder().encode(existing), forKey: "currentWallpaperIdentifiersByScreen")
        defaults.set("/tmp/example.jpg", forKey: "currentWallpaperIdentifier")

        AppDelegate.UserDefaultsMigration.seedPerDisplayWallpaperIdentifiers(
            defaults: defaults,
            screenNames: ["Studio Display", "Projector"]
        )

        let data = try XCTUnwrap(defaults.data(forKey: "currentWallpaperIdentifiersByScreen"))
        let decoded = try JSONDecoder().decode([String: String].self, from: data)

        XCTAssertEqual(decoded, existing)
    }

    func testSeedPerDisplayWallpaperIdentifiersFallsBackToLegacyWallpaperName() throws {
        defaults.set("morning-4", forKey: "currentWallpaperName")

        AppDelegate.UserDefaultsMigration.seedPerDisplayWallpaperIdentifiers(
            defaults: defaults,
            screenNames: ["Studio Display", "Projector"]
        )

        let data = try XCTUnwrap(defaults.data(forKey: "currentWallpaperIdentifiersByScreen"))
        let decoded = try JSONDecoder().decode([String: String].self, from: data)

        XCTAssertEqual(decoded["Studio Display"], "morning-4")
        XCTAssertEqual(decoded["Projector"], "morning-4")
    }
}
