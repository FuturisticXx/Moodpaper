import XCTest
@testable import Moodpaper

@MainActor
final class WeatherServiceTests: XCTestCase {
    func testWeatherAttributionUsesOpenMeteoWhenFallbackIsActive() {
        XCTAssertEqual(
            HorizonWeatherService.attributionLabel(for: "open-meteo"),
            "Weather by Open-Meteo"
        )
        XCTAssertEqual(
            HorizonWeatherService.attributionURL(for: "open-meteo").absoluteString,
            "https://open-meteo.com/"
        )
    }

    func testWeatherAttributionDefaultsToAppleWeatherAttribution() {
        XCTAssertEqual(
            HorizonWeatherService.attributionLabel(for: "weatherkit"),
            "Weather"
        )
        XCTAssertEqual(
            HorizonWeatherService.attributionURL(for: "weatherkit").absoluteString,
            "https://weather-data.apple.com/legal-attribution.html"
        )
        XCTAssertEqual(
            HorizonWeatherService.attributionURL(for: "none").absoluteString,
            "https://weather-data.apple.com/legal-attribution.html"
        )
    }

    func testLatestAttemptControlsRefreshInterval() {
        XCTAssertEqual(
            HorizonWeatherService.nextRefreshInterval(latestAttemptSucceeded: true),
            30 * 60
        )
        XCTAssertEqual(
            HorizonWeatherService.nextRefreshInterval(latestAttemptSucceeded: false),
            5 * 60
        )
    }

    func testCachedWeatherIsOnlyFreshWithinMaximumAge() {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = WeatherCacheSnapshot(
            weather: HorizonWeather(
                temperature: 21,
                condition: .partlyCloudy,
                isDaylight: true,
                windSpeed: 12,
                humidity: 0.55
            ),
            source: "open-meteo",
            fetchedAt: now.addingTimeInterval(-60 * 60)
        )

        XCTAssertTrue(snapshot.isFresh(at: now, maximumAge: 2 * 60 * 60))
        XCTAssertFalse(snapshot.isFresh(at: now, maximumAge: 30 * 60))
    }

    func testOpenMeteoRejectsNonSuccessHTTPResponse() throws {
        let url = try XCTUnwrap(URL(string: "https://api.open-meteo.com/v1/forecast"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )
        )

        XCTAssertThrowsError(
            try HorizonWeatherService.validateOpenMeteoResponse(Data(), response: response)
        )
    }
}
