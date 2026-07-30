import Foundation
import WeatherKit
import CoreLocation
internal import Combine

// MARK: - Horizon Weather Condition
// Local abstraction over WeatherKit's WeatherCondition.
// Keeps the rest of the app decoupled from a direct WeatherKit dependency.

enum HorizonCondition: String, CaseIterable {
    case clear, mostlyClear, partlyCloudy, mostlyCloudy, cloudy
    case foggy, haze, smoky
    case drizzle, rain, heavyRain, freezingDrizzle, freezingRain, sunShowers
    case snow, sleet, blowingSnow, blizzard, flurries, sunFlurries, wintryMix
    case thunderstorms, isolatedThunderstorms, scatteredThunderstorms, strongStorms, tropicalStorm, hurricane
    case windy, breezy, hot, frigid, blowingDust
}

// MARK: - Horizon Weather Model

struct HorizonWeather: Equatable {
    let temperature: Double          // Celsius
    let condition: HorizonCondition
    let isDaylight: Bool
    let windSpeed: Double?           // km/h
    let humidity: Double?            // 0-1

    var temperatureFahrenheit: Double {
        temperature * 9 / 5 + 32
    }
}

// MARK: - WeatherKit Service

@MainActor
class HorizonWeatherService: ObservableObject {
    static let shared = HorizonWeatherService()

    @Published var currentWeather: HorizonWeather?
    @Published var isLoading = false
    @Published var error: Error?

    private let locationService = LocationService.shared
    private let weatherService = WeatherService.shared   // WeatherKit
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private var isFetching = false

    deinit {
        cancellables.removeAll()
        refreshTimer?.invalidate()
    }

    private static let refreshInterval: TimeInterval = 30 * 60  // 30 minutes
    private static let retryInterval:   TimeInterval =  5 * 60  // 5 minutes on failure
    private static let weatherKitTimeout: TimeInterval = 6
    private static let openMeteoTimeout: TimeInterval = 8

