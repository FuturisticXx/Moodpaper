import Foundation
import AppKit
import SwiftUI
import UserNotifications
import UniformTypeIdentifiers
internal import Combine

struct WallpaperHistoryEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let wallpaperName: String
    let wallpaperIdentifier: String?
    let wallpaperIdentifiersByScreen: [String: String]?
    let slotID: String
    let slotDisplayName: String
    let trigger: String?

    init(
        wallpaperName: String,
        wallpaperIdentifier: String? = nil,
        wallpaperIdentifiersByScreen: [String: String]? = nil,
        slotID: String,
        slotDisplayName: String,
        trigger: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.wallpaperName = wallpaperName
        self.wallpaperIdentifier = wallpaperIdentifier
        self.wallpaperIdentifiersByScreen = wallpaperIdentifiersByScreen
        self.slotID = slotID
        self.slotDisplayName = slotDisplayName
        self.trigger = trigger
    }

    var triggerDisplayName: String {
        Self.triggerDisplayName(for: trigger)
    }

    static func triggerDisplayName(for trigger: String?) -> String {
        switch trigger {
        case "scheduledTick": return "Schedule"
        case "moodChange": return "Mood"
        case "vibeChange": return "Mood"   // legacy persisted history entries
        case "activeSpaceDidChange": return "Space"
        case "manual", "restoreHistoryEntry": return "Manual"
        case .some(let value) where value.hasPrefix("weather"):
            // weatherUpdate, weatherReconcile, weatherSyncEnabled,
            // weatherSyncEnabledDeferred, weatherSyncEnabledTimeout,
            // weatherSyncDisabled — raw ids must never reach the history UI.
            return "Weather"
        case .some(let value) where !value.isEmpty:
            return value
        default:
            return "Auto"
        }
    }
}

enum HistoryRestoreResolution: Equatable {
    case resolved(resolvedIdentifiersByScreen: [String: String], primaryScreenName: String, primaryIdentifier: String)
    case failed
}

enum ReconciledWallpaperState: Equatable {
    case live(primaryName: String, primaryIdentifier: String, identifiersByScreen: [String: String])
    case storedFallback(primaryName: String, primaryIdentifier: String?)
}

enum DesktopApplyConfirmationDecision: Equatable {
    case waiting
    case confirmed
    case timedOut
}

nonisolated fileprivate struct SendableScreen: @unchecked Sendable {
    let value: NSScreen
}

nonisolated fileprivate struct WallpaperScreenApplyJob: @unchecked Sendable {
    let name: String
    let screen: SendableScreen
    let preparedURL: URL
    let options: [NSWorkspace.DesktopImageOptionKey: Any]
    let displayID: String
    let modeDescription: String
}

nonisolated fileprivate struct WallpaperScreenApplyResult: Sendable {
    let name: String
    let preparedURL: URL
    let preparedFilename: String
    let displayID: String
    let modeDescription: String
    let outcome: Result<Void, NSError>
    let startOffsetMs: Int
    let callDurationMs: Int
}

extension WallpaperManager {
    /// Returns the dwell interval the rotation engine should use right now,
    /// derived from the global wallpapersPerDay setting. Pure function — no
    /// state reads — so tests can lock the contract without touching
    /// singletons. Use `currentDwellInterval` from runtime code; this is
    /// the testable seam.
    static func dwellSeconds(
        globalWallpapersPerDay: Int
    ) -> TimeInterval {
        let safe = max(globalWallpapersPerDay, 1)
        return TimeInterval(86400 / safe)
    }

    /// Decides whether the system-reported desktop state has caught up with
    /// the URLs Moodpaper asked AppKit to apply. Kept pure so the synchronization
    /// contract can be tested without changing a real desktop wallpaper.
    static func desktopApplyConfirmationDecision(
        expectedURLsByScreen: [String: URL],
        liveURLsByScreen: [String: URL],
        elapsed: TimeInterval,
        timeout: TimeInterval
    ) -> DesktopApplyConfirmationDecision {
        let everyDisplayMatches = !expectedURLsByScreen.isEmpty && expectedURLsByScreen.allSatisfy { screenName, expectedURL in
            guard let liveURL = liveURLsByScreen[screenName] else { return false }
            return liveURL.standardizedFileURL.path == expectedURL.standardizedFileURL.path
        }

        if everyDisplayMatches { return .confirmed }
        if elapsed >= timeout { return .timedOut }
        return .waiting
    }

    /// Absolute times, measured from the setter returning, when Moodpaper
    /// should ask macOS whether every display has caught up. Each read crosses
    /// into WallpaperAgent, so checking every frame or every 100 ms can delay
    /// the change it is trying to observe. These checkpoints stay responsive
    /// around the normal completion window without flooding the system service.
    static func desktopApplyConfirmationCheckpoints(
        timeout: TimeInterval
    ) -> [TimeInterval] {
        guard timeout > 0 else { return [] }

        let preferredCheckpoints: [TimeInterval] = [0.5, 1.5, 3, 5, 7, 9, 12, 16]
        return preferredCheckpoints.filter { $0 < timeout } + [timeout]
    }
}

