import SwiftUI
import AppKit
import WeatherKit
internal import Combine

struct DashboardView: View {
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    @StateObject private var weatherService = HorizonWeatherService.shared
    @StateObject private var locationService = LocationService.shared
    @StateObject private var userWallpaperManager = UserWallpaperManager.shared

    // Get actual frequency from UserDefaults (matches ScheduleSettingsView)
    private var wallpapersPerDay: Int {
        let stored = UserDefaults.standard.double(forKey: HorizonScheduleDefaults.wallpapersPerDayKey)
        return stored == 0 ? 8 : Int(stored)
    }

    // Get actual wallpapers shown today from history
    private var wallpapersShownToday: Int {
        wallpaperManager.todayHistory.count
    }

    // Get current time slot
    private var currentTimeSlot: String {
        wallpaperManager.currentTimeSlot()
    }

    private var currentSlotInfo: (title: String, color: Color)? {
        let slot = HorizonScheduleSettings.timeSlots.first(where: { $0.id == currentTimeSlot })
        guard let slot = slot else { return nil }
        return (slot.title, HorizonColors.colorForSlot(slot.id))
    }


    private var nextChangeText: String {
        wallpaperManager.nextChangeCountdown
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(spacing: HorizonSpacing.xl) {
                // Greeting Header
                GreetingHeader(locationService: locationService)
                    .padding(.horizontal, HorizonSpacing.xxxl)
                    .padding(.top, HorizonSpacing.xl)
                    .id("dashboard-top")   // scroll anchor for Today Preview's View buttons
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .onAppear {
                        locationService.startUpdatingLocation()
                    }

                // Weather & Current Wallpaper Cards
                GeometryReader { geometry in
                    let cardWidth = (geometry.size.width - HorizonSpacing.lg) / 2
                    let cardHeight: CGFloat = 260
                    HStack(spacing: HorizonSpacing.lg) {
                        WeatherCard(weatherService: weatherService)
                            .frame(width: cardWidth, height: cardHeight)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.9).combined(with: .opacity),
                                removal: .scale(scale: 0.9).combined(with: .opacity)
                            ))
                        CurrentWallpaperCard(wallpaperManager: wallpaperManager, currentSlot: currentTimeSlot)
                            .frame(width: cardWidth, height: cardHeight)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.9).combined(with: .opacity),
                                removal: .scale(scale: 0.9).combined(with: .opacity)
                            ))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
                .frame(height: 260)
                .padding(.horizontal, HorizonSpacing.xxxl)
                .task {
                    // fetchWeather is triggered automatically by HorizonWeatherService
                    // via its Combine subscription on LocationService.currentLocation.
                    // No manual call needed here.
                }

                // Stats Row
                HStack(spacing: HorizonSpacing.lg) {
                    MoodToggleCard()
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .scale(scale: 0.95).combined(with: .opacity)
                    ))

                    StatCard(
                        title: "Next Change",
                        value: nextChangeText,
                        subtitle: "Wallpaper Swap",
                        icon: "clock.arrow.circlepath",
                        color: HorizonColors.secondaryAccent
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .scale(scale: 0.95).combined(with: .opacity)
                    ))

                    StatCard(
                        title: "Current Slot",
                        value: currentSlotInfo?.title ?? "Automatic",
                        subtitle: "Time Aware",
                        icon: "sparkles",
                        color: HorizonColors.secondaryAccent
                    )
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .scale(scale: 0.95).combined(with: .opacity)
                    ))
                }
                .padding(.horizontal, HorizonSpacing.xxxl)


                // Timeline
                TimelineVisualization(wallpapersPerDay: wallpapersPerDay)
                    .padding(.horizontal, HorizonSpacing.xxxl)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))

                TodayPreviewSection(
                    wallpaperManager: wallpaperManager,
                    weatherService: weatherService,
                    scrollProxy: scrollProxy
                )
                .padding(.horizontal, HorizonSpacing.xxxl)
                .transition(.opacity.combined(with: .move(edge: .bottom)))

                // Recent History should reflect actual wallpaper changes for all users.
                RecentHistorySection(
                    history: Array(wallpaperManager.history.prefix(5)),
                    onSetCurrent: { entry in
                        wallpaperManager.setWallpaper(historyEntry: entry)
                    }
                )
                .padding(.horizontal, HorizonSpacing.xxxl)
                .transition(.opacity.combined(with: .move(edge: .bottom)))

                DashboardSupportFooter()
                    .padding(.bottom, HorizonSpacing.xxxl)
            }
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        }   // ScrollViewReader
    }
}

// MARK: - Support Footer

private struct DashboardSupportFooter: View {
    @State private var isHovered = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(MoodpaperSupportLinks.buyMeACoffee)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cup.and.saucer.fill")
                    .font(.system(size: 10))
                Text("Buy Me a Coffee")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isHovered ? HorizonColors.textPrimary : HorizonColors.textTertiary)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .frame(maxWidth: .infinity)
        .padding(.top, HorizonSpacing.sm)
        .accessibilityLabel("Buy me a coffee, opens in your browser")
    }
}

// MARK: - Greeting Header

private struct GreetingHeader: View {
    @ObservedObject var locationService: LocationService
    @EnvironmentObject var wallpaperManager: WallpaperManager
    @State private var appeared = false

