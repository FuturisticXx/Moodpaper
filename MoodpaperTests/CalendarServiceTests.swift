import EventKit
import XCTest
@testable import Moodpaper

final class CalendarServiceTests: XCTestCase {
    func testRuntimePlanStopsAndClearsWhenCalendarAccessIsRevoked() {
        XCTAssertEqual(CalendarService.runtimePlan(authorizationStatus: .denied, shouldMonitor: true), .stopAndClear)
        XCTAssertEqual(CalendarService.runtimePlan(authorizationStatus: .restricted, shouldMonitor: true), .stopAndClear)
        XCTAssertEqual(CalendarService.runtimePlan(authorizationStatus: .notDetermined, shouldMonitor: true), .stopAndClear)
    }

    func testRuntimePlanStartsAndRefreshesWhenCalendarAccessIsAvailableAndFocusModeIsOn() {
        XCTAssertEqual(CalendarService.runtimePlan(authorizationStatus: .fullAccess, shouldMonitor: true), .startAndRefresh)
    }

    func testRuntimePlanStopsAndClearsWhenFocusModeIsOff() {
        XCTAssertEqual(CalendarService.runtimePlan(authorizationStatus: .fullAccess, shouldMonitor: false), .stopAndClear)
    }
}
