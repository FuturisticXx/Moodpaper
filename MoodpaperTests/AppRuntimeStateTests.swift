import CoreLocation
import EventKit
import UserNotifications
import XCTest
@testable import Moodpaper

final class AppRuntimeStateTests: XCTestCase {
    func testDeniedPermissionsKeepPermissionGatedCapabilitiesUnavailable() {
        let capabilities = AppRuntimeState.computeCapabilities(
            locationAuthorizationStatus: .denied,
            calendarAuthorizationStatus: .denied,
            notificationAuthorizationStatus: .denied,
            shortcutsAuthorized: false,
            notificationsEnabledPreference: true,
            shortcutsEnabledPreference: true
        )

        XCTAssertFalse(capabilities.locationAuthorized)
        XCTAssertFalse(capabilities.calendarAuthorized)
        XCTAssertFalse(capabilities.notificationsAuthorized)
        XCTAssertTrue(capabilities.shortcutsEnabledPreference)
        XCTAssertTrue(capabilities.notificationsEnabledPreference)
        XCTAssertFalse(capabilities.slotChangeNotificationsAvailable)
        XCTAssertFalse(capabilities.focusModeAvailable)
        XCTAssertTrue(capabilities.independentDisplaysAvailable)
        XCTAssertTrue(capabilities.slotSourceCustomizationAvailable)
    }

    func testCapabilitiesRequireCalendarAccessForFocusMode() {
        let deniedCalendar = AppRuntimeState.computeCapabilities(
            locationAuthorizationStatus: .authorizedAlways,
            calendarAuthorizationStatus: .denied,
            notificationAuthorizationStatus: .authorized,
            shortcutsAuthorized: true,
            notificationsEnabledPreference: true,
            shortcutsEnabledPreference: true
        )
        XCTAssertFalse(deniedCalendar.focusModeAvailable)
        XCTAssertTrue(deniedCalendar.independentDisplaysAvailable)
        XCTAssertTrue(deniedCalendar.slotSourceCustomizationAvailable)
        XCTAssertTrue(deniedCalendar.slotChangeNotificationsAvailable)

        let fullCalendar = AppRuntimeState.computeCapabilities(
            locationAuthorizationStatus: .authorizedAlways,
            calendarAuthorizationStatus: .fullAccess,
            notificationAuthorizationStatus: .authorized,
            shortcutsAuthorized: true,
            notificationsEnabledPreference: true,
            shortcutsEnabledPreference: true
        )
        XCTAssertTrue(fullCalendar.focusModeAvailable)
    }

    func testNotificationCapabilityRequiresPermissionAndPreference() {
        let deniedNotifications = AppRuntimeState.computeCapabilities(
            locationAuthorizationStatus: .denied,
            calendarAuthorizationStatus: .denied,
            notificationAuthorizationStatus: .denied,
            shortcutsAuthorized: false,
            notificationsEnabledPreference: true,
            shortcutsEnabledPreference: false
        )
        XCTAssertFalse(deniedNotifications.slotChangeNotificationsAvailable)

        let enabledNotifications = AppRuntimeState.computeCapabilities(
            locationAuthorizationStatus: .denied,
            calendarAuthorizationStatus: .denied,
            notificationAuthorizationStatus: .authorized,
            shortcutsAuthorized: false,
            notificationsEnabledPreference: true,
            shortcutsEnabledPreference: false
        )
        XCTAssertTrue(enabledNotifications.slotChangeNotificationsAvailable)
    }
}