    // DateFormatter is expensive to construct; hoist to file-static so we
    // don't allocate on every body recomputation.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f
    }()

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 0..<5:   return "Good Night"
        case 5..<12:  return "Good Morning"
        case 12..<17: return "Good Afternoon"
        case 17..<21: return "Good Evening"
        default:      return "Good Night"
        }
    }

    private var currentDate: String {
        Self.dateFormatter.string(from: Date())
    }

    private var currentSlot: HorizonScheduleSettings.TimeSlot? {
        let id = wallpaperManager.currentTimeSlot()
        return HorizonScheduleSettings.timeSlots.first { $0.id == id }
    }

    private var slotColor: Color {
        guard let slot = currentSlot else { return HorizonColors.primaryAccent }
        return HorizonColors.colorForSlot(slot.id)
    }

    var body: some View {
        VStack(spacing: HorizonSpacing.xs) {

            // Row 1: greeting (left) + slot badge (right)
            HStack(alignment: .center, spacing: 0) {
                Text(greeting)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)

                Spacer()

                if let slot = currentSlot {
                    HStack(spacing: 5) {
                        Image(systemName: slot.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .symbolRenderingMode(.monochrome)
                        Text(slot.title.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .kerning(0.6)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                }
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.0), value: appeared)

            // Row 2: location + sunset (left) + date (right)
            HStack(alignment: .center, spacing: 0) {
                if locationService.currentLocation != nil {
                    HStack(spacing: 14) {
                        Label(locationService.locationName, systemImage: "location.fill")
                        if let sunset = locationService.formattedSunsetTime {
                            HStack(spacing: 4) {
                                Text("Sunset \(sunset)")
                                Image(systemName: "sunset.fill")
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Text(currentDate)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 5)
            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1), value: appeared)
        }
        .frame(maxWidth: .infinity)
        .onAppear { appeared = true }
    }
}

// MARK: - Weather Card

private struct WeatherCard: View {
    @ObservedObject var weatherService: HorizonWeatherService
    @EnvironmentObject private var runtimeState: AppRuntimeState
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false
    @State private var weatherAttribution: WeatherAttribution?
    @AppStorage("temperatureUnit") private var temperatureUnit = "Fahrenheit"
    @AppStorage("windSpeedUnit") private var windSpeedUnit = "mph"
    @AppStorage("useDeviceLocation") private var useDeviceLocation: Bool = true
    @StateObject private var userWallpaperManager = UserWallpaperManager.shared
    @ObservedObject private var moodStore = MoodStore.shared

    private var accentColors: [Color] {
        switch weatherTone {
        case .clearDay:
            return [Color(hex: "4DA0FF"), Color(hex: "7EE8FF")]
        case .clearNight:
            return [Color(hex: "0E1B3F"), Color(hex: "243B77")]
        case .cloudy:
            return [Color(hex: "5B677A"), Color(hex: "9EAABD")]
        case .rain:
            return [Color(hex: "1F3A5F"), Color(hex: "3E6BA3")]
        case .snow:
            return [Color(hex: "E8F1FF"), Color(hex: "C9DBF8")]
        case .warmGlow:
            return [Color(hex: "FFB37A"), Color(hex: "FF7E8F")]
        }
    }

    // A vivid glow color that's always visible (avoids near-black night tones)
    private var glowColor: Color {
        switch weatherTone {
        case .clearDay:   return Color(hex: "4DA0FF")
        case .clearNight: return Color(hex: "5B8CFF")
        case .cloudy:     return Color(hex: "9EAABD")
        case .rain:       return Color(hex: "3E6BA3")
        case .snow:       return Color(hex: "C9DBF8")
        case .warmGlow:   return Color(hex: "FF7E8F")
        }
    }

    private var chipForegroundColor: Color {
        colorScheme == .light ? Color.black.opacity(0.78) : Color.white.opacity(0.92)
    }

    private var accentGradient: LinearGradient {
        LinearGradient(colors: accentColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var auraGradient: AngularGradient {
        AngularGradient(colors: [
            Color.white.opacity(0.25),
            accentColors.first?.opacity(0.45) ?? .white.opacity(0.3),
            Color.white.opacity(0.05),
            accentColors.last?.opacity(0.45) ?? .white.opacity(0.3)
        ], center: .center, angle: .degrees(220))
    }

    private enum WeatherTone {
        case clearDay, clearNight, cloudy, rain, snow, warmGlow
    }

    private var weatherTone: WeatherTone {
        guard let w = weatherService.currentWeather else { return .warmGlow }
        switch w.condition {
        case .clear, .mostlyClear:
            return w.isDaylight ? .clearDay : .clearNight
        case .partlyCloudy, .mostlyCloudy, .cloudy,
             .foggy, .haze, .smoky:
            return .cloudy
        case .drizzle, .rain, .heavyRain, .sunShowers,
             .freezingDrizzle, .freezingRain,
             .thunderstorms, .isolatedThunderstorms,
             .scatteredThunderstorms, .strongStorms,
             .tropicalStorm, .hurricane:
            return .rain
        case .snow, .sleet, .blowingSnow, .blizzard,
             .flurries, .sunFlurries, .wintryMix:
            return .snow
        default:
            return .warmGlow
        }
    }

    private var temperatureText: String {
        guard let w = weatherService.currentWeather else { return "--°" }
        let temp = temperatureUnit == "Celsius" ? w.temperature : w.temperatureFahrenheit
        return "\(Int(temp.rounded()))°"
    }
    private var conditionText: String {
        if weatherService.error != nil {
            return "Using time-based wallpaper changes"
        }
        return weatherService.weatherDescription.components(separatedBy: ",").first ?? "Loading weather..."
    }
    private var windText: String {
        guard let speed = weatherService.currentWeather?.windSpeed else { return "--" }
        if windSpeedUnit == "mph" {
            let mph = speed * 0.621371
            return "\(Int(mph.rounded())) mph"
        }
        return "\(Int(speed.rounded())) km/h"
    }

    private var feelsLikeText: String {
        guard let weather = weatherService.currentWeather else { return "--°" }
        // Simple feels like calculation based on temperature and humidity
        let temp = temperatureUnit == "Celsius" ? weather.temperature : weather.temperatureFahrenheit
        let humidity = weather.humidity ?? 0.5

        // Basic heat index calculation (simplified)
        if temp > 80 && humidity > 0.4 {
            let feelsLike = temp + (humidity - 0.4) * 10
            return "\(Int(feelsLike.rounded()))°"
        }

        // Basic wind chill (simplified)
        if let windSpeed = weather.windSpeed, windSpeed > 5 && temp < 50 {
            let windMph = windSpeedUnit == "mph" ? windSpeed : windSpeed * 0.621371
            let feelsLike = temp - windMph * 0.7
            return "\(Int(feelsLike.rounded()))°"
        }

        return "\(Int(temp.rounded()))°"
    }
    private var humidityText: String { weatherService.currentWeather?.humidity.map { "\(Int($0 * 100))%" } ?? "--" }
    private var statusNote: String? {
        if !useDeviceLocation {
            return "Location off. Using approximate daylight timing."
        }
        if !runtimeState.locationAuthorized {
            return "Location unavailable. Using approximate daylight timing."
        }
        if weatherService.error != nil {
            return "Weather unavailable."
        }
        return nil
    }

    @ViewBuilder
    private var attributionBadge: some View {
        if weatherService.source == "weatherkit", let attribution = weatherAttribution {
            Link(destination: attribution.legalPageURL) {
                HStack(spacing: 4) {
                    Image(systemName: "applelogo")
                    Text("Weather")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chipForegroundColor)
                .frame(minHeight: 12)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
        } else {
            Link(destination: weatherService.attributionURL) {
                HStack(spacing: 4) {
                    Image(systemName: weatherService.weatherIcon)
                    Text(weatherService.attributionLabel)
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(chipForegroundColor)
                .frame(minHeight: 12)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var weatherHeroIcon: some View {
        let icon = Image(systemName: weatherService.weatherIcon)
            .font(.system(size: 54, weight: .semibold))
            .foregroundStyle(.primary)
            .symbolRenderingMode(.multicolor)

        if #available(macOS 15.0, *) {
            icon.symbolEffect(.breathe, options: .repeating.speed(0.3))
        } else {
            icon
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.white.opacity(0.05), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: HorizonSpacing.sm) {
                // Top row: controls
                HStack {
                    attributionBadge

                    Spacer()
                }

                // Middle: hero content
                HStack(alignment: .center, spacing: HorizonSpacing.md) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(temperatureText)
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)

                        Text(conditionText)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)

                        if let statusNote {
                            Text(statusNote)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    weatherHeroIcon
                        .scaleEffect(isHovered ? 1.08 : 1.0)
                        .frame(width: 130, height: 130)
                }

                // Bottom metrics — spread evenly, always single row
                HStack(spacing: 0) {
                    MetricChip(label: "Wind", value: windText, icon: "wind", foregroundColor: chipForegroundColor)
                    Spacer()
                    MetricChip(label: "Humidity", value: humidityText, icon: "humidity.fill", foregroundColor: chipForegroundColor)
                    Spacer()
                    MetricChip(label: "Feels Like", value: feelsLikeText, icon: "thermometer", foregroundColor: chipForegroundColor)
                    Spacer()
                    MetricChip(
                        label: "Mood",
                        value: moodStore.activeMood?.name ?? "None",
                        icon: "paintpalette.fill",
                        foregroundColor: chipForegroundColor
                    )
                }
            }
            .padding(HorizonSpacing.lg)

        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(isHovered ? 0.18 : 0.14), radius: isHovered ? 22 : 18, y: 12)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .shadow(color: isHovered ? glowColor.opacity(0.5) : .clear, radius: 36, y: 8)
        .onHover { hovering in
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                isHovered = hovering
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: weatherService.currentWeather)
        .task {
            guard weatherAttribution == nil else { return }
            weatherAttribution = try? await WeatherKit.WeatherService.shared.attribution
        }
    }

}

// MARK: - Weather Metric Chip

private struct MetricChip: View {
    let label: String
    let value: String
    let icon: String
    let foregroundColor: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(foregroundColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(foregroundColor.opacity(0.72))
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(foregroundColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(foregroundColor.opacity(0.15), lineWidth: 0.6)
        )
    }
}

// MARK: - Current Wallpaper Card

private struct CurrentWallpaperCard: View {
    @ObservedObject var wallpaperManager: WallpaperManager
    let currentSlot: String
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var moodStore = MoodStore.shared
    @State private var isHovered = false
    @State private var isSkipping = false
    @State private var hostingScreen: NSScreen?
    @AppStorage(HorizonScheduleDefaults.pauseRotationKey) private var pauseRotation: Bool = false
    @State private var showingUnpinAlert = false
    private let appDidBecomeActive = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    private let activeSpaceDidChange = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
    // After waking from sleep, the OS may have changed the desktop image
    // underneath us. Force a reload (invalidates the cached image) so the
    // shared preview reflects the actual live state. Sidebar surfaces
    // observe the same WallpaperManager.currentPreviewImage so they pick
    // up the refresh in the same render pass.
    private let didWake = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)

    private var slotInfo: (title: String, color: Color)? {
        let actualSlot = currentSlot
        let slot = HorizonScheduleSettings.timeSlots.first(where: { $0.id == actualSlot })
        guard let slot = slot else { return nil }
        return (slot.title, HorizonColors.colorForSlot(slot.id))
    }

    /// Distinguishes a genuinely empty mood from a preview that just hasn't
    /// loaded yet, so the CTA only appears when there is actually nothing
    /// to show rather than flashing during normal async load.
    private var hasAnyMoodWallpapers: Bool {
        guard let mood = moodStore.activeMood else { return false }
        return moodStore.totalWallpaperCount(in: mood) > 0
    }

    var body: some View {
        // Full-bleed image as the entire card. Reads the shared preview
        // image off WallpaperManager so sidebar + dashboard surfaces
        // always render the same wallpaper from one source of truth.
        ZStack {
            // Background image or placeholder, fills edge to edge
            Color.clear
                .overlay {
                    if let previewImage = wallpaperManager.currentPreviewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .id(wallpaperManager.currentPreviewURL?.path ?? "")
                    } else if !hasAnyMoodWallpapers {
                        Rectangle()
                            .fill((slotInfo?.color ?? HorizonColors.primaryAccent).opacity(0.15).gradient)
                            .overlay {
                                VStack(spacing: HorizonSpacing.md) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 40, weight: .ultraLight))
                                        .foregroundColor(HorizonColors.textTertiary)
                                        .accessibilityHidden(true)
                                    Text("No wallpaper yet")
                                        .font(HorizonTypography.callout)
                                        .foregroundColor(HorizonColors.textSecondary)
                                    Button(action: openLibrary) {
                                        Text("Add Wallpapers")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 7)
                                            .background(Capsule().fill(HorizonColors.secondaryAccent))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                    } else {
                        Rectangle()
                            .fill((slotInfo?.color ?? HorizonColors.primaryAccent).opacity(0.15).gradient)
                            .overlay {
                                Image(systemName: "photo")
                                    .font(.system(size: 48, weight: .ultraLight))
                                    .foregroundColor(HorizonColors.textTertiary)
                                    .accessibilityHidden(true)
                            }
                    }
                }
                .clipped()

            // Bottom gradient
            VStack {
                Spacer()
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.55)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 60)
            }

            // Skip button, top trailing
            VStack {
                HStack {
                    // Pin indicator
                    if pauseRotation {
                        Button {
                            showingUnpinAlert = true
                        } label: {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(Circle().fill(Color.yellow.opacity(0.8)))
                                .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                                .padding(10)
                        }
                        .buttonStyle(.plain)
                        .help("Click to unpin")
                        .accessibilityLabel("Unpin current wallpaper")
                    }

                    Spacer()

                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                            isSkipping = true
                        }

                        wallpaperManager.skipToNext()
                        if !wallpaperManager.isChangingWallpaper {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                isSkipping = false
                            }
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Skip")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                                .overlay {
                                    Capsule()
                                        .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
                                }
                        )
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip to next wallpaper")
                    .scaleEffect(isSkipping ? 0.9 : 1.0)
                    .opacity(isSkipping ? 0.6 : 1.0)
                    .padding(10)
                }

                Spacer()
            }
            .alert("Unpin Wallpaper", isPresented: $showingUnpinAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Unpin", role: .destructive) {
                    pauseRotation = false
                }
            } message: {
                Text("Are you sure you want to unpin this wallpaper? Rotation will resume.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: HorizonRadius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HorizonRadius.lg, style: .continuous)
                .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
        }
        .background(
            WindowScreenObserver(screen: $hostingScreen)
        )
        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .shadow(color: isHovered ? (slotInfo?.color ?? HorizonColors.primaryAccent).opacity(0.6) : .clear, radius: 40, y: 12)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
        .onReceive(appDidBecomeActive) { _ in
            deferWallpaperPreviewRefresh()
        }
        .onReceive(activeSpaceDidChange) { _ in
            deferWallpaperPreviewRefresh()
        }
        .onReceive(didWake) { _ in
            // Force reload (and cache invalidation) on wake — the OS may
            // have changed the desktop image underneath us while sleeping.
            deferWallpaperPreviewRefresh(forceReload: true)
        }
        .onChange(of: hostingScreen?.localizedName) { _, _ in
            deferWallpaperPreviewRefresh()
        }
        .onChange(of: wallpaperManager.isChangingWallpaper) { _, isChanging in
            guard !isChanging else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                isSkipping = false
            }
        }
        .onAppear {
            deferWallpaperSyncAndPreviewRefresh()
        }
    }

    private func openLibrary() {
        NotificationCenter.default.post(name: .navigateToUserWallpapers, object: nil)
        openWindow(id: "settings")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            NSApplication.shared.windows
                .first { $0.identifier?.rawValue == "settings" || $0.identifier?.rawValue.hasPrefix("settings-") == true }
                .map { $0.makeKeyAndOrderFront(nil) }
        }
    }

    private func deferWallpaperPreviewRefresh(forceReload: Bool = false) {
        Task { @MainActor in
            await Task.yield()
            wallpaperManager.refreshCurrentPreview(
                preferredScreen: hostingScreen,
                forceReload: forceReload
            )
        }
    }

    private func deferWallpaperSyncAndPreviewRefresh() {
        Task { @MainActor in
            await Task.yield()
            wallpaperManager.syncCurrentWallpaperWithDesktop(preferredScreen: hostingScreen)
            wallpaperManager.refreshCurrentPreview(preferredScreen: hostingScreen)
        }
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color
    var action: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        let card = VStack(alignment: .leading, spacing: HorizonSpacing.md) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(color.gradient)
                    .scaleEffect(isHovered ? 1.1 : 1.0)
                    .rotationEffect(.degrees(isHovered ? 5 : 0))
                Spacer()
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(HorizonColors.textTertiary)
                        .accessibilityHidden(true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(HorizonTypography.caption)
                    .foregroundColor(HorizonColors.textSecondary)

                Text(value)
                    .font(HorizonTypography.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(HorizonColors.textPrimary)
                    .contentTransition(.numericText())

                Text(subtitle)
                    .font(HorizonTypography.caption2)
                    .foregroundColor(HorizonColors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .horizonGlassCard(style: .standard, padding: HorizonSpacing.lg)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .shadow(color: isHovered ? color.opacity(0.2) : .clear, radius: 15, y: 8)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }

        if let action = action {
            Button(action: action) { card }
                .buttonStyle(.plain)
        } else {
            card
        }
    }
}

private struct MoodToggleCard: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var store = MoodStore.shared
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            NotificationCenter.default.post(name: .navigateToMoods, object: nil)
            openWindow(id: "settings")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
                NSApplication.shared.windows
                    .first { $0.identifier?.rawValue == "settings" || $0.identifier?.rawValue.hasPrefix("settings-") == true }
                    .map { $0.makeKeyAndOrderFront(nil) }
            }
        }) {
            VStack(alignment: .leading, spacing: HorizonSpacing.md) {
                HStack {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(HorizonColors.secondaryAccent.gradient)
                        .scaleEffect(isHovered ? 1.1 : 1.0)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Mood")
                        .font(HorizonTypography.caption)
                        .foregroundColor(HorizonColors.textSecondary)

                    Text(store.activeMood?.name ?? "None")
                        .font(HorizonTypography.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(HorizonColors.textPrimary)

                    Text(store.activeMood != nil ? "Active" : "No mood set")
                        .font(HorizonTypography.caption2)
                        .foregroundColor(HorizonColors.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .horizonGlassCard(style: .standard, padding: HorizonSpacing.lg)
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .shadow(color: isHovered ? HorizonColors.primaryAccent.opacity(0.2) : .clear, radius: 15, y: 8)
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Timeline Visualization

private struct TimelineVisualization: View {
    let wallpapersPerDay: Int
    @State private var selectedSlot: String? = nil
    @AppStorage(HorizonScheduleDefaults.timeSlotModeKey) private var timeSlotMode: String = "Detailed"
    @AppStorage(HorizonScheduleDefaults.nightStartKey) private var nightStartRaw: String = HorizonScheduleDefaults.NightStart.oneHourAfter.rawValue

    // DateFormatters are expensive to construct; the slot array is recomputed
    // every render and on selection change, so hoist to file-static.
    private static let minuteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h a"
        return f
    }()

    struct SlotInfo: Identifiable {
        let id: String
        let title: String
        let color: Color
        let startTime: String   // "h:mm a", used by the detail pill
        let endTime: String     // "h:mm a", used by the detail pill
        let hourStart: String   // "h a", used by the sparse bottom row
        let reason: String
    }

    private var timeSlots: [SlotInfo] {
        let location = LocationService.shared
        let formatter = Self.minuteFormatter
        let hourFormatter = Self.hourFormatter

        func label(from date: Date) -> String { formatter.string(from: date) }
        func hourLabel(_ mins: Int) -> String { hourFormatter.string(from: minsToDate(mins)) }
        func minsToDate(_ mins: Int) -> Date {
            let cal = Calendar.current
            let now = Date()
            let start = cal.startOfDay(for: now)
            return start.addingTimeInterval(TimeInterval(mins * 60))
        }
        func minuteLabel(_ mins: Int) -> String { label(from: minsToDate(mins)) }

        if timeSlotMode == "Simple" {
            let sunriseLabel = location.formattedSunriseTime ?? "Sunrise"
            let sunsetLabel  = location.formattedSunsetTime  ?? "Sunset"
            return [
                SlotInfo(id: "morning",   title: "Morning",   color: HorizonColors.morning,   startTime: sunriseLabel, endTime: "12 PM",        hourStart: sunriseLabel, reason: "Starts at sunrise"),
                SlotInfo(id: "afternoon", title: "Afternoon", color: HorizonColors.afternoon, startTime: "12 PM",      endTime: sunsetLabel,    hourStart: "12 PM",      reason: "Starts at noon"),
                SlotInfo(id: "evening",   title: "Night",     color: HorizonColors.evening,   startTime: sunsetLabel,  endTime: "12 AM",        hourStart: sunsetLabel,  reason: "Starts at sunset")
            ]
        }

        // Detailed mode: mirror the exact boundaries from WallpaperManager
        if let sunrise = location.sunriseTime, let sunset = location.sunsetTime {
            let cal = Calendar.current
            let riseMins = cal.component(.hour, from: sunrise) * 60 + cal.component(.minute, from: sunrise)
            let setMins  = cal.component(.hour, from: sunset)  * 60 + cal.component(.minute, from: sunset)

            let dawnStart       = max(0, riseMins - 90)
            let sunriseStart    = max(0, riseMins - 30)
            let morningStart    = riseMins + 30
            let goldenHourStart = max(morningStart, setMins - 60)
            let duskStart       = setMins
            let eveningStart    = HorizonScheduleDefaults.eveningStartMinutes(duskStart: duskStart)

            let nightReason: String = {
                switch HorizonScheduleDefaults.currentNightStart {
                case .atSunset:      return "Starts at sunset"
                case .oneHourAfter:  return "Starts 1 hour after sunset"
                case .twoHoursAfter: return "Starts 2 hours after sunset"
                case .tenPM:         return "Starts at 10 PM"
                }
            }()

            return [
                SlotInfo(id: "deep-night",   title: "Deep Night",  color: HorizonColors.deepNight,  startTime: "12 AM",                      endTime: hourLabel(dawnStart),           hourStart: "12 AM",                    reason: "Starts at midnight"),
                SlotInfo(id: "dawn",         title: "Dawn",        color: HorizonColors.dawn,        startTime: minuteLabel(dawnStart),       endTime: minuteLabel(sunriseStart),      hourStart: hourLabel(dawnStart),       reason: "Starts 90 min before sunrise"),
                SlotInfo(id: "sunrise",      title: "Sunrise",     color: HorizonColors.sunrise,     startTime: minuteLabel(sunriseStart),    endTime: minuteLabel(morningStart),      hourStart: hourLabel(sunriseStart),    reason: "Centered on sunrise"),
                SlotInfo(id: "morning",      title: "Morning",     color: HorizonColors.morning,     startTime: minuteLabel(morningStart),    endTime: "12 PM",                        hourStart: hourLabel(morningStart),    reason: "Starts 30 min after sunrise"),
                SlotInfo(id: "midday",       title: "Midday",      color: HorizonColors.midday,      startTime: "12 PM",                      endTime: "3 PM",                         hourStart: "12 PM",                    reason: "Fixed: 12 PM to 3 PM"),
                SlotInfo(id: "afternoon",    title: "Afternoon",   color: HorizonColors.afternoon,   startTime: "3 PM",                       endTime: minuteLabel(goldenHourStart),   hourStart: "3 PM",                     reason: "Starts at 3 PM"),
                SlotInfo(id: "golden-hour",  title: "Golden Hour", color: HorizonColors.goldenHour,  startTime: minuteLabel(goldenHourStart), endTime: minuteLabel(duskStart),         hourStart: hourLabel(goldenHourStart), reason: "Start 60min before sunset, right before dusk"),
                SlotInfo(id: "dusk",         title: "Dusk",        color: HorizonColors.dusk,        startTime: minuteLabel(duskStart),       endTime: minuteLabel(eveningStart),      hourStart: hourLabel(duskStart),       reason: "Starts at sunset"),
                SlotInfo(id: "evening",      title: "Night",       color: HorizonColors.evening,     startTime: minuteLabel(eveningStart),    endTime: "12 AM",                        hourStart: hourLabel(eveningStart),    reason: nightReason)
            ]
        }

        // Fallback when solar data is unavailable — matches engine fixed-hour fallback
        return [
            SlotInfo(id: "deep-night",  title: "Deep Night",  color: HorizonColors.deepNight,  startTime: "12 AM", endTime: "4 AM",  hourStart: "12 AM", reason: "Starts at midnight"),
            SlotInfo(id: "dawn",        title: "Dawn",        color: HorizonColors.dawn,        startTime: "4 AM",  endTime: "6 AM",  hourStart: "4 AM",  reason: "Fixed: 4 AM to 6 AM"),
            SlotInfo(id: "sunrise",     title: "Sunrise",     color: HorizonColors.sunrise,     startTime: "6 AM",  endTime: "8 AM",  hourStart: "6 AM",  reason: "Fixed: 6 AM to 8 AM"),
            SlotInfo(id: "morning",     title: "Morning",     color: HorizonColors.morning,     startTime: "8 AM",  endTime: "12 PM", hourStart: "8 AM",  reason: "Fixed: 8 AM to 12 PM"),
            SlotInfo(id: "midday",      title: "Midday",      color: HorizonColors.midday,      startTime: "12 PM", endTime: "3 PM",  hourStart: "12 PM", reason: "Fixed: 12 PM to 3 PM"),
            SlotInfo(id: "afternoon",   title: "Afternoon",   color: HorizonColors.afternoon,   startTime: "3 PM",  endTime: "5 PM",  hourStart: "3 PM",  reason: "Fixed: 3 PM to 5 PM"),
            SlotInfo(id: "golden-hour", title: "Golden Hour", color: HorizonColors.goldenHour,  startTime: "5 PM",  endTime: "8 PM",  hourStart: "5 PM",  reason: "Fixed: 5 PM to 8 PM"),
            SlotInfo(id: "dusk",        title: "Dusk",        color: HorizonColors.dusk,        startTime: "8 PM",  endTime: "10 PM", hourStart: "8 PM",  reason: "Fixed: 8 PM to 10 PM"),
            SlotInfo(id: "evening",     title: "Night",       color: HorizonColors.evening,     startTime: "10 PM", endTime: "12 AM", hourStart: "10 PM", reason: "Fixed: 10 PM to midnight")
        ]
    }

    private var selectedSlotInfo: SlotInfo? {
        guard let id = selectedSlot else { return nil }
        return timeSlots.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HorizonSpacing.lg) {
            HStack {
                Text("Today's Timeline")
                    .font(HorizonTypography.title3)
                    .foregroundColor(HorizonColors.textPrimary)

                Spacer()

                if let info = selectedSlotInfo {
                    HorizonBadge(text: info.title, color: info.color, size: .small)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else {
                    HorizonBadge(
                        text: "\(wallpapersPerDay) wallpapers",
                        color: HorizonColors.secondaryAccent,
                        size: .small
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selectedSlot)

            VStack(spacing: HorizonSpacing.sm) {
                // Slot name labels
                HStack(spacing: 0) {
                    ForEach(timeSlots, id: \.id) { slot in
                        let isSelected = selectedSlot == slot.id
                        Text(slot.title)
                            .font(HorizonTypography.caption2)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .foregroundColor(isSelected ? HorizonColors.textPrimary : HorizonColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .multilineTextAlignment(.center)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .animation(.easeInOut(duration: 0.2), value: selectedSlot)
                    }
                }

                // Interactive gradient bar
                HStack(spacing: 2) {
                    ForEach(timeSlots) { slot in
                        let isSelected = selectedSlot == slot.id
                        let hasSelection = selectedSlot != nil
                        ZStack {
                            Rectangle()
                                .fill(slot.color.gradient)
                                .frame(maxWidth: .infinity)
                                .opacity(hasSelection && !isSelected ? 0.45 : 1.0)
                                .scaleEffect(
                                    x: 1.0,
                                    y: isSelected ? 1.18 : 1.0,
                                    anchor: .center
                                )
                            if isSelected {
                                Rectangle()
                                    .strokeBorder(.white.opacity(0.85), lineWidth: 2)
                                    .shadow(color: slot.color.opacity(0.8), radius: 6)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedSlot = (selectedSlot == slot.id) ? nil : slot.id
                            }
                        }
                    }
                }
                .frame(height: 36)
                .clipShape(RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                        .strokeBorder(HorizonColors.glassStroke, lineWidth: 1)
                }
                .animation(.easeInOut(duration: 0.2), value: selectedSlot)

                // Selected slot detail pill — slides in under bar
                if let info = selectedSlotInfo {
                    HStack(alignment: .top, spacing: HorizonSpacing.sm) {
                        Circle()
                            .fill(info.color)
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: HorizonSpacing.sm) {
                                Text(info.title)
                                    .font(HorizonTypography.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(HorizonColors.textPrimary)
                                Spacer()
                                Text("\(info.startTime) – \(info.endTime)")
                                    .font(HorizonTypography.caption)
                                    .foregroundColor(HorizonColors.textSecondary)
                            }
                            Text(info.reason)
                                .font(HorizonTypography.caption2)
                                .foregroundColor(HorizonColors.textTertiary)
                        }
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(HorizonColors.textTertiary)
                            .padding(.top, 3)
                            .accessibilityLabel("Close slot info")
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedSlot = nil
                                }
                            }
                    }
                    .padding(.horizontal, HorizonSpacing.md)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: HorizonRadius.sm, style: .continuous)
                            .fill(info.color.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: HorizonRadius.sm, style: .continuous)
                                    .strokeBorder(info.color.opacity(0.35), lineWidth: 1)
                            )
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    // Time labels (shown only when nothing selected)
                    HStack {
                        let labelSlots: [SlotInfo] = {
                            if timeSlotMode == "Simple" {
                                return timeSlots
                            } else {
                                return [timeSlots[0], timeSlots[3], timeSlots[4], timeSlots[6], timeSlots[8]]
                            }
                        }()
                        ForEach(labelSlots) { slot in
                            Text(slot.hourStart)
                                .font(HorizonTypography.caption2)
                                .foregroundColor(HorizonColors.textTertiary)
                                .frame(maxWidth: .infinity, alignment: slot.id == timeSlots.first?.id ? .leading : (slot.id == timeSlots.last?.id ? .trailing : .center))
                        }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: selectedSlot)
        }
        .horizonGlassCard(style: .standard, padding: HorizonSpacing.lg, glowColor: HorizonColors.secondaryAccent)
    }
}

// MARK: - Today Preview

private struct TodayPreviewSection: View {
    @ObservedObject var wallpaperManager: WallpaperManager
    @ObservedObject var weatherService: HorizonWeatherService
    let scrollProxy: ScrollViewProxy
    @StateObject private var calendarService = CalendarService.shared
    @AppStorage(HorizonScheduleDefaults.timeSlotModeKey) private var timeSlotMode = "Detailed"
    @AppStorage(HorizonScheduleDefaults.pauseRotationKey) private var pauseRotation = false
    @State private var previewedMomentID: String?

    private var moments: [TodayPreviewMoment] {
        let currentSlot = wallpaperManager.currentTimeSlot()
        let normalizedCurrentSlot = HorizonScheduleDefaults.validatedFocusSlot(
            preferred: currentSlot,
            mode: timeSlotMode
        )

        let allSlots = HorizonScheduleDefaults.slotIDs(for: timeSlotMode)
        let enabledSet = HorizonScheduleDefaults.enabledSlotIDs(mode: timeSlotMode)
        let enabled = enabledSet.isEmpty ? allSlots : enabledSet

        let inputs = TodayPreviewMoment.Inputs(
            currentSlotID: normalizedCurrentSlot,
            enabledSlotIDs: enabled,
            slotTitleByID: Dictionary(uniqueKeysWithValues: HorizonScheduleSettings.timeSlots.map { ($0.id, $0.title) }),
            slotIconByID: Dictionary(uniqueKeysWithValues: HorizonScheduleSettings.timeSlots.map { ($0.id, $0.symbol) }),
            nextChangeCountdown: wallpaperManager.nextChangeCountdown,
            pauseRotation: pauseRotation,
            focusModeEnabled: wallpaperManager.focusModeEnabled,
            focusSlotID: HorizonScheduleDefaults.validatedFocusSlot(
                preferred: wallpaperManager.focusSlot,
                mode: timeSlotMode
            ),
            isInMeeting: calendarService.isInMeeting,
            currentMeetingTitle: calendarService.currentMeetingTitle
        )
        return TodayPreviewMoment.build(inputs: inputs)
    }

    private var isFilteringDisabledSlots: Bool {
        let allSlots = HorizonScheduleDefaults.slotIDs(for: timeSlotMode)
        let enabledSlots = HorizonScheduleDefaults.enabledSlotIDs(mode: timeSlotMode)
        return !enabledSlots.isEmpty && enabledSlots.count < allSlots.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HorizonSpacing.lg) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today Preview")
                        .font(HorizonTypography.title3)
                        .foregroundColor(HorizonColors.textPrimary)
                    Text(isFilteringDisabledSlots ? "Upcoming moments from enabled slots only" : "Upcoming wallpaper moments")
                        .font(HorizonTypography.caption)
                        .foregroundColor(HorizonColors.textSecondary)
                }

                Spacer()

                HorizonBadge(
                    text: pauseRotation ? "Paused" : "Live",
                    color: pauseRotation ? HorizonColors.textSecondary : HorizonColors.secondaryAccent,
                    size: .small
                )
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: HorizonSpacing.md)], spacing: HorizonSpacing.md) {
                ForEach(moments) { moment in
                    TodayPreviewMomentCard(
                        moment: moment,
                        isPreviewed: previewedMomentID == moment.id,
                        onPreview: { applyMoment(moment) }
                    )
                }
            }
        }
        .horizonGlassCard(style: .standard, padding: HorizonSpacing.lg, glowColor: HorizonColors.secondaryAccent)
    }

    private func applyMoment(_ moment: TodayPreviewMoment) {
        switch moment.applyMode {
        case .disabled:
            return
        case .scrollTo(let anchorID):
            // Scroll-to actions don't mark the card as "Applied" — they
            // navigate, they don't change the wallpaper.
            withAnimation(.easeInOut(duration: 0.4)) {
                scrollProxy.scrollTo(anchorID, anchor: .top)
            }
            return
        case .standard(let slotID):
            previewedMomentID = moment.id
            wallpaperManager.setWallpaperForSlot(slotID)
        case .oneShotSlot(let slotID):
            previewedMomentID = moment.id
            wallpaperManager.setWallpaperForSlot(
                slotID,
                ignoreMood: true,
                suppressContextualOverrides: true
            )
        case .focusSlot(let slotID):
            previewedMomentID = moment.id
            wallpaperManager.setWallpaperForSlot(
                slotID,
                ignoreMood: true,
                suppressContextualOverrides: true
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if previewedMomentID == moment.id { previewedMomentID = nil }
            }
        }
    }

}

