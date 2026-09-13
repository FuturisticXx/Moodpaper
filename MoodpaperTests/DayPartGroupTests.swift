import XCTest
@testable import Moodpaper

final class DayPartGroupTests: XCTestCase {
    func testFourGroupsCoverEveryDetailedEnginePeriodOnce() {
        XCTAssertEqual(
            DayPartGroup.allCases.flatMap { $0.slots.map(\.slotID) },
            HorizonScheduleDefaults.orderedSlotIDs
        )
    }

    func testApprovedFourGroupMapping() {
        XCTAssertEqual(
            DayPartGroup.morning.slots,
            [.deepNight, .dawn, .sunrise, .morning]
        )
        XCTAssertEqual(DayPartGroup.day.slots, [.midday, .afternoon])
        XCTAssertEqual(DayPartGroup.evening.slots, [.goldenHour, .dusk])
        XCTAssertEqual(DayPartGroup.night.slots, [.evening])
        XCTAssertEqual(DayPartGroup.night.displayName, "Night")
        XCTAssertEqual(TimeSlot.evening.displayName, "Night")
    }
}
