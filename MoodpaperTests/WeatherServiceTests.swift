import XCTest
@testable import Moodpaper

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
}