private struct TodayPreviewMomentCard: View {
    let moment: TodayPreviewMoment
    let isPreviewed: Bool
    let onPreview: () -> Void
    @State private var isHovered = false

    private var accentColor: Color {
        if let hex = moment.accentHex { return Color(hex: hex) }
        if let slot = moment.slotID { return readable(HorizonColors.colorForSlot(slot)) }
        return HorizonColors.secondaryAccent
    }

    private var titleColor: Color {
        moment.slotID == "deep-night" ? Color.white.opacity(0.92) : HorizonColors.textPrimary
    }

    private var detailColor: Color {
        moment.slotID == "deep-night" ? Color.white.opacity(0.68) : HorizonColors.textSecondary
    }

    private var isApplyDisabled: Bool {
        if case .disabled = moment.applyMode { return true }
        return false
    }

    private var showsInfoStyling: Bool {
        if case .disabled = moment.applyMode { return true }
        return false
    }

    private var applyLabel: String {
        if showsInfoStyling { return "Info" }
        if isPreviewed { return "Applied" }
        return moment.customApplyLabel ?? "Apply"
    }

    private var applyIcon: String {
        if showsInfoStyling { return "info.circle" }
        if isPreviewed { return "checkmark.circle.fill" }
        return moment.customApplyIcon ?? "paintbrush.pointed"
    }

