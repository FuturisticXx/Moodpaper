import SwiftUI

// MARK: - UserDefaults Validation Helper

extension UserDefaults {
    func validatedString(forKey key: String) -> String? {
        guard let value = string(forKey: key), !value.isEmpty else {
            return nil
        }
        return value
    }

    func validatedDictionary(forKey key: String) -> [String: Any]? {
        guard let value = dictionary(forKey: key) else { return nil }
        // Validate structure if needed
        return value
    }
}

@main
struct HorizonApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let defaultWindowSize = CGSize(width: 1180, height: 760)

    var body: some Scene {
        Window("Moodpaper", id: "settings") {
            HorizonSettingsRootView()
                .environmentObject(AppRuntimeState.shared)
                .environmentObject(WallpaperManager.shared)
                .frame(minWidth: 1168, minHeight: 792)
                .background(WindowDelegateHandler(defaultSize: defaultWindowSize))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
    }
}

// MARK: - Window Delegate Handler

struct WindowDelegateHandler: NSViewRepresentable {
    let defaultSize: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // Delay slightly to ensure window is available
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = view.window,
               let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                print("Horizon: Setting window delegate for settings window")
                window.delegate = appDelegate
                window.isReleasedWhenClosed = false
                window.setFrameAutosaveName("MoodpaperSettingsWindow")
                let contentSize = window.contentLayoutRect.size
                let frameIsTooSmall = contentSize.width < defaultSize.width || contentSize.height < defaultSize.height
                if !UserDefaults.standard.bool(forKey: "hasCustomizedSettingsWindowFrame") || frameIsTooSmall {
                    appDelegate.isApplyingDefaultSettingsWindowFrame = true
                    let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
                    let targetWidth = min(defaultSize.width, max(1040, visibleFrame.width - 80))
                    let targetHeight = min(defaultSize.height, max(680, visibleFrame.height - 80))
                    window.setContentSize(NSSize(width: targetWidth, height: targetHeight))
                    window.center()
                    DispatchQueue.main.async {
                        appDelegate.isApplyingDefaultSettingsWindowFrame = false
                    }
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct HorizonApplicationSnapshot {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
}

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem?
    var popover = NSPopover()
    var onboardingWindow: NSWindow?
    var isApplyingDefaultSettingsWindowFrame = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[HorizonApp] Application did finish launching")
        terminateDuplicateInstances()
        // Track app launch
        AnalyticsManager.shared.log(.appLaunch)
        HorizonMetricKitObserver.shared.start()

        // Create the menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sun.horizon.fill", accessibilityDescription: "Moodpaper")
            button.action = #selector(togglePopover)
            button.target = self
            button.toolTip = "Moodpaper"
            button.setAccessibilityLabel("Moodpaper")
        }

        // HZN-010: Icon is always visible. Horizon has no Dock icon, so hiding it strands the app.
        statusItem?.isVisible = true

        // Set up the popover
        popover.contentSize = NSSize(width: 320, height: 480)
        popover.behavior = .transient
        // Note: no .accessibilityLabel on the container — SwiftUI applies a
        // container label to EVERY contained element, wiping out the
        // individual control labels (Skip, Like, Pin, ...) for VoiceOver.
        popover.contentViewController = NSHostingController(
            rootView: ContentView()
                .environmentObject(AppRuntimeState.shared)
        )

        // Hide from Dock and App Switcher, menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Global keyboard shortcuts are opt-in because they require Accessibility access.
        Task { @MainActor in
            if UserDefaults.standard.bool(forKey: "shortcutsEnabled") {
                GlobalShortcutManager.shared.start()
            }
            await AppRuntimeState.shared.refresh(reason: "launch")
        }