    private init() {
        // Fetch whenever location becomes available or changes significantly.
        // Using debounce so a burst of location updates collapses into one fetch.
        locationService.$currentLocation
            .compactMap { $0 }
            .removeDuplicates { a, b in a.distance(from: b) < 5_000 }  // skip if < 5 km change
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.fetchWeather()
                }
            }
            .store(in: &cancellables)

    }

    private func scheduleRefresh(after interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchWeather()
            }
        }
    }

    @Published var source: String = "none"   // "weatherkit" or "open-meteo"

    var attributionLabel: String {
        Self.attributionLabel(for: source)
    }

    var attributionURL: URL {
        Self.attributionURL(for: source)
    }

    func clearWeather(reason: String? = nil) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        currentWeather = nil
        error = nil
        isLoading = false
        source = "none"
        if let reason {
            print("[WeatherService] Cleared weather state: \(reason)")
        }
    }

    // MARK: - Fetch

    func fetchWeather() async {
        guard !isFetching else {
            print("[WeatherService] Fetch already in progress, skipping duplicate request")
            return
        }

        guard let location = locationService.currentLocation else {
            print("[WeatherService] No location available, skipping fetch")
            isLoading = false
            return
        }

        isLoading = true
        error = nil
        isFetching = true
        defer {
            isLoading = false
            isFetching = false
        }

        // Try WeatherKit first
        do {
            let weather = try await withTimeout(seconds: Self.weatherKitTimeout) {
                try await self.weatherService.weather(for: location)
            }
            let current = weather.currentWeather

            let newCondition = mapCondition(current.condition)
            currentWeather = HorizonWeather(
                temperature: current.temperature.converted(to: .celsius).value,
                condition: newCondition,
                isDaylight: current.isDaylight,
                windSpeed: current.wind.speed.converted(to: .kilometersPerHour).value,
                humidity: current.humidity
            )

            source = "weatherkit"

            if let temp = currentWeather?.temperatureFahrenheit {
                print("[WeatherService] WeatherKit fetched: \(current.condition), \(Int(temp))°F")
            } else {
                print("[WeatherService] WeatherKit fetched: \(current.condition)")
            }
            scheduleRefresh(after: Self.refreshInterval)
            return
        } catch {
            print("[WeatherService] WeatherKit failed: \(error). Falling back to Open-Meteo.")
        }

        // Fallback: Open-Meteo (free, no API key)
        await fetchFromOpenMeteo(location: location)
        // Schedule next refresh: shorter interval on failure so we recover quickly
        scheduleRefresh(after: currentWeather != nil ? Self.refreshInterval : Self.retryInterval)
    }

    // MARK: - Open-Meteo Fallback

    private func fetchFromOpenMeteo(location: CLLocation) async {
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(lat)&longitude=\(lon)&current=temperature_2m,relative_humidity_2m,wind_speed_10m,weather_code,is_day"

        guard let url = URL(string: urlString) else {
            self.error = NSError(domain: "HorizonWeather", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Open-Meteo URL"])
            return
        }

        do {
            let (data, _) = try await withTimeout(seconds: Self.openMeteoTimeout) {
                try await URLSession.shared.data(from: url)
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any],
                  let tempC = current["temperature_2m"] as? Double,
                  let weatherCode = current["weather_code"] as? Int,
                  let isDay = current["is_day"] as? Int else {
                self.error = NSError(domain: "HorizonWeather", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse Open-Meteo response"])
                print("[WeatherService] Open-Meteo parse error")
                return
            }

            let windSpeed = current["wind_speed_10m"] as? Double
            let humidity = (current["relative_humidity_2m"] as? Double).map { $0 / 100.0 }

            let newCondition = mapOpenMeteoCode(weatherCode)
            currentWeather = HorizonWeather(
                temperature: tempC,
                condition: newCondition,
                isDaylight: isDay == 1,
                windSpeed: windSpeed,
                humidity: humidity
            )

            source = "open-meteo"
            self.error = nil

            if let temp = currentWeather?.temperatureFahrenheit {
                print("[WeatherService] Open-Meteo fetched: code=\(weatherCode), \(Int(temp))°F")
            } else {
                print("[WeatherService] Open-Meteo fetched: code=\(weatherCode)")
            }
        } catch {
            self.error = error
            print("[WeatherService] Open-Meteo fetch error: \(error)")
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw URLError(.timedOut)
            }

            guard let result = try await group.next() else {
                throw URLError(.unknown)
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Open-Meteo WMO weather code → local enum

    private func mapOpenMeteoCode(_ code: Int) -> HorizonCondition {
        switch code {
        case 0:             return .clear
        case 1:             return .mostlyClear
        case 2:             return .partlyCloudy
        case 3:             return .cloudy
        case 45, 48:        return .foggy
        case 51, 53:        return .drizzle
        case 55:            return .drizzle
        case 56, 57:        return .freezingDrizzle
        case 61:            return .rain
        case 63:            return .rain
        case 65:            return .heavyRain
        case 66:            return .freezingRain
        case 67:            return .freezingRain
        case 71, 73:        return .snow
        case 75:            return .blizzard
        case 77:            return .sleet
        case 80, 81:        return .sunShowers
        case 82:            return .heavyRain
        case 85:            return .flurries
        case 86:            return .blowingSnow
        case 95:            return .thunderstorms
        case 96, 99:        return .strongStorms
        default:            return .partlyCloudy
        }
    }

    // MARK: - WeatherKit condition → local enum

    private func mapCondition(_ wk: WeatherKit.WeatherCondition) -> HorizonCondition {
        switch wk {
        case .clear:                       return .clear
        case .mostlyClear:                 return .mostlyClear
        case .partlyCloudy:                return .partlyCloudy
        case .mostlyCloudy:                return .mostlyCloudy
        case .cloudy:                      return .cloudy
        case .foggy:                       return .foggy
        case .haze:                        return .haze
        case .smoky:                       return .smoky
        case .drizzle:                     return .drizzle
        case .rain:                        return .rain
        case .heavyRain:                   return .heavyRain
        case .freezingDrizzle:             return .freezingDrizzle
        case .freezingRain:                return .freezingRain
        case .sunShowers:                  return .sunShowers
        case .snow:                        return .snow
        case .sleet:                       return .sleet
        case .blowingSnow:                 return .blowingSnow
        case .blizzard:                    return .blizzard
        case .flurries:                    return .flurries
        case .sunFlurries:                 return .sunFlurries
        case .wintryMix:                   return .wintryMix
        case .thunderstorms:               return .thunderstorms
        case .isolatedThunderstorms:       return .isolatedThunderstorms
        case .scatteredThunderstorms:      return .scatteredThunderstorms
        case .strongStorms:                return .strongStorms
        case .tropicalStorm:               return .tropicalStorm
        case .hurricane:                   return .hurricane
        case .windy:                       return .windy
        case .breezy:                      return .breezy
        case .hot:                         return .hot
        case .frigid:                      return .frigid
        case .blowingDust:                 return .blowingDust
        case .hail:                        return .heavyRain
        default:                           return .partlyCloudy
        }
    }

    // MARK: - Display Helpers

    var weatherDescription: String {
        if error != nil {
            return "Weather unavailable"
        }
        guard let weather = currentWeather else {
            return isLoading ? "Loading weather..." : "Weather unavailable"
        }
        let temp = Int(weather.temperatureFahrenheit)
        return "\(conditionDescription(weather.condition)), \(temp)°F"
    }

    var weatherIcon: String {
        guard let weather = currentWeather else { return "cloud.fill" }
        return sfSymbol(for: weather.condition, isDaylight: weather.isDaylight)
    }

    static func attributionLabel(for source: String) -> String {
        switch source {
        case "open-meteo":
            return "Weather by Open-Meteo"
        default:
            return "Weather"
        }
    }

    static func attributionURL(for source: String) -> URL {
        switch source {
        case "open-meteo":
            return URL(string: "https://open-meteo.com/") ?? URL(string: "https://open-meteo.com")!
        default:
            return URL(string: "https://weather-data.apple.com/legal-attribution.html") ?? URL(string: "https://weather.apple.com")!
        }
    }

    // MARK: - Internals

    private func conditionDescription(_ condition: HorizonCondition) -> String {
        switch condition {
        case .clear:                   return "Clear"
        case .mostlyClear:             return "Mostly Clear"
        case .partlyCloudy:            return "Partly Cloudy"
        case .mostlyCloudy:            return "Mostly Cloudy"
        case .cloudy:                  return "Cloudy"
        case .foggy:                   return "Foggy"
        case .haze:                    return "Hazy"
        case .smoky:                   return "Smoky"
        case .drizzle:                 return "Drizzle"
        case .rain:                    return "Rain"
        case .heavyRain:               return "Heavy Rain"
        case .freezingDrizzle:         return "Freezing Drizzle"
        case .freezingRain:            return "Freezing Rain"
        case .sunShowers:              return "Sun Showers"
        case .snow:                    return "Snow"
        case .sleet:                   return "Sleet"
        case .blowingSnow:             return "Blowing Snow"
        case .blizzard:                return "Blizzard"
        case .flurries:                return "Flurries"
        case .sunFlurries:             return "Sun & Flurries"
        case .wintryMix:               return "Wintry Mix"
        case .thunderstorms:           return "Thunderstorms"
        case .isolatedThunderstorms:   return "Isolated Thunderstorms"
        case .scatteredThunderstorms:  return "Scattered Thunderstorms"
        case .strongStorms:            return "Strong Storms"
        case .tropicalStorm:           return "Tropical Storm"
        case .hurricane:               return "Hurricane"
        case .windy:                   return "Windy"
        case .breezy:                  return "Breezy"
        case .hot:                     return "Hot"
        case .frigid:                  return "Frigid"
        case .blowingDust:             return "Blowing Dust"
        }
    }

    private func sfSymbol(for condition: HorizonCondition, isDaylight: Bool) -> String {
        switch condition {
        case .clear:                   return isDaylight ? "sun.max.fill" : "moon.stars.fill"
        case .mostlyClear:             return isDaylight ? "sun.max.fill" : "moon.fill"
        case .partlyCloudy:            return isDaylight ? "cloud.sun.fill" : "cloud.moon.fill"
        case .mostlyCloudy:            return isDaylight ? "cloud.sun.fill" : "cloud.moon.fill"
        case .cloudy:                  return "cloud.fill"
        case .foggy, .haze, .smoky:    return "cloud.fog.fill"
        case .drizzle, .sunShowers:    return "cloud.drizzle.fill"
        case .rain:                    return "cloud.rain.fill"
        case .heavyRain:               return "cloud.heavyrain.fill"
        case .freezingDrizzle,
             .freezingRain:            return "cloud.sleet.fill"
        case .snow, .flurries,
             .sunFlurries:             return "cloud.snow.fill"
        case .sleet, .wintryMix:       return "cloud.sleet.fill"
        case .blowingSnow, .blizzard:  return "wind.snow"
        case .thunderstorms,
             .isolatedThunderstorms,
             .scatteredThunderstorms,
             .strongStorms:            return "cloud.bolt.rain.fill"
        case .tropicalStorm,
             .hurricane:               return "hurricane"
        case .windy, .breezy:          return "wind"
        case .hot:                     return "thermometer.sun.fill"
        case .frigid:                  return "thermometer.snowflake"
        case .blowingDust:             return "sun.dust.fill"
        }
    }
}