    private var applyColor: Color {
        // All pills (Apply, Shuffle, Info) use the card's full accent color
        // so they read with equal weight on light vibe surfaces. The
        // disabled state is conveyed by the label ("Info"), icon
        // ("info.circle"), and the button being non-interactive — not by
        // dimming the color.
        if isPreviewed { return .green }
        return accentColor
    }

    /// Luminance-lift for dark slot colors so they read on the dark card
    /// surface. Bright slot colors pass through unchanged.
    private func readable(_ color: Color) -> Color {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        let luminance = 0.299 * ns.redComponent + 0.587 * ns.greenComponent + 0.114 * ns.blueComponent
        guard luminance < 0.5 else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(nsColor: NSColor(
            hue: h,
            saturation: max(s * 0.75, 0.45),
            brightness: 0.88,
            alpha: 1
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HorizonSpacing.md) {
            HStack {
                Label(moment.label, systemImage: moment.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accentColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                if moment.isCalendarConditional {
                    Label("Calendar", systemImage: "calendar")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(accentColor)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(accentColor.opacity(0.12))
                                .overlay(
                                    Capsule()
                                        .strokeBorder(accentColor.opacity(0.25), lineWidth: 1)
                                )
                        )
                }
                Circle()
                    .fill(accentColor.gradient)
                    .frame(width: 9, height: 9)
                    .shadow(color: accentColor.opacity(0.45), radius: 5)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(moment.title)
                    .font(HorizonTypography.bodyMedium)
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(moment.detail)
                    .font(HorizonTypography.caption2)
                    .foregroundColor(detailColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Absorb extra vertical space so the Apply pill stays anchored to
            // the bottom of every card. Combined with .frame(maxHeight: .infinity)
            // on the outer VStack, this makes all cards in a row match height.
            Spacer(minLength: 0)

            Button(action: onPreview) {
                Label(applyLabel, systemImage: applyIcon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(applyColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(applyColor.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .strokeBorder(applyColor.opacity(0.32), lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            // Use allowsHitTesting instead of .disabled so SwiftUI doesn't
            // apply its system grayscale/opacity to the pill. Disabled
            // moments already no-op inside applyMoment(_:).
            .allowsHitTesting(!isApplyDisabled)
        }
        .padding(HorizonSpacing.md)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                .fill(isHovered ? accentColor.opacity(0.10) : HorizonColors.backgroundSecondary.opacity(0.35))
                .overlay(
                    RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                        .strokeBorder(isHovered ? accentColor.opacity(0.35) : HorizonColors.glassStroke, lineWidth: 1)
                )
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Recent History Section

private struct RecentHistorySection: View {
    let history: [WallpaperHistoryEntry]
    let onSetCurrent: (WallpaperHistoryEntry) -> Void
    @State private var selectedEntryID: UUID? = nil
    @State private var setConfirmedID: UUID? = nil

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private func formatTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HorizonSpacing.lg) {
            HStack {
                Text("Recent Wallpaper History")
                    .font(HorizonTypography.title3)
                    .foregroundColor(HorizonColors.textPrimary)

                Spacer()

                if selectedEntryID != nil {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                            selectedEntryID = nil
                        }
                    }) {
                        Text("Done")
                            .font(HorizonTypography.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(HorizonColors.primaryAccent)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                } else {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(HorizonColors.textTertiary)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selectedEntryID)

            if history.isEmpty {
                VStack(spacing: HorizonSpacing.md) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 32))
                        .foregroundColor(HorizonColors.textTertiary)
                        .accessibilityHidden(true)
                    Text("No Wallpaper Changes Yet")
                        .font(HorizonTypography.body)
                        .foregroundColor(HorizonColors.textSecondary)
                    Text("History Will Appear as Moodpaper Changes Your Wallpapers")
                        .font(HorizonTypography.caption)
                        .foregroundColor(HorizonColors.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HorizonSpacing.xl)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(history.enumerated()), id: \.element.id) { index, entry in
                        let slotColor = HorizonColors.colorForSlot(entry.slotID)
                        let isSelected = selectedEntryID == entry.id
                        let wasConfirmed = setConfirmedID == entry.id

                        VStack(spacing: 0) {
                            HStack(spacing: HorizonSpacing.md) {
                                // Timeline dot + line
                                VStack(spacing: 2) {
                                    Circle()
                                        .fill(isSelected ? slotColor : slotColor.opacity(0.7))
                                        .frame(
                                            width: isSelected ? 10 : 8,
                                            height: isSelected ? 10 : 8
                                        )
                                        .shadow(
                                            color: isSelected ? slotColor.opacity(0.6) : .clear,
                                            radius: 4
                                        )
                                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isSelected)

                                    if index < history.count - 1 {
                                        Rectangle()
                                            .fill(HorizonColors.glassStroke)
                                            .frame(width: 1)
                                    }
                                }
                                .frame(width: 12, height: isSelected ? 52 : 40)

                                // Row content
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(formatTime(entry.timestamp))
                                            .font(HorizonTypography.bodyMedium)
                                            .foregroundColor(isSelected ? HorizonColors.textPrimary : HorizonColors.textSecondary)

                                        Text(entry.wallpaperName)
                                            .font(HorizonTypography.body)
                                            .foregroundColor(HorizonColors.textPrimary)
                                            .lineLimit(1)

                                        Spacer()

                                        HorizonBadge(
                                            text: entry.triggerDisplayName,
                                            color: HorizonColors.secondaryAccent,
                                            size: .small
                                        )

                                        HorizonBadge(
                                            text: entry.slotDisplayName,
                                            color: slotColor,
                                            size: .small
                                        )
                                    }

                                    // Set as Current button — expands when selected
                                    if isSelected {
                                        Button(action: {
                                            onSetCurrent(entry)
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                                setConfirmedID = entry.id
                                                selectedEntryID = nil
                                            }
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                                withAnimation { setConfirmedID = nil }
                                            }
                                        }) {
                                            Label("Set as Current", systemImage: "photo.on.rectangle.angled")
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundColor(slotColor)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                .background(
                                                    Capsule()
                                                        .fill(slotColor.opacity(0.15))
                                                        .overlay(
                                                            Capsule()
                                                                .strokeBorder(slotColor.opacity(0.4), lineWidth: 1)
                                                        )
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                    }
                                }
                            }
                            .padding(.horizontal, HorizonSpacing.md)
                            .padding(.vertical, isSelected ? HorizonSpacing.sm + 2 : HorizonSpacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                                    .fill(
                                        isSelected
                                            ? slotColor.opacity(0.10)
                                            : (wasConfirmed ? slotColor.opacity(0.06) : Color.clear)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                                            .strokeBorder(
                                                isSelected ? slotColor.opacity(0.3) : Color.clear,
                                                lineWidth: 1
                                            )
                                    )
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                    selectedEntryID = (selectedEntryID == entry.id) ? nil : entry.id
                                }
                            }
                            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
                        }
                    }
                }
            }
        }
        .horizonGlassCard(style: .standard, padding: HorizonSpacing.lg, glowColor: HorizonColors.primaryAccent)
    }
}
