import Foundation
import CoreLocation
import MapKit
internal import Combine

@MainActor
class LocationService: NSObject, ObservableObject {
    static let shared = LocationService()

    enum RuntimePlan: Equatable {
        case disableUsage
        case requestSingleLocation
        case restoreCachedAndFallback
        case clearAndFallback
    }

    @Published var currentLocation: CLLocation?
    @Published var locationName: String = "Unknown Location"
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var sunriseTime: Date?
    @Published var sunsetTime: Date?
    @Published var locationError: Error?

    private let locationManager = CLLocationManager()
    private var hasTriedFallbacks = false
    private var locationRequestTimeoutTask: Task<Void, Never>?

    // UserDefaults keys for caching
    private let cachedLatKey = "cachedLocationLatitude"
    private let cachedLonKey = "cachedLocationLongitude"
    private let cachedNameKey = "cachedLocationName"
    private let useDeviceLocationKey = "useDeviceLocation"

    private var hasLocationAuthorization: Bool {
        authorizationStatus == .authorizedAlways
            || authorizationStatus == .authorized
    }

    private var useDeviceLocation: Bool {
        UserDefaults.standard.object(forKey: useDeviceLocationKey) as? Bool ?? true
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        authorizationStatus = locationManager.authorizationStatus

        print("[LocationService] Init, authorization: \(authorizationStatus.rawValue)")

        // Load cached location immediately so UI isn't blank
        loadCachedLocation()

        Task { @MainActor in
            if useDeviceLocation && hasLocationAuthorization {
                requestSingleLocation()
            } else if authorizationStatus != .notDetermined {
                // Permission denied, using timezone fallback
                applyTimezoneFallback()
            }
        }
    }

    func requestLocationPermission() {
        print("[LocationService] Requesting location permission...")
        locationManager.requestWhenInUseAuthorization()
    }

    func startUpdatingLocation(requestPermissionIfNeeded: Bool = false) {
        print("[LocationService] startUpdatingLocation, authorization: \(authorizationStatus.rawValue)")

        guard useDeviceLocation else {
            disableLocationUsage()
            return
        }

        if authorizationStatus == .notDetermined {
            if requestPermissionIfNeeded {
                requestLocationPermission()
            } else {
                applyTimezoneFallback()
            }
            return
        }

        if hasLocationAuthorization {
            hasTriedFallbacks = false
            requestSingleLocation()
        } else {
            applyTimezoneFallback()
        }
    }

    func refreshLocation(requestPermissionIfNeeded: Bool = false) {
        print("[LocationService] refreshLocation called")
        locationName = "Updating..."
        hasTriedFallbacks = false

        guard useDeviceLocation else {
            disableLocationUsage()
            return
        }

        if hasLocationAuthorization {
            requestSingleLocation()
        } else if authorizationStatus == .notDetermined {
            if requestPermissionIfNeeded {
                requestLocationPermission()
            } else {
                applyTimezoneFallback()
            }
        } else {
            applyTimezoneFallback()
        }
    }

    func stopUpdatingLocation() {
        locationManager.stopUpdatingLocation()
    }

    func disableLocationUsage() {
        stopUpdatingLocation()
        currentLocation = nil
        locationError = nil
        HorizonWeatherService.shared.clearWeather(reason: "Location disabled by user")
        applyTimezoneFallback()
    }

    func reconcileRuntimeState(reason: String) {
        authorizationStatus = locationManager.authorizationStatus
        print("[LocationService] Reconciling runtime state (\(reason)), authorization: \(authorizationStatus.rawValue)")

        switch Self.runtimePlan(
            useDeviceLocation: useDeviceLocation,
            authorizationStatus: authorizationStatus,
            hasLocationAuthorization: hasLocationAuthorization
        ) {
        case .disableUsage:
            disableLocationUsage()
        case .requestSingleLocation:
            requestSingleLocation()
        case .restoreCachedAndFallback:
            restoreCachedLocationIfAvailable()
            applyTimezoneFallback()
        case .clearAndFallback:
            currentLocation = nil
            locationError = nil
            HorizonWeatherService.shared.clearWeather(reason: "Location permission unavailable")
            applyTimezoneFallback()
        }
    }

    static func runtimePlan(
        useDeviceLocation: Bool,
        authorizationStatus: CLAuthorizationStatus,
        hasLocationAuthorization: Bool
    ) -> RuntimePlan {
        guard useDeviceLocation else {
            return .disableUsage
        }

        if hasLocationAuthorization {
            return .requestSingleLocation
        }

        if authorizationStatus == .notDetermined {
            return .restoreCachedAndFallback
        }

        return .clearAndFallback
    }

