import CoreLocation
import XCTest
@testable import Moodpaper

final class LocationServiceTests: XCTestCase {
    func testRuntimePlanDisablesLocationUsageWhenPreferenceIsOff() {
        XCTAssertEqual(
            LocationService.runtimePlan(
                useDeviceLocation: false,
                authorizationStatus: .authorizedAlways,
                hasLocationAuthorization: true
            ),
            .disableUsage
        )
    }

    func testRuntimePlanRequestsLocationWhenAuthorized() {
        XCTAssertEqual(
            LocationService.runtimePlan(
                useDeviceLocation: true,
                authorizationStatus: .authorizedAlways,
                hasLocationAuthorization: true
            ),
            .requestSingleLocation
        )
    }

    func testRuntimePlanRestoresCachedFallbackWhenPermissionIsUndetermined() {
        XCTAssertEqual(
            LocationService.runtimePlan(
                useDeviceLocation: true,
                authorizationStatus: .notDetermined,
                hasLocationAuthorization: false
            ),
            .restoreCachedAndFallback
        )
    }

    func testRuntimePlanClearsLiveStateWhenPermissionIsUnavailable() {
        XCTAssertEqual(
            LocationService.runtimePlan(
                useDeviceLocation: true,
                authorizationStatus: .denied,
                hasLocationAuthorization: false
            ),
            .clearAndFallback
        )
    }
}
