import SwiftUI
import AppKit
import EventKit
import ServiceManagement
import UserNotifications
import CoreLocation
import UniformTypeIdentifiers
internal import Combine

// MARK: - Diagnostic Result Model

struct DiagResult: Identifiable {
    enum Status { case pass, warn, fail, info }
    let id = UUID()
    let name: String
    let status: Status
    let detail: String
}

// MARK: - Diagnostics View

struct DiagnosticsView: View {
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    @EnvironmentObject private var runtimeState: AppRuntimeState
    @StateObject private var performanceMetrics = AppPerformanceMetrics.shared
    @State private var sections: [(title: String, results: [DiagResult])] = []
    @State private var isRunning = false
    @State private var lastRun: Date? = nil
    @State private var actionMessage: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Diagnostics", systemImage: "stethoscope")
                            .font(.system(size: 22, weight: .semibold))
                        Spacer()
                        if isRunning {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 20, height: 20)
                        } else {
                            Button {
                                Task { await runAllChecks() }
                            } label: {
                                Label("Re-run", systemImage: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    HStack(spacing: 6) {
                        Text("Verifies engine, features, and settings before release.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if let date = lastRun {
                            Text("·")
                                .foregroundStyle(.tertiary)
                            Text("Last run \(date.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Summary bar
                if !sections.isEmpty {
                    let allResults = sections.flatMap { $0.results }
                    let passes  = allResults.filter { $0.status == .pass }.count
                    let warns   = allResults.filter { $0.status == .warn }.count
                    let fails   = allResults.filter { $0.status == .fail }.count
                    HStack(spacing: 12) {
                        SummaryBadge(count: passes, label: "Passed",  color: .green)
                        SummaryBadge(count: warns,  label: "Warning", color: .orange)
                        SummaryBadge(count: fails,  label: "Failed",  color: .red)
                    }
                }

                // Results sections
                ForEach(sections, id: \.title) { section in
                    DiagSection(title: section.title, results: section.results)
                }

                // Debug logging (opt-in, writes to ~/Library/Logs/Moodpaper/)
                DebugLoggingCard()

                // Action buttons
                DiagActionsCard(message: $actionMessage)
                    .environmentObject(wallpaperManager)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await runAllChecks() }
    }

    // MARK: - Check Runner

    private func runAllChecks() async {
        isRunning = true
        sections = []

        async let engineResults  = checkEngine()
        async let featureResults = checkFeatures()
        async let settingsResults = checkSettings()
        async let weatherResults = checkWeather()
        async let analyticsResults = checkAnalytics()
        async let performanceResults = checkPerformance()

        let (eng, feat, set, wea, ana, perf) = await (engineResults, featureResults, settingsResults, weatherResults, analyticsResults, performanceResults)

        sections = [
            (title: "Engine",   results: eng),
            (title: "Features", results: feat),
            (title: "Weather",  results: wea),
            (title: "Settings", results: set),
            (title: "Analytics", results: ana),
            (title: "Performance", results: perf),
        ]
        lastRun = Date()
        isRunning = false
    }

    // MARK: - Engine Checks

    private func checkEngine() async -> [DiagResult] {
        var results: [DiagResult] = []

        // Engine running
        let running = await MainActor.run { wallpaperManager.isRunning }
        results.append(DiagResult(
            name: "Engine running",
            status: running ? .pass : .fail,
            detail: running ? "Timer and observers are active" : "Engine is stopped. Wallpapers will not change."
        ))

        // Space observer
        let hasSpaceObs = await MainActor.run { wallpaperManager.hasSpaceObserver }
        results.append(DiagResult(
            name: "Space observer registered",
            status: hasSpaceObs ? .pass : .warn,
            detail: hasSpaceObs ? "Spaces sync observer is active" : "Space observer not registered. Spaces sync will not work."
        ))

        // Last wallpaper change
        let lastChange = await MainActor.run { wallpaperManager.lastWallpaperChangeDate }
        if let date = lastChange {
            let elapsed = Date().timeIntervalSince(date)
            let mins = Int(elapsed / 60)
            let status: DiagResult.Status = elapsed < 86_400 ? .pass : .warn
            results.append(DiagResult(
                name: "Last wallpaper change",
                status: status,
                detail: mins < 60 ? "\(mins)m ago" : "\(mins / 60)h \(mins % 60)m ago"
            ))
        } else {
            results.append(DiagResult(
                name: "Last wallpaper change",
                status: .warn,
                detail: "No wallpaper has been applied yet this session"
            ))
        }

        // Current wallpaper vs current slot
        let (wallpaperName, currentSlot) = await MainActor.run {
            (wallpaperManager.currentWallpaperName,
             wallpaperManager.currentTimeSlot())
        }
        if wallpaperName.isEmpty {
            results.append(DiagResult(
                name: "Wallpaper/slot alignment",
                status: .info,
                detail: "No wallpaper applied yet this session"
            ))
        } else {
            results.append(DiagResult(
                name: "Wallpaper/slot alignment",
                status: .info,
                detail: "\(wallpaperName), current slot is \(currentSlot)"
            ))
        }

        let persistedIdentifiers = await MainActor.run { wallpaperManager.currentWallpaperIdentifiersByScreen() }
        let activeDisplayNames = await MainActor.run {
            NSScreen.screens
                .filter { wallpaperManager.mode(for: $0.localizedName) != .off }
                .map(\.localizedName)
        }
        let persistedCount = persistedIdentifiers.keys.filter { screenName in
            activeDisplayNames.contains(screenName)
        }.count
        results.append(DiagResult(
            name: "Per-display wallpaper state",
            status: persistedCount >= max(activeDisplayNames.count, 1) ? .pass : .warn,
            detail: persistedIdentifiers.isEmpty
                ? "No per-display wallpaper state persisted yet"
                : "\(persistedCount) of \(activeDisplayNames.count) active displays tracked"
        ))

        return results
    }

    // MARK: - Manifest Checks


    // MARK: - Feature Checks

    private func checkFeatures() async -> [DiagResult] {
        var results: [DiagResult] = []

        // Notification permission
        let notifSettings = await UNUserNotificationCenter.current().notificationSettings()
        let notifyOnSlotChange = UserDefaults.standard.bool(forKey: HorizonScheduleDefaults.notifyOnSlotChangeKey)
        results.append(DiagResult(
            name: "Notification permission",
            status: {
                switch notifSettings.authorizationStatus {
                case .authorized:    return .pass
                case .denied:        return .warn
                case .notDetermined: return notifyOnSlotChange ? .warn : .info
                default:             return .info
                }
            }(),
            detail: {
                switch notifSettings.authorizationStatus {
                case .authorized:    return "Authorized. Slot change notifications will work."
                case .denied:        return "Denied. Slot change notifications will not appear."
                case .notDetermined: return notifyOnSlotChange ? "Not yet requested. Slot notifications are enabled." : "Not yet requested (slot notifications are off)"
                case .provisional:   return "Provisional"
                default:             return "Unknown"
                }
            }()
        ))

        // Calendar access for Focus Mode
        let calStatus = EKEventStore.authorizationStatus(for: .event)
        let calFocusEnabled = await MainActor.run { wallpaperManager.focusModeEnabled }
        results.append(DiagResult(
            name: "Calendar access (Focus Mode)",
            status: {
                switch calStatus {
                case .fullAccess:    return .pass
                case .writeOnly:     return .warn
                case .restricted:    return .warn
                case .denied:        return .warn
                case .notDetermined: return calFocusEnabled ? .warn : .info
                default:             return .info
                }
            }(),
            detail: {
                switch calStatus {
                case .fullAccess:    return "Full access granted. Focus Mode can read meetings."
                case .writeOnly:     return "Write-only. Focus Mode needs Calendar Full Access."
                case .restricted:    return "Restricted by device policy"
                case .denied:        return "Denied. Focus Mode will not detect meetings."
                case .notDetermined: return calFocusEnabled ? "Not yet requested. Focus Mode is enabled." : "Not yet requested (Focus Mode is off)"
                default:             return "Unknown"
                }
            }()
        ))

        // Location permission
        let locStatus = CLLocationManager().authorizationStatus
        results.append(DiagResult(
            name: "Location access (sunrise/sunset)",
            status: (locStatus == .authorizedAlways || locStatus == .authorized) ? .pass : .warn,
            detail: {
                switch locStatus {
                case .authorizedAlways, .authorized: return "Authorized. Accurate sunrise/sunset times active."
                case .denied:                        return "Denied. Using fallback time calculations."
                case .restricted:                    return "Restricted by device policy"
                case .notDetermined:                 return "Not yet requested"
                default:                             return "Unknown"
                }
            }()
        ))

        // Launch at Login
        let loginStatus = SMAppService.mainApp.status
        results.append(DiagResult(
            name: "Launch at Login",
            status: loginStatus == .enabled ? .pass : .info,
            detail: {
                switch loginStatus {
                case .enabled:            return "Registered. Moodpaper will launch at login."
                case .notRegistered:      return "Not registered"
                case .requiresApproval:   return "Requires user approval in System Settings"
                case .notFound:           return "App not found in login items"
                default:                  return "Unknown status"
                }
            }()
        ))

        // Spaces Sync observer
        let (syncEnabled, hasObs) = await MainActor.run {
            (wallpaperManager.syncAllSpaces, wallpaperManager.hasSpaceObserver)
        }
        results.append(DiagResult(
            name: "Spaces sync",
            status: !syncEnabled ? .info : (hasObs ? .pass : .fail),
            detail: !syncEnabled ? "Disabled in settings" : (hasObs ? "Observer active" : "Enabled but observer not registered")
        ))

        // Focus Mode
        let (focusEnabled, focusSlot) = await MainActor.run {
            (wallpaperManager.focusModeEnabled, wallpaperManager.focusSlot)
        }
        results.append(DiagResult(
            name: "Focus Mode",
            status: .info,
            detail: focusEnabled ? "Enabled: switches to \(focusSlot) during meetings" : "Disabled"
        ))

        // Vibe
        let activeMoodName = await MainActor.run { MoodStore.shared.activeMood?.name }
        results.append(DiagResult(
            name: "Vibe",
            status: .info,
            detail: activeMoodName.map { "\"\($0)\" is active" } ?? "No Vibe active"
        ))

        // Behavioral Engine
        let independentDisplaysAllowed = await MainActor.run { runtimeState.independentDisplaysAvailable }
        let usingIndependentDisplayMode = await MainActor.run {
            wallpaperManager.displayModes.values.contains(.independent)
        }
        results.append(DiagResult(
            name: "Independent displays gate",
            status: !usingIndependentDisplayMode || independentDisplaysAllowed ? .pass : .fail,
            detail: usingIndependentDisplayMode
                ? (independentDisplaysAllowed ? "Independent display mode is active and allowed" : "Independent display mode is stored but unavailable")
                : "Independent display mode is not active"
        ))

        let focusAvailable = await MainActor.run { runtimeState.focusModeAvailable }
        let slotSourceAvailable = await MainActor.run { runtimeState.slotSourceCustomizationAvailable }
        results.append(DiagResult(
            name: "Capability matrix",
            status: .info,
            detail: "Focus Mode: \(focusAvailable ? "available" : "unavailable"), Slot Sources: \(slotSourceAvailable ? "available" : "unavailable")"
        ))

        return results
    }

    // MARK: - Weather Checks

    private func checkWeather() async -> [DiagResult] {
        var results: [DiagResult] = []

        let weatherService = HorizonWeatherService.shared
        let locationService = LocationService.shared

        // Location availability
        let hasLocation = await MainActor.run { locationService.currentLocation != nil }
        results.append(DiagResult(
            name: "Location for weather",
            status: hasLocation ? .pass : .fail,
            detail: hasLocation
                ? "Location available: \(await MainActor.run { locationService.locationName })"
                : "No location available. Weather cannot be fetched."
        ))

        // Weather data availability
        let hasWeather = await MainActor.run { weatherService.currentWeather != nil }
        let isLoading = await MainActor.run { weatherService.isLoading }
        let weatherError = await MainActor.run { weatherService.error }
        let lastSuccessfulAt = await MainActor.run { weatherService.lastSuccessfulAt }

        if isLoading {
            results.append(DiagResult(
                name: "Weather data",
                status: .info,
                detail: "Currently loading weather data..."
            ))
        } else if let error = weatherError {
            results.append(DiagResult(
                name: "Weather data",
                status: hasWeather ? .warn : .fail,
                detail: hasWeather
                    ? "Last refresh failed; showing saved weather. Error: \(error.localizedDescription)"
                    : "Error: \(error.localizedDescription)"
            ))
        } else if hasWeather {
            let temp = await MainActor.run { weatherService.currentWeather?.temperatureFahrenheit ?? 0 }
            let condition = await MainActor.run { weatherService.currentWeather?.condition.rawValue ?? "unknown" }
            results.append(DiagResult(
                name: "Weather data",
                status: .pass,
                detail: "\(Int(temp))°F, \(condition)"
            ))
        } else {
            results.append(DiagResult(
                name: "Weather data",
                status: .warn,
                detail: "No weather data available yet. Moodpaper will fall back to time-based wallpaper changes."
            ))
        }

        // Data source
        let dataSource = await MainActor.run { weatherService.source }
        results.append(DiagResult(
            name: "Weather source",
            status: dataSource == "weatherkit" ? .pass : (dataSource == "open-meteo" ? .pass : .info),
            detail: dataSource == "weatherkit" ? "Using Apple WeatherKit"
                  : dataSource == "open-meteo" ? "Using Open-Meteo fallback (WeatherKit unavailable)"
                  : "No weather data fetched yet"
        ))

        results.append(DiagResult(
            name: "Last weather update",
            status: lastSuccessfulAt == nil ? .warn : .info,
            detail: lastSuccessfulAt?.formatted(date: .abbreviated, time: .standard) ?? "No successful weather update recorded"
        ))

        return results
    }

    // MARK: - Settings Checks

    private func checkSettings() async -> [DiagResult] {
        var results: [DiagResult] = []

        // Enabled slots
        let defaults = UserDefaults.standard
        var enabledCount = 0
        if let data = defaults.data(forKey: HorizonScheduleDefaults.slotEnabledKey) {
            do {
                let decoded = try JSONDecoder().decode([String: Bool].self, from: data)
                enabledCount = decoded.values.filter { $0 }.count
            } catch {
                print("[DiagnosticsView] Failed to decode slot enabled data: \(error)")
                enabledCount = 9 // default all enabled
            }
        } else {
            enabledCount = 9 // default all enabled
        }
        results.append(DiagResult(
            name: "Enabled time slots",
            status: enabledCount > 0 ? .pass : .fail,
            detail: "\(enabledCount) of 9 slots enabled"
        ))

        // Wallpapers per day
        let wpd = defaults.double(forKey: HorizonScheduleDefaults.wallpapersPerDayKey)
        let wpdInt = wpd == 0 ? 8 : Int(min(max(wpd, 1), 24))
        results.append(DiagResult(
            name: "Wallpapers per day",
            status: .pass,
            detail: "\(wpdInt) wallpapers/day, rotates every \(Int(86_400 / wpdInt / 60))m"
        ))

        // Smart Mode
        // DND setting
        let dnd = defaults.bool(forKey: "respectDoNotDisturb")
        results.append(DiagResult(
            name: "Respect Do Not Disturb",
            status: .info,
            detail: dnd ? "Enabled: wallpapers pause during Focus" : "Disabled"
        ))

        // Notify on slot change
        let notify = defaults.bool(forKey: HorizonScheduleDefaults.notifyOnSlotChangeKey)
        let notificationsAuthorized = await MainActor.run { runtimeState.notificationsAuthorized }
        results.append(DiagResult(
            name: "Slot change notifications",
            status: !notify || notificationsAuthorized ? .pass : .warn,
            detail: notify
                ? (notificationsAuthorized ? "Enabled and authorized" : "Enabled in settings, but notification permission is missing")
                : "Disabled"
        ))

        let migrationVersion = defaults.integer(forKey: "migrationVersion")
        results.append(DiagResult(
            name: "Preferences schema version",
            status: migrationVersion >= AppDelegate.UserDefaultsMigration.currentVersion ? .pass : .warn,
            detail: "Version \(migrationVersion) stored, expected \(AppDelegate.UserDefaultsMigration.currentVersion)"
        ))

        let shortcutsEnabled = await MainActor.run { runtimeState.shortcutsEnabledPreference }
        let shortcutsAuthorized = await MainActor.run { runtimeState.shortcutsAuthorized }
        results.append(DiagResult(
            name: "Keyboard shortcuts permission",
            status: !shortcutsEnabled || shortcutsAuthorized ? .pass : .warn,
            detail: shortcutsEnabled
                ? (shortcutsAuthorized ? "Enabled and authorized" : "Enabled in settings, but Accessibility permission is missing")
                : "Disabled"
        ))

        let locationAuthorized = await MainActor.run { runtimeState.locationAuthorized }
        let calendarAuthorized = await MainActor.run { runtimeState.calendarAuthorized }
        results.append(DiagResult(
            name: "Permission capability matrix",
            status: .info,
            detail: "Location: \(locationAuthorized ? "authorized" : "not authorized"), Calendar: \(calendarAuthorized ? "authorized" : "not authorized"), Notifications: \(notificationsAuthorized ? "authorized" : "not authorized"), Accessibility: \(shortcutsAuthorized ? "authorized" : "not authorized")"
        ))

        return results
    }

    // MARK: - Performance Checks

    private func checkPerformance() async -> [DiagResult] {
        var results: [DiagResult] = []

        let previewLast = await MainActor.run { performanceMetrics.lastPreviewDecodeDurationMs }
        let previewAverage = await MainActor.run { performanceMetrics.averagePreviewDecodeDurationMs }
        results.append(DiagResult(
            name: "Preview decode timing",
            status: previewAverage == nil ? .info : ((previewAverage ?? 0) < 120 ? .pass : .warn),
            detail: previewAverage == nil
                ? "No preview decode samples collected yet"
                : "Last \(Int((previewLast ?? 0).rounded())) ms, average \(Int((previewAverage ?? 0).rounded())) ms"
        ))

        let wallpaperLast = await MainActor.run { performanceMetrics.lastWallpaperApplyDurationMs }
        let wallpaperAverage = await MainActor.run { performanceMetrics.averageWallpaperApplyDurationMs }
        results.append(DiagResult(
            name: "Wallpaper apply timing",
            status: wallpaperAverage == nil ? .info : ((wallpaperAverage ?? 0) < 300 ? .pass : .warn),
            detail: wallpaperAverage == nil
                ? "No wallpaper apply samples collected yet"
                : "Last \(Int((wallpaperLast ?? 0).rounded())) ms, average \(Int((wallpaperAverage ?? 0).rounded())) ms"
        ))

        let rollbackCount = await MainActor.run { performanceMetrics.wallpaperRollbackCount }
        results.append(DiagResult(
            name: "Wallpaper rollback count",
            status: rollbackCount == 0 ? .pass : .warn,
            detail: "\(rollbackCount) rollback event(s) recorded this session"
        ))

        return results
    }
}

// MARK: - Actions Card

private struct DiagActionsCard: View {
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    @Binding var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("Test Actions")
                    .font(.system(size: 13, weight: .semibold))
            }

            if let msg = message {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            HStack(spacing: 10) {
                ActionButton(title: "Change Wallpaper Now", symbol: "photo.fill") {
                    wallpaperManager.skipToNext()
                    show("Wallpaper changed.")
                }

                ActionButton(title: "Force Slot Transition", symbol: "clock.arrow.circlepath") {
                    wallpaperManager.debugForceSlotTransition()
                    show("Slot transition triggered.")
                }

                ActionButton(title: "Send Test Notification", symbol: "bell.fill") {
                    sendTestNotification()
                }

                ActionButton(title: "Export Analytics", symbol: "square.and.arrow.down") {
                    exportAnalytics()
                }
            }

            HStack(spacing: 10) {
                ActionButton(title: "Share Diagnostics", symbol: "doc.zipper") {
                    exportDiagnostics()
                }

                #if DEBUG
                ActionButton(title: "Reset Onboarding", symbol: "arrow.counterclockwise.circle") {
                    resetOnboarding()
                }
                #endif
            }
        }
        .padding(16)
        .liquidGlassCard()
    }

    #if DEBUG
    private func resetOnboarding() {
        UserDefaults.standard.removeObject(forKey: "hasCompletedOnboarding")
        UserDefaults.standard.synchronize()
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            show("Onboarding flag cleared. Relaunch to see it.")
            return
        }
        // Close any stale onboarding window from a previous reset.
        appDelegate.onboardingWindow?.close()
        appDelegate.onboardingWindow = nil

        appDelegate.showOnboarding()

        // Moodpaper runs with .accessory activation policy, so a freshly created
        // window does not automatically come to the front when triggered from
        // inside an already-active window. Force it forward and activate.
        if let window = appDelegate.onboardingWindow {
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        show("Onboarding reset and reopened.")
    }
    #endif

    private func show(_ text: String) {
        withAnimation { message = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { message = nil }
        }
    }

    private func sendTestNotification() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                DispatchQueue.main.async { show("Notifications not authorized.") }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Moodpaper Diagnostics"
            content.body = "Test notification delivered successfully."
            content.sound = .none
            let request = UNNotificationRequest(identifier: "diag-test", content: content, trigger: nil)
            center.add(request)
            DispatchQueue.main.async { show("Test notification sent.") }
        }
    }

    private func exportAnalytics() {
        let csv = AnalyticsManager.shared.exportToCSV()
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.nameFieldStringValue = "horizon_analytics_\(Date().timeIntervalSince1970).csv"
        savePanel.begin { response in
            if response == .OK, let url = savePanel.url {
                do {
                    try csv.write(to: url, atomically: true, encoding: .utf8)
                    DispatchQueue.main.async { show("Analytics exported successfully.") }
                } catch {
                    DispatchQueue.main.async { show("Failed to export analytics: \(error.localizedDescription)") }
                }
            }
        }
    }

    private func exportDiagnostics() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "horizon_diagnostics_\(Int(Date().timeIntervalSince1970)).txt"
        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            let report = buildDiagnosticsReport()
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { show("Diagnostics exported successfully.") }
            } catch {
                DispatchQueue.main.async { show("Failed to export diagnostics: \(error.localizedDescription)") }
            }
        }
    }

    private func buildDiagnosticsReport() -> String {
        var lines: [String] = []
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"

        lines.append("Moodpaper Diagnostics")
        lines.append("Generated: \(Date().formatted(date: .complete, time: .complete))")
        lines.append("Version: \(version) (\(build))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("")
        lines.append("Runtime")
        lines.append("Weather source: \(HorizonWeatherService.shared.source)")
        lines.append("Last weather update: \(HorizonWeatherService.shared.lastSuccessfulAt?.formatted(date: .abbreviated, time: .standard) ?? "none")")
        lines.append("Last weather failure: \(HorizonWeatherService.shared.lastFailureDescription ?? "none")")
        lines.append("Focus preference: \(WallpaperManager.shared.focusModePreference)")
        lines.append("Focus enabled: \(WallpaperManager.shared.focusModeEnabled)")
        lines.append("In meeting: \(CalendarService.shared.isInMeeting)")
        lines.append("Calendar status: \(CalendarService.shared.authorizationStatus.rawValue)")
        lines.append("Location status: \(LocationService.shared.authorizationStatus.rawValue)")
        lines.append("Current wallpaper: \(WallpaperManager.shared.currentWallpaperName)")
        lines.append("")
        lines.append("Analytics")
        lines.append(AnalyticsManager.shared.exportToCSV())
        lines.append("")
        lines.append("Debug Log")
        if let log = try? String(contentsOf: HorizonDebugLog.shared.currentLogFile, encoding: .utf8), !log.isEmpty {
            lines.append(log)
        } else {
            lines.append("No debug log found. Enable Debug Logging before reproducing an issue for richer reports.")
        }

        return lines.joined(separator: "\n")
    }

    private struct ActionButton: View {
        let title: String
        let symbol: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - Debug Logging Card

private struct DebugLoggingCard: View {
    @AppStorage(HorizonScheduleDefaults.debugLoggingEnabledKey) private var enabled: Bool = false
    @State private var sizeText: String = ""
    @State private var statusMessage: String? = nil
    @State private var sizeTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("Debug Logging")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Text("Writes wallpaper and system events to ~/Library/Logs/Moodpaper/. Off by default. Safe to leave on while reproducing a bug; rotates daily and keeps 7 days.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if enabled {
                Text("Current log: \(sizeText.isEmpty ? "empty" : sizeText)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            if let msg = statusMessage {
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(HorizonDebugLog.shared.logsDirectory)
                } label: {
                    Label("Reveal Logs in Finder", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    HorizonDebugLog.shared.clear()
                    show("Logs cleared.")
                    refreshSize()
                } label: {
                    Label("Clear Logs", systemImage: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .liquidGlassCard()
        .onAppear {
            refreshSize()
            sizeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                refreshSize()
            }
        }
        .onDisappear {
            sizeTimer?.invalidate()
            sizeTimer = nil
        }
    }

    private func refreshSize() {
        let bytes = HorizonDebugLog.shared.currentLogSize
        if bytes == 0 {
            sizeText = ""
        } else {
            sizeText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }

    private func show(_ text: String) {
        withAnimation { statusMessage = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { statusMessage = nil }
        }
    }
}

// MARK: - Section View

private struct DiagSection: View {
    let title: String
    let results: [DiagResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    DiagRow(result: result)
                    if index < results.count - 1 {
                        Divider().opacity(0.3).padding(.leading, 46)
                    }
                }
            }
            .liquidGlassCard()
        }
    }
}

// MARK: - Row View

private struct DiagRow: View {
    let result: DiagResult

    var statusColor: Color {
        switch result.status {
        case .pass: return .green
        case .warn: return .orange
        case .fail: return .red
        case .info: return .secondary
        }
    }

    var statusSymbol: String {
        switch result.status {
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(result.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Analytics Check

private extension DiagnosticsView {
    func checkAnalytics() async -> [DiagResult] {
        var results: [DiagResult] = []
        let analytics = AnalyticsManager.shared

        // Total events
        results.append(DiagResult(
            name: "Total events logged",
            status: .info,
            detail: "\(analytics.events.count) events recorded"
        ))

        // Unique days active
        let uniqueDays = analytics.uniqueDaysActive()
        results.append(DiagResult(
            name: "Unique days active",
            status: uniqueDays > 0 ? .pass : .info,
            detail: "\(uniqueDays) days with app activity"
        ))

        // Onboarding completion rate
        let onboardingCount = analytics.eventCount(for: .onboardingCompleted)
        let launchCount = analytics.eventCount(for: .appLaunch)
        let completionRate = launchCount > 0 ? Double(onboardingCount) / Double(launchCount) : 0
        results.append(DiagResult(
            name: "Onboarding completion",
            status: completionRate > 0.8 ? .pass : completionRate > 0.5 ? .warn : .info,
            detail: "\(onboardingCount)/\(launchCount) launches (\(Int(completionRate * 100))%)"
        ))

        return results
    }
}

// MARK: - Summary Badge

private struct SummaryBadge: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text("\(count)")
                .font(.system(size: 18, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(color.opacity(0.2), lineWidth: 1)
                )
        )
    }
}
