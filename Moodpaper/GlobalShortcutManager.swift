import AppKit

// MARK: - Key codes (macOS virtual key codes)
private enum KeyCode {
    static let leftArrow:  UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let r:          UInt16 = 15
    static let h:          UInt16 = 4
}

// MARK: - GlobalShortcutManager

/// Registers global keyboard shortcuts for Horizon.
///
/// Shortcuts:
///   ⌥⌘→  Next wallpaper
///   ⌥⌘←  Previous wallpaper (history-based)
///   ⌥⌘R  Random wallpaper
///   ⌃⌘H  Open Horizon popover
///
/// Requires Accessibility permission. Horizon only prompts after the user
/// enables shortcuts in Settings.
@MainActor
final class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()

    private var monitor: Any?
    private init() {}

    // MARK: - Lifecycle

    var isAuthorized: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func start() -> Bool {
        guard monitor == nil else { return true }

        // Request accessibility if not already granted, prompts System Settings
        if !isAuthorized {
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
            AXIsProcessTrustedWithOptions(options)
            return false
        }

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        print("[Shortcuts] Global monitor registered")
        return true
    }

    @discardableResult
    func reconcile(enabledPreference: Bool) -> Bool {
        guard enabledPreference else {
            stop()
            return false
        }

        guard isAuthorized else {
            stop()
            return false
        }

        return start()
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        print("[Shortcuts] Global monitor removed")
    }
    // MARK: - Handler

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key   = event.keyCode

        let optCmd:  NSEvent.ModifierFlags = [.option, .command]
        let ctrlCmd: NSEvent.ModifierFlags = [.control, .command]

        switch (flags, key) {
        case (optCmd, KeyCode.rightArrow):
            // ⌥⌘→ Next wallpaper
            WallpaperManager.shared.skipToNext()
            print("[Shortcuts] ⌥⌘→ Next wallpaper")

        case (optCmd, KeyCode.leftArrow):
            // ⌥⌘← Previous wallpaper (history-based playback)
            WallpaperManager.shared.skipToPrevious()
            print("[Shortcuts] ⌥⌘← Previous wallpaper")

        case (optCmd, KeyCode.r):
            // ⌥⌘R Random wallpaper — full pool, ignores current slot and vibe
            WallpaperManager.shared.skipToRandom()
            print("[Shortcuts] ⌥⌘R Random wallpaper")

        case (ctrlCmd, KeyCode.h):
            // ⌃⌘H Open Horizon popover
            openHorizon()
            print("[Shortcuts] ⌃⌘H Open Horizon")

        default:
            break
        }
    }

    // MARK: - Open Horizon

    private func openHorizon() {
        // Post a notification that AppDelegate listens to
        NotificationCenter.default.post(name: .horizonOpenPopover, object: nil)
    }
}

// MARK: - Notification Name

extension Notification.Name {
    static let horizonOpenPopover        = Notification.Name("com.2DaMax.Moodpaper.openPopover")
    static let navigateToMoods           = Notification.Name("com.2DaMax.Moodpaper.navigateToMoods")
    static let navigateToUserWallpapers  = Notification.Name("com.2DaMax.Moodpaper.navigateToUserWallpapers")
}