class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()

    /// Current dwell interval for automatic rotation. Routes through
    /// `dwellSeconds` so the rotation gate, diagnostics, and UI countdown
    /// all use the same source-of-truth math.
    var currentDwellInterval: TimeInterval {
        Self.dwellSeconds(
            globalWallpapersPerDay: wallpapersPerDayFromDefaults()
        )
    }

    @Published var currentWallpaperName: String = UserDefaults.standard.string(forKey: "currentWallpaperName") ?? ""
    @Published var isRunning: Bool = false
    @Published var displayModes: [String: DisplayMode] = [:]
    @Published var isChangingWallpaper: Bool = false
    @Published var lastError: String?
    @Published var history: [WallpaperHistoryEntry] = []
    @Published var isDNDActive: Bool = false
    @Published var nextChangeCountdown: String = "Soon"

    /// Single source of truth for the "current wallpaper preview" image
    /// rendered in the sidebar + dashboard surfaces. Previously each surface
    /// owned its own @State previewImage with a different set of refresh
    /// triggers (appDidBecomeActive, activeSpaceDidChange, didWake, etc.),
    /// so on triggers only some views observed, the surfaces drifted onto
    /// different wallpapers visually. With both views rendering this
    /// published image, they cannot disagree.
    @Published private(set) var currentPreviewImage: NSImage?
    /// The URL the published image was loaded from. Exposed so views can
    /// invalidate the loader cache for the right key on wake.
    private(set) var currentPreviewURL: URL?
    private var currentPreviewLoadToken: UUID?

    private var timer: Timer?
    private var countdownTimer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var screenParamsObserver: NSObjectProtocol?
    private var willSleepObserver: NSObjectProtocol?
    private var didWakeObserver: NSObjectProtocol?
    private var spaceDebounceTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastAppliedURL: URL?

    deinit {
        timer?.invalidate()
        countdownTimer?.invalidate()
        spaceDebounceTimer?.invalidate()
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = screenParamsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = willSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        cancellables.removeAll()
    }
    // Tracks what URL each screen SHOULD display. Updated on wallpaper change,
    // consulted on Space switch to reapply the correct wallpaper per-screen
    // (handles independent displays correctly).
    private var desiredURLPerScreen: [String: URL] = [:]
    private var lastSlot: String = ""
    private var lastWallpaperChangeAt: Date?
    private let userWallpaperManager = UserWallpaperManager.shared
    private let historyKey = "wallpaperHistory"
    private let displayModesKey = "schedule.displayModes"
    private let maxHistoryCount = 50
    private let lastWallpaperChangeAtKey = "lastWallpaperChangeAt"
    private let focusModeEnabledKey = "focus.enabled"
    private let focusSlotKey = "focus.slot"
    private let preparedWallpaperSourceMapKey = "preparedWallpaperSourceMap"
    private let currentWallpaperIdentifiersByScreenKey = "currentWallpaperIdentifiersByScreen"


    // HZN-003: Slot active during setWallpaper(url:), used for per-screen independent selection
    private var activeSlot: String = ""

    // HZN-006: Slot attributed to the in-flight wallpaper change, written before the change starts
    private var pendingHistorySlot: String = ""
    private var applyTriggerContext: String?

    // Tracks which Spaces have received the current wallpaper (keyed by Space UUID string)
    // Tracks how many unique Space visits have received the current wallpaper (for UI display only)
    @Published var coveredSpaceIDs: Set<String> = []

    // Track last space change time to prevent double-counting from rapid notifications
    private var lastSpaceChangeTime: Date = Date.distantPast
    private let currentWallpaperIdentifierKey = "currentWallpaperIdentifier"

    /// Exposed for Diagnostics: true when the space observer is registered
    var hasSpaceObserver: Bool { spaceObserver != nil }

    /// Exposed for Diagnostics: the timestamp of the most recent wallpaper change
    var lastWallpaperChangeDate: Date? { lastWallpaperChangeAt }

    // Monotonically incrementing counter that advances each time the active Space changes.
    // Used as a relative Space key for per-Space pinning. Not a macOS Space UUID.
    // macOS does not expose Space identifiers via public APIs.
    private var spaceVisitCounter: Int = 0

    // Per-Space slot pins, keyed by Space visit counter string ("0", "1", ...), value is slot ID
    // Stored in UserDefaults as JSON.
    private let spacePinsKey = "schedule.spacePins"

    var spacePins: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: spacePinsKey) else { return [:] }
            do {
                let decoded = try JSONDecoder().decode([String: String].self, from: data)
                return decoded
            } catch {
                print("[WallpaperManager] Failed to decode spacePins: \(error)")
                return [:]
            }
        }
        set {
            do {
                let encoded = try JSONEncoder().encode(newValue)
                UserDefaults.standard.set(encoded, forKey: spacePinsKey)
            } catch {
                print("[WallpaperManager] Failed to encode spacePins: \(error)")
            }
            objectWillChange.send()
        }
    }

    func setPinForSpace(_ spaceKey: String, slotID: String?) {
        var pins = spacePins
        if let slot = slotID {
            pins[spaceKey] = slot
        } else {
            pins.removeValue(forKey: spaceKey)
        }
        spacePins = pins
    }

    func pinnedSlot(forSpace spaceKey: String) -> String? {
        spacePins[spaceKey]
    }

    // Sync all Spaces: re-applies wallpaper whenever the active Space changes.
    // Defaults to true for never-touched users; explicit false stays false.
    var syncAllSpaces: Bool {
        get {
            UserDefaults.standard.object(forKey: HorizonScheduleDefaults.syncAllSpacesKey) as? Bool
                ?? HorizonScheduleDefaults.syncAllSpacesDefault
        }
        set {
            UserDefaults.standard.set(newValue, forKey: HorizonScheduleDefaults.syncAllSpacesKey)
            // Apply immediately when toggled on so the user sees the effect right away
            if newValue {
                reapplyDesiredWallpapers()
            }
        }
    }

    // Focus Mode: switches to a calm wallpaper slot during calendar meetings
    var focusModePreference: Bool {
        get { UserDefaults.standard.bool(forKey: focusModeEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: focusModeEnabledKey) }
    }

    var focusModeEnabled: Bool {
        get { focusModePreference }
        set { setFocusModeEnabled(newValue, reason: "focusModePreferenceChanged") }
    }

    var focusSlot: String {
        get { UserDefaults.standard.string(forKey: focusSlotKey) ?? "deep-night" }
        set { UserDefaults.standard.set(newValue, forKey: focusSlotKey) }
    }

    func setFocusModeEnabled(_ enabled: Bool, reason: String = "focusModePreferenceChanged") {
        let wasEnabled = focusModeEnabled
        focusModePreference = enabled
        let isEnabled = focusModeEnabled

        CalendarService.shared.reconcileRuntimeState(shouldMonitor: isEnabled, reason: reason)

        guard wasEnabled != isEnabled else { return }
        lastSlot = ""
        checkAndUpdateWallpaper()
    }

    var respectDoNotDisturb: Bool {
        get { UserDefaults.standard.bool(forKey: "respectDoNotDisturb") }
        set { UserDefaults.standard.set(newValue, forKey: "respectDoNotDisturb") }
    }

    var notifyOnSlotChange: Bool {
        get { UserDefaults.standard.bool(forKey: HorizonScheduleDefaults.notifyOnSlotChangeKey) }
        set { UserDefaults.standard.set(newValue, forKey: HorizonScheduleDefaults.notifyOnSlotChangeKey) }
    }

    init() {
        loadHistory()
        loadDisplayModes()
        loadLastWallpaperChangeDate()
        reconcileCurrentWallpaperState()
        refreshPreparedWallpaperStateIfNeeded()
        validateStateInvariants(context: "init")
        startEngine()
    }

    private func loadDisplayModes() {
        guard let data = UserDefaults.standard.data(forKey: displayModesKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            var modes: [String: DisplayMode] = [:]
            for (screen, raw) in decoded {
                if let mode = DisplayMode(rawValue: raw) {
                    modes[screen] = mode
                }
            }
            displayModes = modes
        } catch {
            print("[WallpaperManager] Failed to decode displayModes: \(error)")
        }
    }

    private func saveDisplayModes() {
        let raw = displayModes.mapValues { $0.rawValue }
        do {
            let data = try JSONEncoder().encode(raw)
            UserDefaults.standard.set(data, forKey: displayModesKey)
        } catch {
            print("[WallpaperManager] Failed to encode displayModes: \(error)")
        }
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([WallpaperHistoryEntry].self, from: data)
            history = decoded
        } catch {
            print("[WallpaperManager] Failed to decode history: \(error)")
        }
    }

    private func saveHistory() {
        do {
            let encoded = try JSONEncoder().encode(history)
            UserDefaults.standard.set(encoded, forKey: historyKey)
        } catch {
            print("[WallpaperManager] Failed to encode history: \(error)")
        }
    }

    private func addToHistory(
        wallpaperName: String,
        wallpaperIdentifier: String?,
        wallpaperIdentifiersByScreen: [String: String] = [:],
        slotID: String,
        trigger: String?
    ) {
        let slotDisplayName = HorizonScheduleSettings.timeSlots.first(where: { $0.id == slotID })?.title ?? slotID
        let entry = WallpaperHistoryEntry(
            wallpaperName: wallpaperName,
            wallpaperIdentifier: wallpaperIdentifier,
            wallpaperIdentifiersByScreen: wallpaperIdentifiersByScreen.isEmpty ? nil : wallpaperIdentifiersByScreen,
            slotID: slotID,
            slotDisplayName: slotDisplayName,
            trigger: trigger
        )

        history.insert(entry, at: 0)

        // Keep only last 50 entries
        if history.count > maxHistoryCount {
            history = Array(history.prefix(maxHistoryCount))
        }

        saveHistory()
    }

    private func loadLastWallpaperChangeDate() {
        if let storedDate = UserDefaults.standard.object(forKey: lastWallpaperChangeAtKey) as? Date {
            lastWallpaperChangeAt = storedDate
        }
    }

    private func saveLastWallpaperChangeDate() {
        UserDefaults.standard.set(lastWallpaperChangeAt, forKey: lastWallpaperChangeAtKey)
    }

    var todayHistory: [WallpaperHistoryEntry] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return history.filter { calendar.isDate($0.timestamp, inSameDayAs: today) }
    }

    func startEngine() {
        guard !isRunning else { return } // prevent duplicate observers on repeated calls
        isRunning = true
        CalendarService.shared.reconcileRuntimeState(shouldMonitor: focusModeEnabled, reason: "wallpaperEngineStart")

        // A mood switch must reflect on the desktop immediately, through a
        // coalesced refresh (one apply per user action, views never call
        // apply directly).
        MoodStore.shared.onActiveMoodChange = { [weak self] in
            self?.requestMoodStateRefresh()
        }

        checkAndUpdateWallpaper()

        CalendarService.shared.$isInMeeting
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self, self.focusModeEnabled else { return }
                self.lastSlot = ""
                self.checkAndUpdateWallpaper()
            }
            .store(in: &cancellables)

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.checkAndUpdateWallpaper()
        }

        // Countdown timer: the published string only changes by the minute,
        // so a 1Hz tick was burning 86,400 wakeups/day for at most 1,440
        // observable transitions. 10s keeps the UI within visual tolerance
        // (the displayed minute will roll within 10s of wall-clock truth)
        // while cutting wakeups 10x. Manual events (skip, mood activation)
        // call updateNextChangeCountdown() explicitly to keep
        // skip-driven updates feeling instant.
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.updateNextChangeCountdown()
        }

        HorizonDebugLog.shared.log("engine.start", fields: [
            "screens": NSScreen.screens.map { $0.localizedName }.joined(separator: ","),
            "screenCount": NSScreen.screens.count
        ])

        // Screen parameters change: display added/removed, resolution change, mirror toggle.
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            HorizonDebugLog.shared.log("screen.paramsChanged", fields: [
                "screens": NSScreen.screens.map { $0.localizedName }.joined(separator: ","),
                "screenCount": NSScreen.screens.count
            ])
        }

        // System sleep / wake — wallpaper state can drift across these transitions.
        willSleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            HorizonDebugLog.shared.log("system.willSleep")
        }
        didWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            HorizonDebugLog.shared.log("system.didWake", fields: [
                "screenCount": NSScreen.screens.count
            ])
            self?.reconcileRuntimeState(reason: "systemDidWake")
            self?.lastSlot = ""
            self?.checkAndUpdateWallpaper()
        }

        // Re-apply the current wallpaper whenever the user switches to a new Space.
        // macOS sets wallpaper per-Space: calling setDesktopImageURL only affects the
        // currently active Space, so we must call it again each time the Space changes.
        //
        // Important: macOS fires this notification 2-3 times per swipe (animation frames),
        // so we debounce 0.4 s and re-apply the SAME URL, never a new random image.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees we run on the main thread; the Sendable
            // closure type is the only reason we can't see main-actor state
            // directly. MainActor.assumeIsolated is the right hop here —
            // dropping it for Task { @MainActor in ... } added an async hop
            // per burst notification (3+ per swipe) for no behavior gain.
            // Matches the pattern documented in tasks/lessons.md 2026-05-10.
            MainActor.assumeIsolated {
                guard let self else { return }

                HorizonDebugLog.shared.log("space.change.received", fields: [
                    "visits": self.spaceVisitCounter,
                    "sinceLast": String(format: "%.3f", Date().timeIntervalSince(self.lastSpaceChangeTime))
                ])

                // Debounce: cancel any pending work and reschedule 0.25 s out.
                // All burst notifications from a single swipe collapse into one execution.
                guard self.syncAllSpaces else {
                    HorizonDebugLog.shared.log("space.change.skipped", fields: [
                        "reason": "noSync",
                        "syncAllSpaces": self.syncAllSpaces
                    ])
                    return
                }
                self.spaceDebounceTimer?.invalidate()
                self.spaceDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                    // Timer scheduled on the main run loop fires on main, so
                    // MainActor.assumeIsolated is sound here too.
                    MainActor.assumeIsolated {
                        guard let self else { return }

                        // Advance the visit counter for UI display and per-Space pin lookup
                        // Guard: cooldown prevents double-counting from rapid notifications (animation bursts)
                        guard Date().timeIntervalSince(self.lastSpaceChangeTime) > 0.5 else {
                            HorizonDebugLog.shared.log("space.change.debounced", fields: [
                                "reason": "cooldown"
                            ])
                            return
                        }
                        self.lastSpaceChangeTime = Date()
                        self.spaceVisitCounter += 1
                        let visitKey = "\(self.spaceVisitCounter)"
                        self.coveredSpaceIDs.insert(visitKey)

                        // Per-Space pin selects a specific slot, this IS a new wallpaper pick
                        if let pinnedSlot = self.pinnedSlot(forSpace: visitKey) {
                            HorizonDebugLog.shared.log("space.change.handled", fields: [
                                "path": "pinnedSlot",
                                "visitKey": visitKey,
                                "slot": pinnedSlot
                            ])
                            self.withApplyTrigger("activeSpaceDidChange") {
                                self.setWallpaperForSlot(pinnedSlot)
                            }
                            return
                        }

                        // Reapply the correct wallpaper per screen to the newly active Space.
                        // desiredURLPerScreen tracks what each screen should show, handling
                        // independent displays correctly. Falls back to setWallpaperForSlot
                        // only on first launch before any URL has been applied.
                        if !self.desiredURLPerScreen.isEmpty || self.lastAppliedURL != nil {
                            HorizonDebugLog.shared.log("space.change.handled", fields: [
                                "path": "reapply",
                                "visitKey": visitKey,
                                "desiredCount": self.desiredURLPerScreen.count
                            ])
                            self.withApplyTrigger("activeSpaceDidChange") {
                                self.reapplyDesiredWallpapers()
                            }
                        } else {
                            let slot = self.currentTimeSlot()
                            guard let resolvedSlot = self.resolvedSlotForSchedule(from: slot) else {
                                HorizonDebugLog.shared.log("space.change.handled", fields: [
                                    "path": "noSlot",
                                    "visitKey": visitKey
                                ])
                                return
                            }
                            HorizonDebugLog.shared.log("space.change.handled", fields: [
                                "path": "firstApply",
                                "visitKey": visitKey,
                                "slot": resolvedSlot
                            ])
                            self.withApplyTrigger("activeSpaceDidChange") {
                                self.setWallpaperForSlot(resolvedSlot)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Re-applies the desired wallpaper to every active screen when a Space
    /// change is detected or Spaces sync is toggled on.
    ///
    /// Uses `NSWorkspace.desktopImageURL(for:)` to read the ACTUAL wallpaper
    /// on the newly-active Space and skips screens that already match,
    /// avoiding redundant disk I/O.  `desiredURLPerScreen` ensures that
    /// independent displays get their own image reapplied (not the shared URL).
    private func reapplyDesiredWallpapers() {
        let screens = NSScreen.screens.filter { self.mode(for: $0.localizedName) != .off }
        guard !screens.isEmpty else { return }

        for screen in screens {
            // Look up the correct URL for this screen; fall back to the shared URL
            guard let targetURL = desiredURLPerScreen[screen.localizedName] ?? lastAppliedURL else { continue }

            // Ask macOS what this Space currently has — the source of truth
            if let currentURL = NSWorkspace.shared.desktopImageURL(for: screen),
               currentURL == targetURL {
                continue   // This Space already has the right wallpaper
            }

            do {
                try NSWorkspace.shared.setDesktopImageURL(targetURL, for: screen, options: desktopImageOptions(for: screen))
                HorizonDebugLog.shared.log("wallpaper.apply", fields: [
                    "trigger": applyTriggerContext ?? "activeSpaceDidChange",
                    "screen": screen.localizedName,
                    "displayID": displayIDString(for: screen),
                    "url": targetURL.lastPathComponent,
                    "slot": activeSlot.isEmpty ? "none" : activeSlot,
                    "mood": MoodStore.shared.activeMood?.name ?? "none",
                    "weather": HorizonWeatherService.shared.currentWeather?.condition.rawValue ?? "none"
                ])
                print("Horizon [Spaces sync]: Reapplied to \(screen.localizedName)")
            } catch {
                HorizonDebugLog.shared.log("wallpaper.apply.error", fields: [
                    "trigger": applyTriggerContext ?? "activeSpaceDidChange",
                    "screen": screen.localizedName,
                    "error": error.localizedDescription
                ])
                print("Horizon [Spaces sync]: Failed on \(screen.localizedName): \(error.localizedDescription)")
            }
        }
    }

    func stopEngine() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        countdownTimer?.invalidate()
        countdownTimer = nil
        spaceDebounceTimer?.invalidate()
        spaceDebounceTimer = nil
        if let observer = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceObserver = nil
        }
        if let observer = screenParamsObserver {
            NotificationCenter.default.removeObserver(observer)
            screenParamsObserver = nil
        }
        if let observer = willSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            willSleepObserver = nil
        }
        if let observer = didWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            didWakeObserver = nil
        }
        HorizonDebugLog.shared.log("engine.stop")
    }

    /// CGDirectDisplayID as a string, or "unknown". Used by debug logging.
    private func displayIDString(for screen: NSScreen) -> String {
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return "\(num.uint32Value)"
        }
        return "unknown"
    }

    // Called when wallpaper rotates to a new image, reset coverage count for UI
    private func resetSpaceCoverage() {
        coveredSpaceIDs.removeAll()
    }

    /// Called when the time slot mode changes (Detailed ↔ Simple) so the engine
    /// immediately re-evaluates which slot is active rather than waiting 60 seconds.
    func resetSlotAndRecheck() {
        lastSlot = ""
        checkAndUpdateWallpaper()
    }

    func checkAndUpdateWallpaper() {
        var tickFields: [String: Any] = [
            "lastSlot": lastSlot.isEmpty ? "none" : lastSlot,
            "isDND": isDNDActive,
            "focusMode": focusModeEnabled,
            "inMeeting": CalendarService.shared.isInMeeting,
            "nextChangeCountdown": nextChangeCountdown,
            "lastAppliedURL": lastAppliedURL?.lastPathComponent ?? "none",
            "lastAppliedByScreen": Self.debugURLSummary(desiredURLPerScreen)
        ]
        if let nextRotation = nextAutomaticRotationDate() {
            tickFields["nextAutomaticRotationAt"] = Self.debugTimestamp(nextRotation)
        } else {
            tickFields["nextAutomaticRotationAt"] = "pendingInitialApply"
        }
        HorizonDebugLog.shared.log("schedule.tick", fields: tickFields)
        // Pause Rotation is a lock: automatic and manual rotation requests
        // should leave the current wallpaper untouched.
        if !Self.shouldAllowWallpaperChange(
            pauseRotationEnabled: UserDefaults.standard.bool(forKey: HorizonScheduleDefaults.pauseRotationKey),
            userInitiated: false
        ) {
            HorizonLog("Horizon: Rotation paused, skipping wallpaper update")
            HorizonDebugLog.shared.log("schedule.skip", fields: ["reason": "paused"])
            return
        }

        // Respect Do Not Disturb: pause when system Focus/DND is active
        let focusMeetingActive = Self.shouldSuppressContextualWallpaperOverrides(
            focusModeEnabled: focusModeEnabled,
            isInMeeting: CalendarService.shared.isInMeeting
        )
        if Self.shouldSkipWallpaperUpdateForDND(
            isDNDActive: isDNDActive,
            respectDoNotDisturb: respectDoNotDisturb,
            focusMeetingActive: focusMeetingActive
        ) {
            print("Horizon: DND active, skipping wallpaper update")
            return
        }

        let baseSlot = currentTimeSlot()
        var effectiveSlot: String
        if focusMeetingActive {
            effectiveSlot = HorizonScheduleDefaults.validatedFocusSlot(
                preferred: focusSlot,
                mode: UserDefaults.standard.string(forKey: HorizonScheduleDefaults.timeSlotModeKey) ?? "Detailed"
            )
        } else {
            effectiveSlot = baseSlot
        }

        print("Horizon: base=\(baseSlot) effective=\(effectiveSlot)")

        guard let resolvedSlot = resolvedSlotForSchedule(from: effectiveSlot) else {
            print("Horizon: No enabled time slots. Skipping wallpaper update.")
            // Reset lastSlot to empty so we'll detect when slots become enabled again
            lastSlot = ""
            return
        }

        let slotChanged = resolvedSlot != lastSlot && !lastSlot.isEmpty
        // Treat empty lastSlot as a slot change to recover from reset states
        let needsInitialSet = lastSlot.isEmpty

        // Dwell interval is needed both by the launch-preservation check and
        // the rotation gate below; compute it once. Derives from the global
        // wallpapersPerDay setting. See dwellSeconds().
        let minimumInterval = currentDwellInterval

        // Launch preservation: lastSlot is in-memory only, so every launch
        // lands here with needsInitialSet — but a relaunch is not a reason to
        // rotate. If the persisted wallpaper still fits the current slot and
        // the persisted dwell clock hasn't expired, keep it and just repair
        // the bookkeeping.
        let persistedIdentifier = currentWallpaperIdentifier()
        let preservePersistedAtLaunch = needsInitialSet && Self.shouldPreservePersistedWallpaperAtLaunch(
            hasPersistedWallpaper: persistedIdentifier != nil,
            persistedWallpaperSlot: nil,
            resolvedSlot: resolvedSlot,
            secondsSinceLastChange: lastWallpaperChangeAt.map { Date().timeIntervalSince($0) },
            minimumInterval: minimumInterval
        )
        if preservePersistedAtLaunch {
            lastSlot = resolvedSlot
            HorizonDebugLog.shared.log("schedule.launchPreserve", fields: [
                "persisted": persistedIdentifier ?? "none",
                "slot": resolvedSlot
            ])
        }

        // Entering a new time slot: switch immediately, ignoring the
        // frequency interval.
        if (slotChanged || needsInitialSet) && !preservePersistedAtLaunch {
            if slotChanged {
                sendSlotChangeNotification(for: resolvedSlot)
            }
            lastSlot = resolvedSlot
            pendingHistorySlot = resolvedSlot  // HZN-006: recorded in setWallpaper on success
            withApplyTrigger("scheduledTick") {
                setWallpaperForSlot(
                    resolvedSlot,
                    ignoreMood: focusMeetingActive,
                    suppressContextualOverrides: focusMeetingActive
                )
            }
            return
        }

        let now = Date()
        let shouldRotate: Bool
        if let lastChange = lastWallpaperChangeAt {
            shouldRotate = now.timeIntervalSince(lastChange) >= minimumInterval
        } else {
            shouldRotate = true
        }

        guard shouldRotate else { return }

        lastSlot = resolvedSlot
        pendingHistorySlot = resolvedSlot  // HZN-006: recorded in setWallpaper on success
        withApplyTrigger("scheduledTick") {
            setWallpaperForSlot(
                resolvedSlot,
                ignoreMood: focusMeetingActive,
                suppressContextualOverrides: focusMeetingActive
            )
        }
    }

    private func withApplyTrigger(_ trigger: String, _ work: () -> Void) {
        let previous = applyTriggerContext
        applyTriggerContext = trigger
        defer { applyTriggerContext = previous }
        work()
    }

    private func nextAutomaticRotationDate() -> Date? {
        guard let lastWallpaperChangeAt else { return nil }
        // Same source-of-truth as the rotation gate and the UI countdown.
        return lastWallpaperChangeAt.addingTimeInterval(currentDwellInterval)
    }

    private func wallpapersPerDayFromDefaults() -> Int {
        let defaults = UserDefaults.standard
        let stored = defaults.double(forKey: HorizonScheduleDefaults.wallpapersPerDayKey)
        if stored == 0 {
            return 8
        }

        return Int(min(max(stored, 1), 48))
    }

    func skipToPrevious() {
        // Walk history (newest-first) to find the most recent entry that differs from current
        guard let previousEntry = history.first(where: {
            !currentWallpaperStateMatches($0)
        }) else {
            lastError = "No previous wallpaper is available yet."
            return
        }
        setWallpaper(historyEntry: previousEntry)
        lastWallpaperChangeAt = Date()
    }

    func skipToNext(trigger: String = "manual") {
        guard Self.shouldAllowWallpaperChange(
            pauseRotationEnabled: UserDefaults.standard.bool(forKey: HorizonScheduleDefaults.pauseRotationKey),
            userInitiated: true
        ) else { return }

        let currentWallpaperSlot = currentTimeSlot()

        let focusMeetingActive = Self.shouldSuppressContextualWallpaperOverrides(
            focusModeEnabled: focusModeEnabled,
            isInMeeting: CalendarService.shared.isInMeeting
        )
        let effectiveSlot = focusMeetingActive
            ? HorizonScheduleDefaults.validatedFocusSlot(
                preferred: focusSlot,
                mode: UserDefaults.standard.string(forKey: HorizonScheduleDefaults.timeSlotModeKey) ?? "Detailed"
            )
            : currentWallpaperSlot
        guard let resolvedSlot = resolvedSlotForSchedule(from: effectiveSlot) else {
            print("Horizon: No enabled time slots. Skipping manual skip.")
            return
        }


        pendingHistorySlot = resolvedSlot  // HZN-006
        withApplyTrigger(trigger) {
            setWallpaperForSlot(
                resolvedSlot,
                ignoreMood: focusMeetingActive,
                suppressContextualOverrides: focusMeetingActive
            )
        }
        // Bookkeeping must track the WALL-CLOCK slot, not the pool the skip
        // pulled from. resolvedSlot follows the current wallpaper's manifest
        // slot (pool continuity for selection), but writing it into lastSlot
        // corrupts the tick's slot-transition detector: after a chaos-mode
        // skip landed a midday wallpaper at 10 PM, the next 60s tick read
        // lastSlot=midday vs evening, declared a phantom slot transition, and
        // rotated the wallpaper the user had just picked.
        lastSlot = Self.postSkipLastSlot(
            selectionSlot: resolvedSlot,
            timeBasedSlot: resolvedSlotForSchedule(from: currentTimeSlot()),
            focusMeetingActive: focusMeetingActive
        )
        lastWallpaperChangeAt = Date()
    }

    /// The lastSlot value a manual skip should record. During a focus meeting
    /// the tick compares against the focus slot (which IS the selection slot);
    /// otherwise it compares against the wall-clock slot, so that is what must
    /// be stored regardless of which pool the skip selected from.
    static func postSkipLastSlot(
        selectionSlot: String,
        timeBasedSlot: String?,
        focusMeetingActive: Bool
    ) -> String {
        if focusMeetingActive { return selectionSlot }
        return timeBasedSlot ?? selectionSlot
    }

    /// Skips to another wallpaper, ignoring the frequency schedule.
    /// Used by the ⌥⌘R global shortcut. With the bundled library gone this
    /// is the same as a manual skip through the user's own pools.
    func skipToRandom() {
        skipToNext()
    }

    private var moodRefreshScheduled = false

    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Single entry point for "active mood changed, reflect it on the
    /// desktop now". Owned by MoodStore.onActiveMoodChange so every switch
    /// refreshes symmetrically — views must never call applyMoodChange
    /// directly (lessons.md 2026-05-25). Coalesced per runloop tick: one
    /// user action must produce exactly ONE apply.
    func requestMoodStateRefresh() {
        guard !Self.isRunningUnderXCTest else { return }
        guard !moodRefreshScheduled else { return }
        moodRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.moodRefreshScheduled = false
            self.applyMoodChange()
        }
    }

    /// Called when the active mood changes — picks a wallpaper from the new
    /// mood's pool for the current slot.
    func applyMoodChange() {
        let slot = currentTimeSlot()
        guard let resolvedSlot = resolvedSlotForSchedule(from: slot) else { return }
        pendingHistorySlot = resolvedSlot
        withApplyTrigger("moodChange") {
            setWallpaperForSlot(resolvedSlot, ignoreMood: false)
        }
        lastSlot = resolvedSlot
        lastWallpaperChangeAt = Date()
    }

    /// Diagnostics: clears lastSlot so the next checkAndUpdateWallpaper() call
    /// treats it as a slot transition and forces an immediate wallpaper change.
    func debugForceSlotTransition() {
        lastSlot = ""
        lastWallpaperChangeAt = nil
        checkAndUpdateWallpaper()
    }

    func currentTimeSlot() -> String {
        let isSimple = UserDefaults.standard.string(forKey: HorizonScheduleDefaults.timeSlotModeKey) == "Simple"
        if isSimple {
            return currentSimpleTimeSlot()
        }
        return currentDetailedTimeSlot()
    }

    private func currentSimpleTimeSlot() -> String {
        let cal = Calendar.current
        let now = Date()
        let nowMins = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let location = LocationService.shared
        let riseMins: Int
        let setMins: Int
        if let sunrise = location.sunriseTime, let sunset = location.sunsetTime {
            riseMins = cal.component(.hour, from: sunrise) * 60 + cal.component(.minute, from: sunrise)
            setMins  = cal.component(.hour, from: sunset)  * 60 + cal.component(.minute, from: sunset)
        } else {
            riseMins = 6 * 60
            setMins  = 18 * 60
        }
        switch nowMins {
        case riseMins..<(12 * 60): return "morning"
        case (12 * 60)..<setMins:  return "afternoon"
        default:                   return "evening"
        }
    }

    private func currentDetailedTimeSlot() -> String {
        let now = Date()
        let cal = Calendar.current

        // HZN-002: Use real sunrise/sunset times when available
        let location = LocationService.shared
        if let sunrise = location.sunriseTime, let sunset = location.sunsetTime {
            let nowMins  = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
            let riseMins = cal.component(.hour, from: sunrise) * 60 + cal.component(.minute, from: sunrise)
            let setMins  = cal.component(.hour, from: sunset)  * 60 + cal.component(.minute, from: sunset)

            let dawnStart       = max(0, riseMins - 90)
            let sunriseStart    = max(0, riseMins - 30)
            let morningStart    = riseMins + 30
            let goldenHourStart = max(morningStart, setMins - 60)
            let duskStart       = setMins
            let eveningStart    = HorizonScheduleDefaults.eveningStartMinutes(duskStart: duskStart)

            switch nowMins {
            case ..<dawnStart:                        return "deep-night"
            case dawnStart..<sunriseStart:            return "dawn"
            case sunriseStart..<morningStart:         return "sunrise"
            case morningStart..<(12 * 60):            return "morning"
            case (12 * 60)..<(15 * 60):               return "midday"
            case (15 * 60)..<goldenHourStart:         return "afternoon"
            case goldenHourStart..<duskStart:         return "golden-hour"
            case duskStart..<eveningStart:            return "dusk"
            default:                                  return "evening"
            }
        }

        // Fallback to fixed hours when solar data is unavailable
        let hour = cal.component(.hour, from: now)
        switch hour {
        case 0..<4:   return "deep-night"
        case 4..<6:   return "dawn"
        case 6..<8:   return "sunrise"
        case 8..<12:  return "morning"
        case 12..<15: return "midday"
        case 15..<17: return "afternoon"
        case 17..<20: return "golden-hour"
        case 20..<22: return "dusk"
        default:      return "evening"
        }
    }

    /// Returns minutes until the next slot boundary, respecting the current time slot mode.
    func minutesUntilNextSlotChange() -> Int {
        let isSimple = UserDefaults.standard.string(forKey: HorizonScheduleDefaults.timeSlotModeKey) == "Simple"
        let cal = Calendar.current
        let now = Date()
        let nowMins = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)

        if isSimple {
            let location = LocationService.shared
            let riseMins: Int
            let setMins: Int
            if let sunrise = location.sunriseTime, let sunset = location.sunsetTime {
                riseMins = cal.component(.hour, from: sunrise) * 60 + cal.component(.minute, from: sunrise)
                setMins  = cal.component(.hour, from: sunset)  * 60 + cal.component(.minute, from: sunset)
            } else {
                riseMins = 6 * 60
                setMins  = 18 * 60
            }
            let boundaries = [riseMins, 12 * 60, setMins, 24 * 60]
            let next = boundaries.first(where: { $0 > nowMins }) ?? 24 * 60
            return next - nowMins
        }

        // Detailed mode: use solar boundaries when available
        let location = LocationService.shared
        if let sunrise = location.sunriseTime, let sunset = location.sunsetTime {
            let riseMins = cal.component(.hour, from: sunrise) * 60 + cal.component(.minute, from: sunrise)
            let setMins  = cal.component(.hour, from: sunset)  * 60 + cal.component(.minute, from: sunset)
            let dawnStart       = max(0, riseMins - 90)
            let sunriseStart    = max(0, riseMins - 30)
            let morningStart    = riseMins + 30
            let goldenHourStart = max(morningStart, setMins - 60)
            let duskStart       = setMins
            let eveningStart    = HorizonScheduleDefaults.eveningStartMinutes(duskStart: duskStart)
            let boundaries      = [dawnStart, sunriseStart, morningStart, 12 * 60, 15 * 60, goldenHourStart, duskStart, eveningStart, 24 * 60]
            let next = boundaries.first(where: { $0 > nowMins }) ?? 24 * 60
            return next - nowMins
        }

        // Fallback fixed boundaries
        let boundaries = [4 * 60, 6 * 60, 8 * 60, 12 * 60, 15 * 60, 17 * 60, 20 * 60, 22 * 60, 24 * 60]
        let next = boundaries.first(where: { $0 > nowMins }) ?? 24 * 60
        return next - nowMins
    }

    /// Updates the nextChangeCountdown property with the current calculated value
    func updateNextChangeCountdown() {
        // Show whichever comes first — next slot boundary or frequency interval.
        let slotMins = minutesUntilNextSlotChange()
        let slotSecs = slotMins * 60

        // Same source-of-truth as the rotation gate and diagnostics.
        let interval = currentDwellInterval
        let freqSecs: Int
        if let last = lastWallpaperChangeDate {
            let rem = last.addingTimeInterval(interval).timeIntervalSinceNow
            freqSecs = rem > 0 ? Int(rem) : 0
        } else {
            freqSecs = Int(interval)
        }

        let secs = min(slotSecs, freqSecs)
        guard secs > 0 else {
            setNextChangeCountdown("Now")
            return
        }
        let mins = secs / 60
        setNextChangeCountdown(mins < 60 ? "\(mins)m" : "\(mins / 60)h \(mins % 60)m")
    }

    private func setNextChangeCountdown(_ value: String) {
        guard Self.shouldPublishCountdownUpdate(current: nextChangeCountdown, next: value) else { return }
        nextChangeCountdown = value
    }

    func setWallpaperForSlot(
        _ slot: String,
        ignoreMood: Bool = false,
        suppressContextualOverrides: Bool = false
    ) {
        activeSlot = slot  // HZN-003: captured by setWallpaper(url:) for independent display mode

        // Selection reads the active Mood's slot-specific pool first, then
        // falls back to its shared All Day pool. The user decides the mood;
        // the engine only remembers it.
        guard let url = moodWallpaperURL(for: slot) else {
            // Empty-slot rule: keep whatever is on screen until a slot that
            // has images comes around. Never an error — an empty slot is a
            // normal state for a mood the user is still filling in.
            print("Horizon: Mood slot \(slot) has no images. Holding current wallpaper.")
            return
        }
        setWallpaper(url: url)
    }

    /// Random pick from the active Mood's effective pool for `slot`, or nil
    /// when both the slot and All Day are empty (the caller holds the current
    /// wallpaper). Single source of truth for primary and independent picks.
    private func moodWallpaperURL(for slot: String) -> URL? {
        let timeSlot = timeSlotFromString(slot)
        let pool = MoodStore.shared.activeMood.map {
            MoodStore.shared.effectiveWallpapers(for: timeSlot, in: $0).map(\.path)
        } ?? []
        switch Self.resolveWallpaperSource(moodPoolIsEmpty: pool.isEmpty) {
        case .holdCurrent: return nil
        case .moodPool:    return resolveWallpaperURL(from: pool)
        }
    }

    private func timeSlotFromString(_ slot: String) -> TimeSlot {
        switch slot {
        case "deep-night": return .deepNight
        case "dawn": return .dawn
        case "sunrise": return .sunrise
        case "morning": return .morning
        case "midday": return .midday
        case "afternoon": return .afternoon
        case "golden-hour": return .goldenHour
        case "dusk": return .dusk
        case "evening": return .evening
        default: return .morning
        }
    }

    /// Resolves either a bundled wallpaper name or a user-added absolute file path.
    private func wallpaperURL(for identifier: String) -> URL? {
        if identifier.hasPrefix("/") {
            let fileURL = URL(fileURLWithPath: identifier)
            return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
        }
        return bundleURL(for: identifier)
    }

    /// Picks a random URL from `pool`, filtering out any wallpaper identifiers that
    /// no longer resolve. This supports both bundled wallpaper names and absolute
    /// file paths for user-imported wallpapers.
    private func resolveWallpaperURL(from pool: [String]) -> URL? {
        let validPool = pool.filter { wallpaperURL(for: $0) != nil }
        guard !validPool.isEmpty else { return nil }
        // validPool is non-empty here, so randomElement() can only return nil
        // under a future refactor that drops the guard above. Fall back to the
        // first element rather than force-unwrap so a regression can't crash
        // the wallpaper engine.
        return wallpaperURL(for: validPool.randomElement() ?? validPool[0])
    }

    private func bundleURL(for name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "jpg") ??
        Bundle.main.url(forResource: name, withExtension: "jpeg") ??
        Bundle.main.url(forResource: name, withExtension: "png")
    }

    // MARK: - Dwell tracking

    func exportWallpaper(named imageName: String) {
        guard let url = Bundle.main.url(forResource: imageName, withExtension: "jpg") ??
                        Bundle.main.url(forResource: imageName, withExtension: "jpeg") ??
                        Bundle.main.url(forResource: imageName, withExtension: "png") else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.jpeg]
        panel.begin { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                print("[WallpaperManager] Failed to export wallpaper: \(error)")
            }
        }
    }

    func setWallpaper(named imageName: String) {
        guard let url = Bundle.main.url(forResource: imageName, withExtension: "jpg") ??
                        Bundle.main.url(forResource: imageName, withExtension: "jpeg") ??
                        Bundle.main.url(forResource: imageName, withExtension: "png") else {
            let errorMsg = "Could not find wallpaper: \(imageName)"
            print("Horizon: \(errorMsg)")
            DispatchQueue.main.async {
                self.lastError = errorMsg
            }
            return
        }
        setWallpaperManually(url: url)
    }

    /// User-initiated "Set as Current" (Library cards, focus
    /// picker). Unlike the raw `setWallpaper(url:)` — whose callers stage
    /// `pendingHistorySlot` themselves or deliberately leave it empty for
    /// system-initiated applies — this records the change in Recent History
    /// under the current slot with a manual trigger, so a wallpaper the user
    /// explicitly picked shows up in history and Previous can return to it.
    func setWallpaperManually(url: URL) {
        let slot = currentTimeSlot()
        pendingHistorySlot = resolvedSlotForSchedule(from: slot) ?? slot
        withApplyTrigger("manual") {
            setWallpaper(url: url)
        }
    }

    func setWallpaper(identifier: String) {
        guard let url = wallpaperURL(for: identifier) else {
            let errorMsg = "Could not find wallpaper: \(identifier)"
            print("Horizon: \(errorMsg)")
            DispatchQueue.main.async {
                self.lastError = errorMsg
            }
            return
        }
        setWallpaper(url: url)
    }

    func setWallpaper(historyEntry: WallpaperHistoryEntry) {
        guard let identifiersByScreen = historyEntry.wallpaperIdentifiersByScreen, !identifiersByScreen.isEmpty else {
            setWallpaper(identifier: storedIdentifier(for: historyEntry))
            return
        }

        setWallpapers(identifiersByScreen: identifiersByScreen)
    }

    /// Sets the given wallpaper and pauses automatic rotation so it stays indefinitely.
    func lockWallpaper(named imageName: String) {
        setWallpaper(named: imageName)
        UserDefaults.standard.set(true, forKey: HorizonScheduleDefaults.pauseRotationKey)
        objectWillChange.send()
    }

    func setWallpaper(url: URL) {
        // Re-entrancy guard: under the previous synchronous applyWallpapers,
        // rapid repeated calls (Skip-spamming) serialized through main and
        // were naturally ordered. With the apply now async, two overlapping
        // calls could race the file-prepare and rollback paths against each
        // other. Drop the second request rather than queue it — the user
        // doesn't want machine-gun wallpaper changes anyway.
        guard !isChangingWallpaper else {
            print("[WallpaperManager] Wallpaper change already in progress; skipping duplicate request")
            return
        }

        lastAppliedURL = url
        isChangingWallpaper = true
        lastError = nil
        let source = url.path.hasPrefix(Bundle.main.bundleURL.path) ? "bundled" : "user"
        AnalyticsManager.shared.log(.wallpaperChanged, metadata: ["source": source])

        // HZN-003: Exclude screens with display mode set to .off
        let screens = NSScreen.screens.filter { self.mode(for: $0.localizedName) != .off }
        guard !screens.isEmpty else {
            let errorMsg = "No displays detected"
            print("Horizon: \(errorMsg)")
            self.lastError = errorMsg
            self.isChangingWallpaper = false
            return
        }

        let slotSnapshot = activeSlot  // HZN-003: captured for closures
        var sourceURLsByScreen: [String: URL] = [:]

        for screen in screens {
            if self.mode(for: screen.localizedName) == .independent,
               !slotSnapshot.isEmpty,
               let independentURL = self.moodWallpaperURL(for: slotSnapshot),
               independentURL != url {
                sourceURLsByScreen[screen.localizedName] = independentURL
            } else {
                sourceURLsByScreen[screen.localizedName] = url
            }
        }

        let primaryIdentifier = self.identifier(for: url)
        let primaryName = url.deletingPathExtension().lastPathComponent
        // Snapshot ambient state synchronously so the trigger/pending-slot
        // values we use inside the Task can't be mutated by an outer
        // withApplyTrigger defer or by another caller racing in.
        let trigger = applyTriggerContext ?? "manual"
        let pendingSlot = self.pendingHistorySlot

        // Multi-MB file preparation moves off the main thread inside
        // applyWallpapers. Apple's desktop-image getter and setter remain on
        // the main actor, as required by AppKit.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let applied = await self.applyWallpapers(
                sourceURLsByScreen: sourceURLsByScreen,
                trigger: trigger,
                slotSnapshot: slotSnapshot
            )
            self.isChangingWallpaper = false

            guard applied else { return }

            var identifiersByScreen: [String: String] = [:]
            for (screenName, sourceURL) in sourceURLsByScreen {
                identifiersByScreen[screenName] = self.identifier(for: sourceURL)
            }

            if primaryName != self.currentWallpaperName {
                self.resetSpaceCoverage()
            }
            self.persistWallpaperState(
                primaryName: primaryName,
                primaryIdentifier: primaryIdentifier,
                identifiersByScreen: identifiersByScreen
            )
            self.validateStateInvariants(context: "setWallpaper")
            // HZN-006: Record history and timestamp only after confirmed successful change
            self.lastWallpaperChangeAt = Date()
            self.saveLastWallpaperChangeDate()
            self.updateNextChangeCountdown()
            // Refresh the shared preview image so sidebar + dashboard cards
            // pick up the new wallpaper from one source. Without this,
            // each view's own .onChange(of: currentWallpaperName) trigger
            // raced and the two surfaces could publish at different times.
            // Pass the just-applied URL as authoritative so a lagging
            // NSWorkspace.desktopImageURL read can't freeze the preview on the
            // previous wallpaper (the stale Lake-Tahoe-over-rain bug).
            self.refreshCurrentPreview(forceReload: true, authoritativeURL: url)
            if !pendingSlot.isEmpty {
                self.addToHistory(
                    wallpaperName: primaryName,
                    wallpaperIdentifier: primaryIdentifier,
                    wallpaperIdentifiersByScreen: identifiersByScreen,
                    slotID: pendingSlot,
                    trigger: trigger
                )
                // Only clear pendingHistorySlot if it hasn't been overwritten
                // by a newer queued change while we were awaiting the apply.
                if self.pendingHistorySlot == pendingSlot {
                    self.pendingHistorySlot = ""
                }
            }
        }
    }

    private func setWallpapers(identifiersByScreen: [String: String]) {
        // Same re-entrancy guard as setWallpaper(url:) — a history restore
        // racing a normal change would corrupt isChangingWallpaper bookkeeping.
        guard !isChangingWallpaper else {
            print("[WallpaperManager] Wallpaper change already in progress; skipping history restore")
            return
        }

        isChangingWallpaper = true
        lastError = nil

        let screens = NSScreen.screens.filter { self.mode(for: $0.localizedName) != .off }
        guard !screens.isEmpty else {
            lastError = "No displays detected"
            isChangingWallpaper = false
            return
        }

        let primaryScreenName = preferredDesktopScreen()?.localizedName ?? screens[0].localizedName
        let resolution = Self.resolveHistoryRestore(
            storedIdentifiersByScreen: identifiersByScreen,
            activeScreenNames: screens.map(\.localizedName),
            primaryScreenName: primaryScreenName
        )

        guard case .resolved(let resolvedIdentifiersByScreen, let resolvedPrimaryScreenName, let primaryIdentifier) = resolution else {
            lastError = "Failed to restore wallpaper history."
            isChangingWallpaper = false
            return
        }

        var resolvedSourceURLs: [String: URL] = [:]
        for (screenName, identifier) in resolvedIdentifiersByScreen {
            guard let sourceURL = wallpaperURL(for: identifier) else {
                lastError = "Failed to restore wallpaper history."
                isChangingWallpaper = false
                return
            }
            resolvedSourceURLs[screenName] = sourceURL
        }

        let primaryURL = resolvedSourceURLs[resolvedPrimaryScreenName] ?? resolvedSourceURLs[screens[0].localizedName] ?? resolvedSourceURLs.values.first!
        let primaryName = displayName(for: primaryURL)
        let slotSnapshot = activeSlot
        // Keep lastAppliedURL current on the restore path too — the stale-read
        // guard in syncCurrentWallpaperWithDesktop compares against it, so a
        // restore that skipped this update would let a lagging desktop read
        // overwrite the just-restored identity (same bug as the Skip path).
        lastAppliedURL = primaryURL

        Task { @MainActor [weak self] in
            guard let self else { return }
            let applied = await self.applyWallpapers(
                sourceURLsByScreen: resolvedSourceURLs,
                trigger: "restoreHistoryEntry",
                slotSnapshot: slotSnapshot
            )
            self.isChangingWallpaper = false
            guard applied else { return }

            self.persistWallpaperState(
                primaryName: primaryName,
                primaryIdentifier: primaryIdentifier,
                identifiersByScreen: resolvedSourceURLs.mapValues { self.identifier(for: $0) }
            )
            self.validateStateInvariants(context: "restoreHistoryEntry")
        }
    }

    @MainActor
    private func applyWallpapers(
        sourceURLsByScreen: [String: URL],
        trigger: String,
        slotSnapshot: String
    ) async -> Bool {
        let applyStart = CFAbsoluteTimeGetCurrent()
        let screens = NSScreen.screens.filter { self.mode(for: $0.localizedName) != .off }

        // Set up prepared directory on main (creates if missing).
        let preparedDirectory: URL
        do {
            preparedDirectory = try preparedWallpaperDirectory()
        } catch {
            let errorMsg = "Failed to prepare wallpaper directory: \(error.localizedDescription)"
            HorizonDebugLog.shared.log("wallpaper.prepare.error", fields: [
                "trigger": trigger,
                "error": error.localizedDescription
            ])
            print("Horizon: \(errorMsg)")
            self.lastError = errorMsg
            return false
        }

        // Snapshot previous URLs (for rollback) and source map BEFORE going
        // off-main — NSScreen and NSWorkspace lookups belong on main.
        var previousURLsByScreen: [String: URL] = [:]
        for screen in screens {
            guard sourceURLsByScreen[screen.localizedName] != nil else { continue }
            if let previousURL = NSWorkspace.shared.desktopImageURL(for: screen) {
                previousURLsByScreen[screen.localizedName] = previousURL
            }
        }
        let sourceMap = sourceURLsByScreen

        // Off-main: prepare each wallpaper file (copy + prune stale fingerprints).
        // This is the step that beach-balled the main thread on multi-display
        // skip — a fresh wallpaper meant a multi-MB synchronous copy per
        // screen. Synchronized displays share a source URL, so we dedupe
        // before doing work.
        let preparedResults: [String: Result<URL, NSError>] = await Task.detached(priority: .userInitiated) {
            var preparedBySource: [URL: Result<URL, NSError>] = [:]
            var results: [String: Result<URL, NSError>] = [:]
            for (screenName, sourceURL) in sourceMap {
                if let cached = preparedBySource[sourceURL] {
                    results[screenName] = cached
                    continue
                }
                let result: Result<URL, NSError>
                do {
                    let preparedURL = try Self.prepareWallpaperFile(
                        sourceURL: sourceURL,
                        preparedDirectory: preparedDirectory
                    )
                    result = .success(preparedURL)
                } catch let error as NSError {
                    result = .failure(error)
                }
                preparedBySource[sourceURL] = result
                results[screenName] = result
            }
            return results
        }.value

        // Back on main: collect prepared URLs and update the on-disk source map.
        var preparedURLsByScreen: [String: URL] = [:]
        var mapping = preparedWallpaperSourceMap
        for (screenName, result) in preparedResults {
            switch result {
            case .success(let preparedURL):
                preparedURLsByScreen[screenName] = preparedURL
                if let sourceURL = sourceMap[screenName] {
                    mapping[preparedURL.path] = sourceURL.path
                }
            case .failure(let error):
                let errorMsg = "Failed to prepare wallpaper: \(error.localizedDescription)"
                HorizonDebugLog.shared.log("wallpaper.prepare.error", fields: [
                    "trigger": trigger,
                    "screen": screenName,
                    "error": error.localizedDescription
                ])
                print("Horizon: \(errorMsg)")
                self.lastError = errorMsg
                return false
            }
        }
        preparedWallpaperSourceMap = mapping

        // Snapshot per-screen apply jobs on main (NSScreen + options dict +
        // displayID + mode) so the off-main worker doesn't have to query
        // main-actor-isolated properties.
        let jobs: [WallpaperScreenApplyJob] = screens.compactMap { screen in
            guard let preparedURL = preparedURLsByScreen[screen.localizedName] else { return nil }
            return WallpaperScreenApplyJob(
                name: screen.localizedName,
                screen: SendableScreen(value: screen),
                preparedURL: preparedURL,
                options: desktopImageOptions(for: screen),
                displayID: displayIDString(for: screen),
                modeDescription: "\(self.mode(for: screen.localizedName))"
            )
        }

        // AppKit requires the desktop-image setter on the main thread. The
        // prepared files are already ready, so these calls only submit the
        // three lightweight per-display requests to WallpaperAgent.
        let applyResults = Self.applyWallpaperJobsOnMainActor(
            jobs,
            applyStart: applyStart
        )

        // Back on main: update bookkeeping, log per-screen outcomes, and
        // roll back successful screens if any peer failed (preserves the
        // all-or-nothing semantics the sync version had).
        var appliedScreens: [NSScreen] = []
        var firstFailure: (name: String, error: NSError)?
        let jobByName = Dictionary(uniqueKeysWithValues: jobs.map { ($0.name, $0) })

        for result in applyResults {
            switch result.outcome {
            case .success:
                desiredURLPerScreen[result.name] = result.preparedURL
                if let job = jobByName[result.name] {
                    appliedScreens.append(job.screen.value)
                }
                let displayName = result.preparedURL.deletingPathExtension().lastPathComponent
                HorizonDebugLog.shared.log("wallpaper.apply", fields: [
                    "trigger": trigger,
                    "screen": result.name,
                    "displayID": result.displayID,
                    "url": result.preparedFilename,
                    "slot": slotSnapshot.isEmpty ? "none" : slotSnapshot,
                    "mood": MoodStore.shared.activeMood?.name ?? "none",
                    "weather": HorizonWeatherService.shared.currentWeather?.condition.rawValue ?? "none",
                    "mode": result.modeDescription,
                    // Diagnostics: see the per-screen instrumentation note on
                    // ScreenApplyResult. Compare startOffsetMs across screens
                    // to tell whether NSWorkspace serializes us or not.
                    "startOffsetMs": result.startOffsetMs,
                    "callDurationMs": result.callDurationMs
                ])
                print("Horizon: Set wallpaper to \(displayName) on \(result.name)")
            case .failure(let error):
                HorizonDebugLog.shared.log("wallpaper.apply.error", fields: [
                    "trigger": trigger,
                    "screen": result.name,
                    "error": error.localizedDescription
                ])
                print("Horizon: Failed to set wallpaper: \(error.localizedDescription) on \(result.name)")
                if firstFailure == nil {
                    firstFailure = (result.name, error)
                }
            }
        }

        if let firstFailure {
            let errorMsg = "Failed to set wallpaper: \(firstFailure.error.localizedDescription)"
            self.lastError = errorMsg
            rollbackWallpapers(appliedScreens, previousURLsByScreen: previousURLsByScreen, trigger: trigger)
            let durationMs = (CFAbsoluteTimeGetCurrent() - applyStart) * 1000
            HorizonDebugLog.shared.log("wallpaper.apply.aborted", fields: [
                "trigger": trigger,
                "durationMs": Int(durationMs.rounded())
            ])
            return false
        }

        // AppKit's setter can return before WallpaperAgent publishes the new
        // per-screen desktop URLs. Keep the cards on the old image until the
        // public desktopImageURL API reports that every display caught up.
        // This is condition-based and normally exits immediately after the OS
        // update; the timeout is only a safety valve if the service stalls.
        let confirmed = await waitForDesktopApplyConfirmation(
            expectedURLsByScreen: preparedURLsByScreen,
            screens: screens,
            timeout: 20
        )
        if !confirmed {
            HorizonDebugLog.shared.log("wallpaper.apply.confirmationTimeout", fields: [
                "trigger": trigger,
                "timeoutSeconds": 20,
                "screens": screens.count
            ])
        }

        let durationMs = (CFAbsoluteTimeGetCurrent() - applyStart) * 1000
        AppPerformanceMetrics.shared.recordWallpaperApply(durationMs: durationMs)
        HorizonDebugLog.shared.log("wallpaper.apply.summary", fields: [
            "trigger": trigger,
            "durationMs": Int(durationMs.rounded()),
            "screens": screens.count,
            "confirmed": confirmed,
            "lastAppliedByScreen": Self.debugURLSummary(desiredURLPerScreen)
        ])
        return confirmed
    }

    @MainActor
    private static func applyWallpaperJobsOnMainActor(
        _ jobs: [WallpaperScreenApplyJob],
        applyStart: CFAbsoluteTime
    ) -> [WallpaperScreenApplyResult] {
        jobs.map { job in
            let taskStart = CFAbsoluteTimeGetCurrent()
            let outcome: Result<Void, NSError>
            do {
                try NSWorkspace.shared.setDesktopImageURL(
                    job.preparedURL,
                    for: job.screen.value,
                    options: job.options
                )
                outcome = .success(())
            } catch let error as NSError {
                outcome = .failure(error)
            }
            let taskEnd = CFAbsoluteTimeGetCurrent()
            return WallpaperScreenApplyResult(
                name: job.name,
                preparedURL: job.preparedURL,
                preparedFilename: job.preparedURL.lastPathComponent,
                displayID: job.displayID,
                modeDescription: job.modeDescription,
                outcome: outcome,
                startOffsetMs: Int(((taskStart - applyStart) * 1000).rounded()),
                callDurationMs: Int(((taskEnd - taskStart) * 1000).rounded())
            )
        }
    }

    @MainActor
    private func waitForDesktopApplyConfirmation(
        expectedURLsByScreen: [String: URL],
        screens: [NSScreen],
        timeout: TimeInterval
    ) async -> Bool {
        let startedAt = CFAbsoluteTimeGetCurrent()

        for checkpoint in Self.desktopApplyConfirmationCheckpoints(timeout: timeout) {
            guard !Task.isCancelled else { return false }

            let elapsedBeforeSleep = CFAbsoluteTimeGetCurrent() - startedAt
            let remainingDelay = checkpoint - elapsedBeforeSleep
            if remainingDelay > 0 {
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64((remainingDelay * 1_000_000_000).rounded())
                    )
                } catch {
                    return false
                }
            }

            var liveURLsByScreen: [String: URL] = [:]
            for screen in screens {
                guard expectedURLsByScreen[screen.localizedName] != nil,
                      let liveURL = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
                liveURLsByScreen[screen.localizedName] = liveURL
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            switch Self.desktopApplyConfirmationDecision(
                expectedURLsByScreen: expectedURLsByScreen,
                liveURLsByScreen: liveURLsByScreen,
                elapsed: elapsed,
                timeout: timeout
            ) {
            case .confirmed:
                return true
            case .timedOut:
                return false
            case .waiting:
                continue
            }
        }

        return false
    }

    /// Single entry point for refreshing the shared `currentPreviewImage`
    /// that every wallpaper-preview surface renders. Views call this from
    /// onAppear, screen change, space change, wake, etc. The manager
    /// dedupes by URL — if the candidate URL hasn't changed since the
    /// last successful load, we skip the work. If it has, we kick off a
    /// load via `WallpaperPreviewLoader` and publish when it completes.
    ///
    /// `forceReload` ignores the dedupe check and invalidates the loader
    /// cache for the prior URL — used by the wake-from-sleep observer in
    /// the dashboard card, because the OS may have changed the desktop
    /// underneath us without telling Horizon.
    @MainActor
    func refreshCurrentPreview(
        preferredScreen: NSScreen? = nil,
        forceReload: Bool = false,
        authoritativeURL: URL? = nil
    ) {
        // When Horizon has just applied a wallpaper itself, the URL it applied is
        // the source of truth. NSWorkspace.desktopImageURL can briefly still report
        // the PREVIOUS image right after a set, so reading the live desktop here
        // would load a stale preview and the dedupe below would freeze it there.
        // Prefer the authoritative URL on self-initiated applies; fall back to the
        // live-desktop read for OS-driven changes (space switch, wake, manual).
        let liveURL = liveDesktopImageURL(preferredScreen: preferredScreen)
        let fallbackURL = currentWallpaperURL()
        let candidateURL = WallpaperPreviewLoader.preferredPreviewURL(
            liveURL: liveURL,
            fallbackURL: fallbackURL,
            authoritativeURL: authoritativeURL
        )

        guard let candidateURL else {
            currentPreviewImage = nil
            currentPreviewURL = nil
            currentPreviewLoadToken = nil
            return
        }

        if forceReload, let previousURL = currentPreviewURL {
            WallpaperPreviewLoader.shared.invalidate(previousURL)
        } else if !forceReload, candidateURL == currentPreviewURL, currentPreviewImage != nil {
            // Nothing has changed; avoid kicking off a duplicate decode.
            return
        }

        let loadToken = UUID()
        currentPreviewLoadToken = loadToken
        WallpaperPreviewLoader.shared.loadImage(from: candidateURL, fallbackURL: fallbackURL) { [weak self] image in
            guard let self else { return }
            // Drop the result if a newer refresh has taken precedence so
            // we never publish a stale image over a fresher one.
            guard self.currentPreviewLoadToken == loadToken else { return }
            self.currentPreviewURL = candidateURL
            self.currentPreviewImage = image
        }
    }

    /// Pure file-prepare: copies `sourceURL` into `preparedDirectory` under a
    /// fingerprint-suffixed name if it isn't already there, pruning stale
    /// fingerprints for the same base name. No `self` capture so it's safe
    /// to call from `Task.detached`. Caller is responsible for updating any
    /// preparedWallpaperSourceMap mapping after success.
    nonisolated static func prepareWallpaperFile(
        sourceURL: URL,
        preparedDirectory: URL
    ) throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return sourceURL }

        let values = try sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let fileSize = values.fileSize ?? 0
        let fingerprint = "\(modifiedAt)-\(fileSize)"
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        var base = sourceURL.deletingPathExtension().lastPathComponent
        if let fingerprintRange = base.range(of: "--\\d+-\\d+$", options: .regularExpression) {
            base = String(base[..<fingerprintRange.lowerBound])
        }
        let preparedURL = preparedDirectory
            .appendingPathComponent("\(base)--\(fingerprint)")
            .appendingPathExtension(ext)

        if !FileManager.default.fileExists(atPath: preparedURL.path) {
            // Prune older fingerprints for the same base name. Failure to
            // prune isn't fatal — the copy still proceeds.
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: preparedDirectory,
                includingPropertiesForKeys: nil
            ) {
                for url in contents where url.lastPathComponent.hasPrefix("\(base)--") && url.lastPathComponent != preparedURL.lastPathComponent {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            try FileManager.default.copyItem(at: sourceURL, to: preparedURL)
        }
        return preparedURL
    }

    private func rollbackWallpapers(
        _ screens: [NSScreen],
        previousURLsByScreen: [String: URL],
        trigger: String
    ) {
        AppPerformanceMetrics.shared.recordWallpaperRollback()
        for screen in screens {
            guard let previousURL = previousURLsByScreen[screen.localizedName] else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(previousURL, for: screen, options: desktopImageOptions(for: screen))
                desiredURLPerScreen[screen.localizedName] = previousURL
                HorizonDebugLog.shared.log("wallpaper.rollback", fields: [
                    "trigger": trigger,
                    "screen": screen.localizedName,
                    "url": previousURL.lastPathComponent
                ])
            } catch {
                HorizonDebugLog.shared.log("wallpaper.rollback.error", fields: [
                    "trigger": trigger,
                    "screen": screen.localizedName,
                    "error": error.localizedDescription
                ])
                print("Horizon: Failed to roll back wallpaper on \(screen.localizedName): \(error.localizedDescription)")
            }
        }
    }

    private func resolvedSlotForSchedule(from slot: String) -> String? {
        let isSimple = UserDefaults.standard.string(forKey: HorizonScheduleDefaults.timeSlotModeKey) == "Simple"
        let orderedSlots = isSimple ? HorizonScheduleDefaults.simpleSlotIDs : HorizonScheduleDefaults.orderedSlotIDs
        let enabledMap = slotEnabledMapFromDefaults(slots: orderedSlots)
        guard enabledMap.values.contains(true) else { return nil }
        let normalizedSlot = normalizedSlot(slot, isSimple: isSimple)

        guard let startIndex = orderedSlots.firstIndex(of: normalizedSlot) else {
            return orderedSlots.first { enabledMap[$0] ?? true }
        }

        for offset in 0..<orderedSlots.count {
            let index = (startIndex + offset) % orderedSlots.count
            let candidate = orderedSlots[index]
            if enabledMap[candidate] ?? true {
                return candidate
            }
        }

        return nil
    }

    private func slotEnabledMapFromDefaults(slots: [String] = HorizonScheduleDefaults.orderedSlotIDs) -> [String: Bool] {
        let defaults = UserDefaults.standard
        var enabledMap = slots.reduce(into: [String: Bool]()) {
            $0[$1] = true
        }

        if let data = defaults.data(forKey: HorizonScheduleDefaults.slotEnabledKey) {
            do {
                let decoded = try JSONDecoder().decode([String: Bool].self, from: data)
                for slotID in slots {
                    if let value = decoded[slotID] {
                        enabledMap[slotID] = value
                    }
                }
            } catch {
                print("[WallpaperManager] Failed to decode slot enabled data: \(error)")
            }
        }

        return enabledMap
    }

    func currentWallpaperURL() -> URL? {
        guard let identifier = currentWallpaperIdentifier() else { return nil }
        return wallpaperURL(for: identifier)
    }

    private func desktopImageOptions(for screen: NSScreen) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        var options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        if options[.imageScaling] == nil {
            options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
        }
        if options[.allowClipping] == nil {
            options[.allowClipping] = true
        }
        return options
    }

    func mode(for screenName: String) -> DisplayMode {
        displayModes[screenName] ?? .synchronized
    }

    func setMode(_ mode: DisplayMode, for screenName: String) {
        displayModes[screenName] = mode
        saveDisplayModes()
    }

    func connectedScreenNames() -> [String] {
        return NSScreen.screens.map { $0.localizedName }
    }

    // MARK: - Slot Change Notifications

    private func sendSlotChangeNotification(for slotID: String) {
        guard notifyOnSlotChange else { return }
        let slotName = HorizonScheduleSettings.timeSlots.first(where: { $0.id == slotID })?.title ?? slotID
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = "Moodpaper"
            content.body = "Now entering \(slotName)"
            content.sound = .none
            let request = UNNotificationRequest(
                identifier: "horizon-slot-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }
}

extension WallpaperManager {
    private var preparedWallpaperSourceMap: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: preparedWallpaperSourceMapKey) else {
                return [:]
            }
            do {
                let decoded = try JSONDecoder().decode([String: String].self, from: data)
                return decoded
            } catch {
                print("[WallpaperManager] Failed to decode preparedWallpaperSourceMap: \(error)")
                return [:]
            }
        }
        set {
            do {
                let encoded = try JSONEncoder().encode(newValue)
                UserDefaults.standard.set(encoded, forKey: preparedWallpaperSourceMapKey)
            } catch {
                print("[WallpaperManager] Failed to encode preparedWallpaperSourceMap: \(error)")
            }
        }
    }

    private func preferredDesktopScreen(explicitScreen: NSScreen? = nil) -> NSScreen? {
        explicitScreen
            ?? NSApp.keyWindow?.screen
            ?? NSApp.mainWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func preparedWallpaperDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("Moodpaper", isDirectory: true)
            .appendingPathComponent("PreparedWallpapers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func preparedDesktopImageURL(for sourceURL: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return sourceURL }

        let values = try sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        let fileSize = values.fileSize ?? 0
        let fingerprint = "\(modifiedAt)-\(fileSize)"
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        var base = sourceURL.deletingPathExtension().lastPathComponent
        // Strip existing fingerprint pattern to prevent duplication (e.g., evening-13--123456--123456.jpg)
        if let fingerprintRange = base.range(of: "--\\d+-\\d+$", options: .regularExpression) {
            base = String(base[..<fingerprintRange.lowerBound])
        }
        let preparedURL = try preparedWallpaperDirectory()
            .appendingPathComponent("\(base)--\(fingerprint)")
            .appendingPathExtension(ext)

        if !FileManager.default.fileExists(atPath: preparedURL.path) {
            do {
                try prunePreparedWallpaperCopies(forBaseName: base, keeping: preparedURL.lastPathComponent)
            } catch {
                print("[WallpaperManager] Failed to prune prepared wallpaper copies: \(error)")
            }
            try FileManager.default.copyItem(at: sourceURL, to: preparedURL)
        }

        var mapping = preparedWallpaperSourceMap
        mapping[preparedURL.path] = sourceURL.path
        preparedWallpaperSourceMap = mapping
        return preparedURL
    }

    private func prunePreparedWallpaperCopies(forBaseName base: String, keeping keepName: String) throws {
        let directory = try preparedWallpaperDirectory()
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in contents where url.lastPathComponent.hasPrefix("\(base)--") && url.lastPathComponent != keepName {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("[WallpaperManager] Failed to remove prepared wallpaper copy: \(error)")
            }
        }
    }

    private func sourceURL(forPreparedWallpaperURL url: URL) -> URL? {
        guard let sourcePath = preparedWallpaperSourceMap[url.path], !sourcePath.isEmpty else { return nil }
        return URL(fileURLWithPath: sourcePath)
    }

    private func isPreparedWallpaperURL(_ url: URL) -> Bool {
        if url.pathComponents.contains("PreparedWallpapers") {
            return true
        }
        do {
            let directory = try preparedWallpaperDirectory()
            return url.path.hasPrefix(directory.path)
        } catch {
            print("[WallpaperManager] Failed to get prepared wallpaper directory: \(error)")
            return false
        }
    }

    func liveDesktopImageURL(preferredScreen: NSScreen? = nil) -> URL? {
        let screen = preferredDesktopScreen(explicitScreen: preferredScreen)
        guard let screen else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    func currentWallpaperIdentifier() -> String? {
        if let stored = UserDefaults.standard.string(forKey: currentWallpaperIdentifierKey), !stored.isEmpty {
            return stored
        }
        guard !currentWallpaperName.isEmpty else { return nil }
        return currentWallpaperName
    }

    func storedIdentifier(for entry: WallpaperHistoryEntry) -> String {
        entry.wallpaperIdentifier ?? entry.wallpaperName
    }

    func currentWallpaperIdentifiersByScreen() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: currentWallpaperIdentifiersByScreenKey) else {
            return [:]
        }

        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            print("[WallpaperManager] Failed to decode currentWallpaperIdentifiersByScreen: \(error)")
            return [:]
        }
    }

    func currentWallpaperStateMatches(_ entry: WallpaperHistoryEntry) -> Bool {
        Self.wallpaperStateMatches(
            entryIdentifiersByScreen: entry.wallpaperIdentifiersByScreen,
            currentIdentifiersByScreen: currentWallpaperIdentifiersByScreen(),
            entryIdentifier: storedIdentifier(for: entry),
            currentIdentifier: currentWallpaperIdentifier()
        )
    }

    private func identifier(for url: URL) -> String {
        if let sourceURL = sourceURL(forPreparedWallpaperURL: url),
           sourceURL.path != url.path {
            return identifier(for: sourceURL)
        }
        if let preparedIdentifier = Self.preparedWallpaperBaseIdentifier(from: url) {
            return preparedIdentifier
        }
        if url.path.hasPrefix(Bundle.main.bundleURL.path) {
            return url.deletingPathExtension().lastPathComponent
        }
        return url.path
    }

    private func displayName(for url: URL) -> String {
        if let sourceURL = sourceURL(forPreparedWallpaperURL: url),
           sourceURL.path != url.path {
            return sourceURL.deletingPathExtension().lastPathComponent
        }
        if let preparedIdentifier = Self.preparedWallpaperBaseIdentifier(from: url) {
            return preparedIdentifier
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private func persistWallpaperState(
        primaryName: String,
        primaryIdentifier: String,
        identifiersByScreen: [String: String]
    ) {
        currentWallpaperName = primaryName
        UserDefaults.standard.set(primaryName, forKey: "currentWallpaperName")
        UserDefaults.standard.set(primaryIdentifier, forKey: currentWallpaperIdentifierKey)

        do {
            let data = try JSONEncoder().encode(identifiersByScreen)
            UserDefaults.standard.set(data, forKey: currentWallpaperIdentifiersByScreenKey)
        } catch {
            print("[WallpaperManager] Failed to encode currentWallpaperIdentifiersByScreen: \(error)")
        }
    }

    private func validateStateInvariants(context: String) {
        let violations = Self.stateInvariantViolations(
            activeScreenNames: Set(
                NSScreen.screens
                    .filter { mode(for: $0.localizedName) != .off }
                    .map(\.localizedName)
            ),
            trackedScreenNames: Set(currentWallpaperIdentifiersByScreen().keys)
        )

        guard !violations.isEmpty else { return }

        let message = "[WallpaperManager] State invariant failed (\(context)): \(violations.joined(separator: "; "))"
        HorizonDebugLog.shared.log("state.invariant", fields: [
            "context": context,
            "violations": violations.joined(separator: " | ")
        ])
        print(message)

#if DEBUG
        assertionFailure(message)
#endif
    }

    private func refreshPreparedWallpaperStateIfNeeded() {
        guard let liveURL = liveDesktopImageURL(),
              !isPreparedWallpaperURL(liveURL),
              let identifier = currentWallpaperIdentifier(),
              let resolvedURL = wallpaperURL(for: identifier),
              resolvedURL.path == liveURL.path else {
            return
        }

        DispatchQueue.main.async {
            self.pendingHistorySlot = ""
            self.setWallpaper(identifier: identifier)
        }
    }

    func normalizedSlot(_ slot: String, isSimple: Bool) -> String {
        guard isSimple else { return slot }
        switch slot {
        case "deep-night", "dawn", "sunrise", "morning":
            return "morning"
        case "midday", "afternoon":
            return "afternoon"
        case "golden-hour", "dusk", "evening":
            return "evening"
        default:
            return slot
        }
    }

    /// True when a live `NSWorkspace.desktopImageURL` read must NOT be trusted
    /// to overwrite persisted wallpaper identity. The live read briefly returns
    /// the PREVIOUS image right after `setDesktopImageURL` (tasks/lessons.md
    /// 2026-05-29). A stale read after our own apply is always one of our own
    /// prepared files, so an external URL (user changed wallpaper in System
    /// Settings) is always accepted, and our own prepared file that contradicts
    /// a just-applied wallpaper is ignored inside a short settle window.
    static func shouldIgnoreLiveDesktopRead(
        liveIdentifier: String,
        liveURLIsOwnPrepared: Bool,
        lastAppliedIdentifier: String?,
        isChangingWallpaper: Bool,
        secondsSinceLastChange: TimeInterval?,
        spacesSyncOwnsConsistency: Bool = false
    ) -> Bool {
        if isChangingWallpaper { return true }
        guard liveURLIsOwnPrepared,
              let lastAppliedIdentifier,
              liveIdentifier != lastAppliedIdentifier else { return false }
        // With "Sync to all Spaces" ON, the engine owns per-Space consistency:
        // an own-prepared file that contradicts the applied wallpaper is a
        // Space the 0.25s reapply debounce hasn't reached yet. Persisting that
        // transient read regressed currentWallpaperName on a Space switch
        // (live repro: name said morning-8 while every display showed
        // night-01). External URLs still sync normally.
        if spacesSyncOwnsConsistency { return true }
        guard let secondsSinceLastChange else { return false }
        return secondsSinceLastChange < 15
    }

    func syncCurrentWallpaperWithDesktop(preferredScreen: NSScreen? = nil) {
        guard let liveURL = liveDesktopImageURL(preferredScreen: preferredScreen) else { return }

        let liveName = displayName(for: liveURL)
        let liveIdentifier = identifier(for: liveURL)

        // Never let a lagging live read regress state we just persisted
        // ourselves (the popover's onChange fires exactly when a new name is
        // persisted, racing the still-settling desktop read).
        if Self.shouldIgnoreLiveDesktopRead(
            liveIdentifier: liveIdentifier,
            liveURLIsOwnPrepared: isPreparedWallpaperURL(liveURL),
            lastAppliedIdentifier: lastAppliedURL.map(identifier(for:)),
            isChangingWallpaper: isChangingWallpaper,
            secondsSinceLastChange: lastWallpaperChangeAt.map { Date().timeIntervalSince($0) },
            spacesSyncOwnsConsistency: syncAllSpaces
        ) {
            return
        }

        guard currentWallpaperName != liveName
            || currentWallpaperIdentifier() != liveIdentifier
            || lastAppliedURL != liveURL
        else {
            return
        }

        currentWallpaperName = liveName
        // Only update lastAppliedURL if it's empty or if the new URL is from the current time slot
        // This prevents corruption when switching to a space with a different wallpaper
        if lastAppliedURL == nil || isCurrentTimeSlotWallpaper(liveURL) {
            lastAppliedURL = liveURL
        }
        UserDefaults.standard.set(liveIdentifier, forKey: currentWallpaperIdentifierKey)
        UserDefaults.standard.set(liveName, forKey: "currentWallpaperName")
        if let screenName = preferredScreen?.localizedName {
            var identifiersByScreen = currentWallpaperIdentifiersByScreen()
            identifiersByScreen[screenName] = liveIdentifier
            do {
                let data = try JSONEncoder().encode(identifiersByScreen)
                UserDefaults.standard.set(data, forKey: currentWallpaperIdentifiersByScreenKey)
            } catch {
                print("[WallpaperManager] Failed to encode currentWallpaperIdentifiersByScreen: \(error)")
            }
        }
    }

    /// Check if a wallpaper URL belongs to the current time slot
    private func isCurrentTimeSlotWallpaper(_ url: URL) -> Bool {
        let currentSlot = currentTimeSlot()
        let identifier = identifier(for: url)
        return Self.wallpaperBelongsToCurrentSlot(
            identifier: identifier,
            currentSlot: currentSlot,
            manifestSlotForIdentifier: { _ in nil }
        )
    }

    func reconcileCurrentWallpaperState() {
        let storedName = UserDefaults.standard.string(forKey: "currentWallpaperName") ?? ""
        let liveScreenURLs = NSScreen.screens.reduce(into: [String: URL]()) { result, screen in
            if let url = liveDesktopImageURL(preferredScreen: screen) {
                result[screen.localizedName] = url
            }
        }

        // Same staleness rule as syncCurrentWallpaperWithDesktop: this runs on
        // appDidBecomeActive/systemDidWake, which can land inside the settle
        // window right after our own apply, when the live reads still return
        // the previous wallpaper. Persisting from them would regress state.
        let staleRead = liveScreenURLs.values.contains { liveURL in
            Self.shouldIgnoreLiveDesktopRead(
                liveIdentifier: identifier(for: liveURL),
                liveURLIsOwnPrepared: isPreparedWallpaperURL(liveURL),
                lastAppliedIdentifier: lastAppliedURL.map(identifier(for:)),
                isChangingWallpaper: isChangingWallpaper,
                secondsSinceLastChange: lastWallpaperChangeAt.map { Date().timeIntervalSince($0) },
                spacesSyncOwnsConsistency: syncAllSpaces
            )
        }
        if staleRead { return }

        let liveIdentifiersByScreen = liveScreenURLs.mapValues { self.identifier(for: $0) }
        let resolution = Self.resolveReconciledWallpaperState(
            storedName: storedName,
            currentStoredIdentifier: UserDefaults.standard.string(forKey: currentWallpaperIdentifierKey),
            primaryScreenName: preferredDesktopScreen()?.localizedName,
            liveIdentifiersByScreen: liveIdentifiersByScreen,
            displayNameForIdentifier: { [self] identifier in
                wallpaperURL(for: identifier).map(displayName(for:))
            }
        )

        switch resolution {
        case .live(let primaryName, let primaryIdentifier, let identifiersByScreen):
            currentWallpaperName = primaryName
            if let primaryScreenName = preferredDesktopScreen()?.localizedName,
               let liveURL = liveScreenURLs[primaryScreenName] ?? liveScreenURLs.values.first,
               lastAppliedURL == nil || isCurrentTimeSlotWallpaper(liveURL) {
                lastAppliedURL = liveURL
            }
            persistWallpaperState(
                primaryName: primaryName,
                primaryIdentifier: primaryIdentifier,
                identifiersByScreen: identifiersByScreen
            )
        case .storedFallback(let primaryName, let primaryIdentifier):
            currentWallpaperName = primaryName
            if primaryIdentifier == nil, !storedName.isEmpty {
                UserDefaults.standard.set(storedName, forKey: currentWallpaperIdentifierKey)
            }
            lastAppliedURL = currentWallpaperURL()
        }
    }

    func reconcileRuntimeState(reason: String) {
        print("[WallpaperManager] Reconciling runtime state (\(reason))")
        reconcileCurrentWallpaperState()
        validateStateInvariants(context: "runtimeReconcile:\(reason)")
    }

    static func wallpaperStateMatches(
        entryIdentifiersByScreen: [String: String]?,
        currentIdentifiersByScreen: [String: String],
        entryIdentifier: String,
        currentIdentifier: String?
    ) -> Bool {
        if let entryIdentifiersByScreen, !entryIdentifiersByScreen.isEmpty {
            return entryIdentifiersByScreen == currentIdentifiersByScreen
        }

        return entryIdentifier == currentIdentifier
    }

    static func shouldSuppressContextualWallpaperOverrides(
        focusModeEnabled: Bool,
        isInMeeting: Bool
    ) -> Bool {
        focusModeEnabled && isInMeeting
    }

    /// The single authoritative answer to "where does the wallpaper come from
    /// right now?" After the Moodpaper pivot there is exactly one source: the
    /// active Mood's folder for the current slot. The only decision left is
    /// the empty-slot rule, locked here so it stays testable (see
    /// WallpaperSourceDecisionTests): an empty slot HOLDS the current
    /// wallpaper until the schedule reaches a slot that has images.
    enum WallpaperSourceDecision: Equatable {
        case moodPool
        case holdCurrent
    }

    static func resolveWallpaperSource(moodPoolIsEmpty: Bool) -> WallpaperSourceDecision {
        moodPoolIsEmpty ? .holdCurrent : .moodPool
    }

    static func shouldSkipWallpaperUpdateForDND(
        isDNDActive: Bool,
        respectDoNotDisturb: Bool,
        focusMeetingActive: Bool
    ) -> Bool {
        isDNDActive && respectDoNotDisturb && !focusMeetingActive
    }

    static func shouldAllowWallpaperChange(
        pauseRotationEnabled: Bool,
        userInitiated: Bool
    ) -> Bool {
        !pauseRotationEnabled
    }

    static func shouldPublishCountdownUpdate(current: String, next: String) -> Bool {
        current != next
    }

    static func wallpaperBelongsToCurrentSlot(
        identifier: String,
        currentSlot: String,
        manifestSlotForIdentifier: (String) -> String?
    ) -> Bool {
        if let manifestSlot = manifestSlotForIdentifier(identifier) {
            return manifestSlot == currentSlot
        }
        return identifier.hasPrefix(currentSlot)
    }

    /// Launch churn guard: a fresh launch has an empty in-memory lastSlot,
    /// which used to force a rotation on every login/restart. Keep the
    /// persisted wallpaper when it still fits: the dwell clock (persisted)
    /// hasn't expired and the wallpaper belongs to the current slot. A nil
    /// persistedWallpaperSlot means a user/custom wallpaper with no manifest
    /// slot — those are slot-agnostic and preserved while the dwell is valid.
    static func shouldPreservePersistedWallpaperAtLaunch(
        hasPersistedWallpaper: Bool,
        persistedWallpaperSlot: String?,
        resolvedSlot: String,
        secondsSinceLastChange: TimeInterval?,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard hasPersistedWallpaper else { return false }
        guard let elapsed = secondsSinceLastChange, elapsed >= 0, elapsed < minimumInterval else { return false }
        if let persistedWallpaperSlot {
            return persistedWallpaperSlot == resolvedSlot
        }
        return true
    }

    static func debugTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func debugURLSummary(_ urlsByScreen: [String: URL]) -> String {
        guard !urlsByScreen.isEmpty else { return "none" }
        return urlsByScreen
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.lastPathComponent)" }
            .joined(separator: ",")
    }

    static func preparedWallpaperBaseIdentifier(from url: URL) -> String? {
        guard url.pathComponents.contains("PreparedWallpapers") else { return nil }
        let baseName = url.deletingPathExtension().lastPathComponent
        if let fingerprintRange = baseName.range(of: "--\\d+-\\d+$", options: .regularExpression) {
            let identifier = String(baseName[..<fingerprintRange.lowerBound])
            return identifier.isEmpty ? nil : identifier
        }
        return baseName.isEmpty ? nil : baseName
    }

    static func resolveReconciledWallpaperState(
        storedName: String,
        currentStoredIdentifier: String?,
        primaryScreenName: String?,
        liveIdentifiersByScreen: [String: String],
        displayNameForIdentifier: (String) -> String?
    ) -> ReconciledWallpaperState {
        if let primaryScreenName,
           let primaryIdentifier = liveIdentifiersByScreen[primaryScreenName] ?? liveIdentifiersByScreen.values.first {
            let primaryName = displayNameForIdentifier(primaryIdentifier) ?? primaryIdentifier
            return .live(
                primaryName: primaryName,
                primaryIdentifier: primaryIdentifier,
                identifiersByScreen: liveIdentifiersByScreen
            )
        }

        return .storedFallback(
            primaryName: storedName,
            primaryIdentifier: currentStoredIdentifier
        )
    }

    static func resolveHistoryRestore(
        storedIdentifiersByScreen: [String: String],
        activeScreenNames: [String],
        primaryScreenName: String
    ) -> HistoryRestoreResolution {
        guard !activeScreenNames.isEmpty else {
            return .failed
        }

        let fallbackIdentifier = storedIdentifiersByScreen.values.first
        var resolvedIdentifiersByScreen: [String: String] = [:]

        for screenName in activeScreenNames {
            guard let identifier = storedIdentifiersByScreen[screenName] ?? fallbackIdentifier else {
                return .failed
            }
            resolvedIdentifiersByScreen[screenName] = identifier
        }

        guard let primaryIdentifier = resolvedIdentifiersByScreen[primaryScreenName]
            ?? resolvedIdentifiersByScreen[activeScreenNames[0]] else {
            return .failed
        }

        let resolvedPrimaryScreenName = resolvedIdentifiersByScreen[primaryScreenName] != nil
            ? primaryScreenName
            : activeScreenNames[0]

        return .resolved(
            resolvedIdentifiersByScreen: resolvedIdentifiersByScreen,
            primaryScreenName: resolvedPrimaryScreenName,
            primaryIdentifier: primaryIdentifier
        )
    }

    static func stateInvariantViolations(
        activeScreenNames: Set<String>,
        trackedScreenNames: Set<String>
    ) -> [String] {
        var violations: [String] = []

        if !trackedScreenNames.isEmpty && !activeScreenNames.isSubset(of: trackedScreenNames) {
            violations.append("per-display wallpaper state is missing one or more active screens")
        }

        return violations
    }
}

// MARK: - Display Mode

enum DisplayMode: String, CaseIterable {
    case synchronized
    case independent
    case off

    static func availableCases() -> [DisplayMode] {
        allCases
    }

    var title: String {
        switch self {
        case .synchronized: return "Synchronized"
        case .independent: return "Independent"
        case .off: return "Off"
        }
    }

    var subtitle: String {
        switch self {
        case .synchronized: return "Mirrors all other displays"
        case .independent: return "Own wallpaper per time slot"
        case .off: return "No wallpaper changes"
        }
    }

    var symbol: String {
        switch self {
        case .synchronized: return "rectangle.2.swap"
        case .independent: return "rectangle.split.2x1"
        case .off: return "rectangle.slash"
        }
    }
}
