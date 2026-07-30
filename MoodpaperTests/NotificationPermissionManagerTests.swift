import UserNotifications
import XCTest
@testable import Moodpaper

final class NotificationPermissionManagerTests: XCTestCase {
    func testRuntimePlanRequestsAuthorizationWhenEnabledButUndetermined() {
        XCTAssertEqual(
            NotificationPermissionManager.runtimePlan(
                enabledPreference: true,
                authorizationStatus: .notDetermined
            ),
            .requestAuthorization
        )
    }

    func testRuntimePlanDisablesWhenPreferenceIsOffOrPermissionIsDenied() {
        XCTAssertEqual(
            NotificationPermissionManager.runtimePlan(
                enabledPreference: false,
                authorizationStatus: .authorized
            ),
            .disabled
        )
        XCTAssertEqual(
            NotificationPermissionManager.runtimePlan(
                enabledPreference: true,
                authorizationStatus: .denied
            ),
            .disabled
        )
    }

    func testAuthorizedStatusesCountAsAvailableCapability() {
        XCTAssertTrue(NotificationPermissionManager.isAuthorized(.authorized))
        XCTAssertTrue(NotificationPermissionManager.isAuthorized(.provisional))
        XCTAssertFalse(NotificationPermissionManager.isAuthorized(.denied))
        XCTAssertFalse(NotificationPermissionManager.isAuthorized(.notDetermined))
    }
}