    private func requestSingleLocation() {
        print("[LocationService] Requesting single location fix...")
        locationManager.requestLocation()
        locationRequestTimeoutTask?.cancel()
        locationRequestTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 12 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            if self.currentLocation == nil {
                print("[LocationService] Location request timed out, applying fallback")
                self.locationError = CLError(.locationUnknown)
                self.restoreCachedLocationIfAvailable()
                if self.currentLocation == nil {
                    self.applyTimezoneFallback()
                }
            }
        }
    }

    // MARK: - Location Resolved

    /// Called when we successfully get a location from any source
    private func didResolveLocation(_ location: CLLocation, name: String? = nil) {
        locationRequestTimeoutTask?.cancel()
        locationRequestTimeoutTask = nil
        self.currentLocation = location
        self.calculateSunTimes(for: location)

        // Cache for future use
        cacheLocation(location, name: name)

        if let name = name {
            self.locationName = name
        } else {
            reverseGeocodeLocation(location)
        }
    }

    // MARK: - Caching

    private func cacheLocation(_ location: CLLocation, name: String?) {
        let defaults = UserDefaults.standard
        defaults.set(location.coordinate.latitude, forKey: cachedLatKey)
        defaults.set(location.coordinate.longitude, forKey: cachedLonKey)
        if let name = name {
            defaults.set(name, forKey: cachedNameKey)
        }
        print("[LocationService] Cached location: \(name ?? "unnamed") (\(location.coordinate.latitude), \(location.coordinate.longitude))")
    }

    private func loadCachedLocation() {
        let defaults = UserDefaults.standard
        let lat = defaults.double(forKey: cachedLatKey)
        let lon = defaults.double(forKey: cachedLonKey)

        // Check if we have a cached location (0,0 means never saved)
        guard lat != 0 || lon != 0 else { return }

        let location = CLLocation(latitude: lat, longitude: lon)
        self.currentLocation = location
        self.calculateSunTimes(for: location)

        if let name = defaults.string(forKey: cachedNameKey) {
            self.locationName = name
            print("[LocationService] Loaded cached location: \(name)")
        }
    }

    private func restoreCachedLocationIfAvailable() {
        loadCachedLocation()
    }

    // MARK: - Timezone Fallback (VPN-safe)

    /// Uses the system timezone to derive approximate coordinates.
    /// This is always accurate regardless of VPN because macOS timezone is set locally.
    private func applyTimezoneFallback() {
        print("[LocationService] Applying timezone-based fallback (VPN-safe)...")

        let tz = TimeZone.current
        let offsetSeconds = tz.secondsFromGMT(for: Date())

        // Approximate longitude from UTC offset (15° per hour)
        let approximateLongitude = Double(offsetSeconds) / 3600.0 * 15.0

        // Use a mid-latitude estimate (~35°N covers most of continental US)
        // This gives good enough sunrise/sunset for most users
        let approximateLatitude = 35.0

        // Extract a readable name from the timezone identifier
        // e.g. "America/Chicago" → "Chicago", "America/New_York" → "New York"
        let tzName = tz.identifier
            .components(separatedBy: "/").last?
            .replacingOccurrences(of: "_", with: " ") ?? "Your Area"

        let location = CLLocation(latitude: approximateLatitude, longitude: approximateLongitude)
        currentLocation = nil
        locationName = "Using approximate daylight timing"
        calculateSunTimes(for: location)
        print("[LocationService] Timezone fallback: \(tzName) (approx \(approximateLatitude), \(approximateLongitude))")
    }

    // MARK: - Reverse Geocoding

    private func reverseGeocodeLocation(_ location: CLLocation) {
        if #available(macOS 26.0, *) {
            Task { [weak self] in
                guard let self else { return }
                do {
                    guard let request = MKReverseGeocodingRequest(location: location) else {
                        self.locationName = "Current Location"
                        self.cacheLocation(location, name: self.locationName)
                        return
                    }
                    let mapItems = try await request.mapItems
                    let addressRepresentations = mapItems.first?.addressRepresentations

                    if let cityWithContext = addressRepresentations?.cityWithContext(.short) {
                        self.locationName = cityWithContext
                    } else if let city = addressRepresentations?.cityName {
                        self.locationName = city
                    } else if let region = addressRepresentations?.regionName {
                        self.locationName = region
                    } else {
                        self.locationName = "Current Location"
                    }
                    self.cacheLocation(location, name: self.locationName)
                    print("[LocationService] Geocoded: \(self.locationName)")
                } catch {
                    print("[LocationService] Geocoding error: \(error.localizedDescription)")
                }
            }
        } else {
            CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, error in
                guard let service = self else { return }
                Task { @MainActor in
                    if let error {
                        print("[LocationService] Geocoding error: \(error.localizedDescription)")
                        return
                    }
                    let placemark = placemarks?.first
                    if let locality = placemark?.locality, let region = placemark?.administrativeArea {
                        service.locationName = "\(locality), \(region)"
                    } else if let locality = placemark?.locality {
                        service.locationName = locality
                    } else if let name = placemark?.name {
                        service.locationName = name
                    } else if let region = placemark?.administrativeArea {
                        service.locationName = region
                    } else {
                        service.locationName = "Current Location"
                    }
                    service.cacheLocation(location, name: service.locationName)
                    print("[LocationService] Geocoded: \(service.locationName)")
                }
            }
        }
    }

    // MARK: - Sun Time Calculations

    private func calculateSunTimes(for location: CLLocation) {
        let now = Date()

        guard let sunrise = calculateSunEvent(for: location, date: now, isSunrise: true),
              let sunset = calculateSunEvent(for: location, date: now, isSunrise: false) else {
            return
        }

        self.sunriseTime = sunrise
        self.sunsetTime = sunset
        print("[LocationService] Sun times, sunrise: \(formattedSunriseTime ?? "nil"), sunset: \(formattedSunsetTime ?? "nil")")
    }

    private func calculateSunEvent(for location: CLLocation, date: Date, isSunrise: Bool) -> Date? {
        let calendar = Calendar.current
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude

        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        let declination = -23.44 * cos((360.0 / 365.0) * Double(dayOfYear + 10) * .pi / 180.0)

        let latRad = latitude * .pi / 180.0
        let declRad = declination * .pi / 180.0

        let cosHourAngle = -tan(latRad) * tan(declRad)
        guard abs(cosHourAngle) <= 1.0 else { return nil }

        let hourAngle = acos(cosHourAngle) * 180.0 / .pi

        let solarNoon = 12.0 - (longitude / 15.0)
        let eventTimeUTC = isSunrise ? solarNoon - (hourAngle / 15.0) : solarNoon + (hourAngle / 15.0)

        let timezoneOffset = Double(TimeZone.current.secondsFromGMT(for: date)) / 3600.0
        let eventTimeLocal = eventTimeUTC + timezoneOffset

        let normalizedTime = ((eventTimeLocal.truncatingRemainder(dividingBy: 24.0)) + 24.0).truncatingRemainder(dividingBy: 24.0)

        let hour = Int(normalizedTime)
        let minute = Int((normalizedTime - Double(hour)) * 60.0)

        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = hour
        components.minute = minute
        components.second = 0

        return calendar.date(from: components)
    }

    private static let shortTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    var formattedSunsetTime: String? {
        guard let sunset = sunsetTime else { return nil }
        return Self.shortTimeFormatter.string(from: sunset)
    }

    var formattedSunriseTime: String? {
        guard let sunrise = sunriseTime else { return nil }
        return Self.shortTimeFormatter.string(from: sunrise)
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            print("[LocationService] Authorization changed: \(manager.authorizationStatus.rawValue)")

            if hasLocationAuthorization {
                self.restoreCachedLocationIfAvailable()
                self.requestSingleLocation()
            } else {
                HorizonWeatherService.shared.clearWeather(reason: "Location access unavailable")
                self.applyTimezoneFallback()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            print("[LocationService] ✅ Got location: \(location.coordinate.latitude), \(location.coordinate.longitude)")
            self.didResolveLocation(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let clError = error as? CLError
            print("[LocationService] ⚠️ Core Location error: code=\(clError?.code.rawValue ?? -1), \(error.localizedDescription)")
            self.locationError = error
            self.locationRequestTimeoutTask?.cancel()
            self.locationRequestTimeoutTask = nil

            // Fallback chain: cached location, then timezone.
            if !self.hasTriedFallbacks {
                self.hasTriedFallbacks = true

                // If we already have a cached location, restore cached name and use it
                if self.currentLocation != nil {
                    if let cachedName = UserDefaults.standard.string(forKey: self.cachedNameKey) {
                        self.locationName = cachedName
                    }
                    print("[LocationService] Using cached location")
                    return
                }

                // Otherwise use timezone (VPN-safe, always works)
                self.applyTimezoneFallback()
            }
        }
    }
}
