import XCTest
@testable import Moodpaper

final class HorizonScheduleDefaultsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "HorizonScheduleDefaultsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    func testEveningStartMatchesSelectedNightStartMode() {
        XCTAssertEqual(
            HorizonScheduleDefaults.eveningStartMinutes(
                duskStart: 18 * 60,
                nightStart: .atSunset
            ),
            18 * 60
        )
        XCTAssertEqual(
            HorizonScheduleDefaults.eveningStartMinutes(
                duskStart: 18 * 60,
                nightStart: .oneHourAfter
            ),
            19 * 60
        )
        XCTAssertEqual(
            HorizonScheduleDefaults.eveningStartMinutes(
                duskStart: 18 * 60,
                nightStart: .twoHoursAfter
            ),
            20 * 60
        )
    }

    func testEveningStartClampsToDuskFloor() {
        XCTAssertEqual(
            HorizonScheduleDefaults.eveningStartMinutes(
                duskStart: 23 * 60,
                nightStart: .tenPM
            ),
            23 * 60
        )
    }

    func testEveningStartClampsToLatestAllowedCeiling() {
        XCTAssertEqual(
            HorizonScheduleDefaults.eveningStartMinutes(
                duskStart: 23 * 60 + 20,
                nightStart: .twoHoursAfter
            ),
            23 * 60 + 30
        )
    }

    func testEveningStartHandlesPolarMidnightSun() {
        // duskStart at midnight (1440) - polar summer; result must not invert below dusk
        let result = HorizonScheduleDefaults.eveningStartMinutes(
            duskStart: 24 * 60,
            nightStart: .oneHourAfter
        )
        XCTAssertEqual(result, 23 * 60 + 30)
    }

    func testEveningStartHandlesDuskExactlyAtCeiling() {
        let result = HorizonScheduleDefaults.eveningStartMinutes(
            duskStart: 23 * 60 + 30,
            nightStart: .atSunset
        )
        XCTAssertEqual(result, 23 * 60 + 30)
    }

    func testValidatedFocusSlotNormalizesDetailedSlotForSimpleMode() {
        XCTAssertEqual(
            HorizonScheduleDefaults.validatedFocusSlot(
                preferred: "deep-night",
                mode: "Simple",
                defaults: defaults
            ),
            "morning"
        )
    }

    func testValidatedFocusSlotFallsBackWhenPreferredSlotIsDisabled() throws {
        let enabled = [
            "morning": false,
            "afternoon": true,
            "evening": true,
        ]
        defaults.set(try JSONEncoder().encode(enabled), forKey: HorizonScheduleDefaults.slotEnabledKey)

        XCTAssertEqual(
            HorizonScheduleDefaults.validatedFocusSlot(
                preferred: "morning",
                mode: "Simple",
                defaults: defaults
            ),
            "afternoon"
        )
    }

    func testEnabledFocusSlotsRespectScheduleMode() throws {
        let enabled = [
            "deep-night": true,
            "morning": false,
            "afternoon": true,
            "evening": false,
        ]
        defaults.set(try JSONEncoder().encode(enabled), forKey: HorizonScheduleDefaults.slotEnabledKey)

        XCTAssertEqual(
            HorizonScheduleDefaults.enabledSlotIDs(mode: "Simple", defaults: defaults),
            ["afternoon"]
        )
    }
}
