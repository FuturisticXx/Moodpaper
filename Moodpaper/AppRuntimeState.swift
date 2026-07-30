import AppKit
import CoreLocation
import EventKit
import Foundation
import UserNotifications
internal import Combine

@MainActor
final class AppRuntimeState: ObservableObject {
    static let shared = AppRuntimeState()

    struct Capabilities: Equatable {
        let locationAuthorized: Bool
        let calendarAuthorized: Bool
        let notificationsAuthorized: Bool
        let shortcutsAuthorized: Bool
        let notificationsEnabledPreference: Bool
        let shortcutsEnabledPreference: Bool
        let slotChangeNotificationsAvailable: Bool
        let focusModeAvailable: Bool
        let independentDisplaysAvailable: Bool
        let slotSourceCustomizationAvailable: Bool
    }

    @Published private(set) var locationAuthorized: Bool = false
    @Published private(set) var calendarAuthorized: Bool = false
    @Published private(set) var notificationsAuthorized: Bool = false
    @Published private(set) var shortcutsAuthorized: Bool = false
    @Published private(set) var notificationsEnabledPreference: Bool = false
    @Published private(set) var shortcutsEnabledPreference: Bool = false
    @Published private(set) var slotChangeNotificationsAvailable: Bool = false
    @Published private(set) var focusModeAvailable: Bool = false
    @Published private(set) var independentDisplaysAvailable: Bool = false
    @Published private(set) var slotSourceCustomizationAvailable: Bool = false
    @Published private(set) var lastRefreshReason: String = "startup"
    @Published private(set) var lastRefreshAt: Date?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        bindSources()
        recomputeCapabilities(reason: "init")
    }

    func refresh(reason: String) async {
        lastRefreshReason = reason

        LocationService.shared.reconcileRuntimeState(reason: reason)
        CalendarService.shared.reconcileRuntimeState(shouldMonitor: WallpaperManager.shared.focusModeEnabled, reason: reason)
        let notificationsEnabled = UserDefaults.standard.bool(forKey: HorizonScheduleDefaults.notifyOnSlotChangeKey)
        _ = await NotificationPermissionManager.shared.reconcile(enabledPreference: notificationsEnabled)
        let shortcutsEnabled = UserDefaults.standard.bool(forKey: "shortcutsEnabled")
        GlobalShortcutManager.shared.reconcile(enabledPreference: shortcutsEnabled)
        WallpaperManager.shared.reconcileRuntimeState(reason: reason)
        recomputeCapabilities(reason: reason)
    }

    private func bindSources() {
        // All four sources are @Published on @MainActor singletons, so they
        // emit on main already. The prior .receive(on: RunLoop.main) added a
        // runloop hop per emission for no benefit — Combine pipes through
        // straight when the sink reads from main without it.
        LocationService.shared.$authorizationStatus
            .sink { [weak self] _ in
                self?.recomputeCapabilities(reason: "locationAuthorizationChanged")
            }
            .store(in: &cancellables)

        CalendarService.shared.$authorizationStatus
            .sink { [weak self] _ in
                self?.recomputeCapabilities(reason: "calendarAuthorizationChanged")
            }
            .store(in: &cancellables)

        NotificationPermissionManager.shared.$authorizationStatus
            .sink { [weak self] _ in
                self?.recomputeCapabilities(reason: "notificationAuthorizationChanged")
            }
            .store(in: &cancellables)
    }

    private func recomputeCapabilities(reason: String) {
        let capabilities = Self.computeCapabilities(
            locationAuthorizationStatus: LocationService.shared.authorizationStatus,
            calendarAuthorizationStatus: CalendarService.shared.authorizationStatus,
            notificationAuthorizationStatus: NotificationPermissionManager.shared.authorizationStatus,
            shortcutsAuthorized: GlobalShortcutManager.shared.isAuthorized,
            notificationsEnabledPreference: UserDefaults.standard.bool(forKey: HorizonScheduleDefaults.notifyOnSlotChangeKey),
            shortcutsEnabledPreference: UserDefaults.standard.bool(forKey: "shortcutsEnabled")
        )

        locationAuthorized = capabilities.locationAuthorized
        calendarAuthorized = capabilities.calendarAuthorized
        notificationsAuthorized = capabilities.notificationsAuthorized
        shortcutsAuthorized = capabilities.shortcutsAuthorized
        notificationsEnabledPreference = capabilities.notificationsEnabledPreference
        shortcutsEnabledPreference = capabilities.shortcutsEnabledPreference
        slotChangeNotificationsAvailable = capabilities.slotChangeNotificationsAvailable
        focusModeAvailable = capabilities.focusModeAvailable
        independentDisplaysAvailable = capabilities.independentDisplaysAvailable
        slotSourceCustomizationAvailable = capabilities.slotSourceCustomizationAvailable
        lastRefreshReason = reason
        lastRefreshAt = Date()
    }

    static func computeCapabilities(
        locationAuthorizationStatus: CLAuthorizationStatus,
        calendarAuthorizationStatus: EKAuthorizationStatus,
        notificationAuthorizationStatus: UNAuthorizationStatus,
        shortcutsAuthorized: Bool,
        notificationsEnabledPreference: Bool,
        shortcutsEnabledPreference: Bool
    ) -> Capabilities {
        let locationAuthorized = locationAuthorizationStatus == .authorizedAlways
            || locationAuthorizationStatus == .authorized
        let calendarAuthorized = calendarAuthorizationStatus == .fullAccess
        let notificationsAuthorized = NotificationPermissionManager.isAuthorized(notificationAuthorizationStatus)

        return Capabilities(
            locationAuthorized: locationAuthorized,
            calendarAuthorized: calendarAuthorized,
            notificationsAuthorized: notificationsAuthorized,
            shortcutsAuthorized: shortcutsAuthorized,
            notificationsEnabledPreference: notificationsEnabledPreference,
            shortcutsEnabledPreference: shortcutsEnabledPreference,
            slotChangeNotificationsAvailable: notificationsEnabledPreference && notificationsAuthorized,
            focusModeAvailable: calendarAuthorized,
            independentDisplaysAvailable: true,
            slotSourceCustomizationAvailable: true
        )
    }
}
