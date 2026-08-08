import XCTest
@testable import Moodpaper

final class OnboardingDayDialTests: XCTestCase {
    private let slotCount = HorizonScheduleDefaults.orderedSlotIDs.count

    func testSlotIndexCoversFullRange() {
        XCTAssertEqual(OnboardingDayDial.slotIndex(for: 0, slotCount: slotCount), 0)
        XCTAssertEqual(
            OnboardingDayDial.slotIndex(for: 1, slotCount: slotCount),
            slotCount - 1,
            "Position 1.0 belongs to the last slot, not one past the end"
        )
    }

    func testSlotIndexClampsOutOfRangePositions() {
        XCTAssertEqual(OnboardingDayDial.slotIndex(for: -0.5, slotCount: slotCount), 0)
        XCTAssertEqual(OnboardingDayDial.slotIndex(for: 1.5, slotCount: slotCount), slotCount - 1)
        XCTAssertEqual(OnboardingDayDial.slotIndex(for: 0.5, slotCount: 0), 0)
    }

    func testEverySlotIsReachableAndRoundTrips() {
        for index in 0..<slotCount {
            let position = OnboardingDayDial.position(forSlotIndex: index, slotCount: slotCount)
            XCTAssertEqual(
                OnboardingDayDial.slotIndex(for: position, slotCount: slotCount),
                index,
                "Band center for slot \(index) must map back to slot \(index)"
            )
        }
    }

    func testThumbSymbolAndDisplayNameCoverAllEngineSlots() {
        for slotID in HorizonScheduleDefaults.orderedSlotIDs {
            XCTAssertFalse(OnboardingDayDial.thumbSymbol(forSlotID: slotID).isEmpty)
            XCTAssertNotEqual(
                OnboardingDayDial.displayName(forSlotID: slotID),
                slotID,
                "Slot \(slotID) should resolve to a user-facing display name, not its raw ID"
            )
        }
    }
}