        // Listen for ⌃⌘H open-popover notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openPopoverFromShortcut),
            name: .horizonOpenPopover,
            object: nil
        )

        migrateUserDefaultsIfNeeded()

        // Show onboarding on first launch
        showOnboardingIfNeeded()
    }

    // MARK: - Migrations

    struct UserDefaultsMigration {
        static let currentVersion = 3

        static func migrateIfNeeded() {
            let defaults = UserDefaults.standard
            let lastVersion = defaults.integer(forKey: "migrationVersion")

            if lastVersion < currentVersion {
                print("[UserDefaultsMigration] Migrating from version \(lastVersion) to \(currentVersion)")
                migrate(from: lastVersion, to: currentVersion)
                defaults.set(currentVersion, forKey: "migrationVersion")
            }
        }

        private static func migrate(from oldVersion: Int, to newVersion: Int) {
            let defaults = UserDefaults.standard

            // Version 1 used to migrate weatherSyncToggle → schedule.weatherSync.
            // Weather-driven selection was removed in the Moodpaper pivot, so
            // the legacy keys are simply cleared.
            if oldVersion < 1 {
                defaults.removeObject(forKey: "weatherSyncToggle")
                defaults.removeObject(forKey: "schedule.weatherSync")
            }

            if oldVersion < 2 {
                // Placeholder for future migrations
            }

            // Migration to version 3: seed per-display wallpaper identifiers from the
            // legacy single current wallpaper identifier so upgraded installs have a
            // consistent baseline for replay and reconciliation.
            if oldVersion < 3 {
                seedPerDisplayWallpaperIdentifiers(
                    defaults: defaults,
                    screenNames: NSScreen.screens.map(\.localizedName)
                )
            }
        }

        static func seedPerDisplayWallpaperIdentifiers(defaults: UserDefaults, screenNames: [String]) {
            let perDisplayKey = "currentWallpaperIdentifiersByScreen"
            if defaults.data(forKey: perDisplayKey) != nil {
                return
            }

            let legacyIdentifier =
                defaults.string(forKey: "currentWallpaperIdentifier")
                ?? defaults.string(forKey: "currentWallpaperName")

            guard let legacyIdentifier, !legacyIdentifier.isEmpty else {
                return
            }

            let perDisplayIdentifiers = Dictionary(
                uniqueKeysWithValues: screenNames.map { ($0, legacyIdentifier) }
            )
            guard !perDisplayIdentifiers.isEmpty,
                  let encoded = try? JSONEncoder().encode(perDisplayIdentifiers) else {
                return
            }

            defaults.set(encoded, forKey: perDisplayKey)
            print("[UserDefaultsMigration] Seeded currentWallpaperIdentifiersByScreen from legacy identifier")
        }
    }

    private func migrateUserDefaultsIfNeeded() {
        UserDefaultsMigration.migrateIfNeeded()
    }

    // MARK: - Onboarding

    func showOnboardingIfNeeded() {
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if !hasCompletedOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.showOnboarding()
            }
        }
    }

    func showOnboarding() {
        let onboardingView = OnboardingView(isPresented: Binding(
            get: { self.onboardingWindow != nil },
            set: { newValue in
                if !newValue {
                    self.onboardingWindow?.close()
                }
            }
        ))
        let hostingController = NSHostingController(rootView: onboardingView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovable = true
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 1060, height: 720))
        window.minSize = NSSize(width: 1060, height: 720)
        window.level = .floating

        // Center on the primary screen (NSScreen.screens.first is the screen
        // with the menu bar). window.center() and NSScreen.main can both land
        // the window on the wrong display in multi-monitor configurations.
        if let screen = NSScreen.screens.first {
            let visibleFrame = screen.visibleFrame
            let windowSize = NSSize(width: 1060, height: 720)
            let origin = NSPoint(
                x: visibleFrame.midX - windowSize.width / 2,
                y: visibleFrame.midY - windowSize.height / 2
            )
            window.setFrameOrigin(origin)
        } else {
            window.center()
        }

        // Persist completion + clear the window reference whenever the window
        // closes, regardless of how it closed (Continue, Skip, or the red
        // traffic light). Single source of truth for onboarding completion.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                AnalyticsManager.shared.log(.onboardingCompleted)
                self?.onboardingWindow = nil
            }
        }

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        onboardingWindow = window
    }

    @objc func openPopoverFromShortcut() {
        guard let button = statusItem?.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc func togglePopover() {
        if let button = statusItem?.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                popover.contentViewController?.view.window?.makeKey()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the app running even when all windows are closed (menu bar app)
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            await AppRuntimeState.shared.refresh(reason: "appDidBecomeActive")
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        print("[HorizonApp] windowShouldClose called for \(sender.title), hiding window instead")
        // Hide the window instead of closing it
        sender.orderOut(nil)
        return false
    }

    func windowDidResize(_ notification: Notification) {
        recordSettingsWindowCustomizationIfNeeded(notification)
    }

    func windowDidMove(_ notification: Notification) {
        recordSettingsWindowCustomizationIfNeeded(notification)
    }

    private func recordSettingsWindowCustomizationIfNeeded(_ notification: Notification) {
        guard !isApplyingDefaultSettingsWindowFrame,
              let window = notification.object as? NSWindow,
              window.identifier?.rawValue == "settings" || window.title == "Moodpaper" else {
            return
        }
        UserDefaults.standard.set(true, forKey: "hasCustomizedSettingsWindowFrame")
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("[HorizonApp] Application will terminate")

        // Clean up observers to prevent memory leaks
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    static func duplicateHorizonProcessIDs(
        snapshots: [HorizonApplicationSnapshot],
        currentProcessID: pid_t,
        currentBundleIdentifier: String?
    ) -> [pid_t] {
        guard let currentBundleIdentifier else { return [] }
        return snapshots
            .filter { $0.bundleIdentifier == currentBundleIdentifier }
            .filter { $0.processIdentifier != currentProcessID }
            .map(\.processIdentifier)
            .sorted()
    }

    static func shouldTerminateDuplicateInstances(environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }

    private func terminateDuplicateInstances() {
        guard Self.shouldTerminateDuplicateInstances(environment: ProcessInfo.processInfo.environment) else { return }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentBundleIdentifier = Bundle.main.bundleIdentifier
        let runningApplications = NSWorkspace.shared.runningApplications
        let snapshots = runningApplications.map {
            HorizonApplicationSnapshot(
                processIdentifier: $0.processIdentifier,
                bundleIdentifier: $0.bundleIdentifier
            )
        }
        let duplicatePIDs = Self.duplicateHorizonProcessIDs(
            snapshots: snapshots,
            currentProcessID: currentPID,
            currentBundleIdentifier: currentBundleIdentifier
        )
        guard !duplicatePIDs.isEmpty else { return }

        for application in runningApplications where duplicatePIDs.contains(application.processIdentifier) {
            print("[HorizonApp] Terminating duplicate Horizon instance pid=\(application.processIdentifier)")
            application.terminate()
        }
    }
}
