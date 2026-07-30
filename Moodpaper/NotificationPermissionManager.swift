import Foundation
import UserNotifications
internal import Combine

@MainActor
final class NotificationPermissionManager: ObservableObject {
    static let shared = NotificationPermissionManager()

    enum RuntimePlan: Equatable {
        case disabled
        case requestAuthorization
        case enabled
    }

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private init() {
        Task { @MainActor in
            await refreshAuthorizationStatus(reason: "init")
        }
    }

    var isAuthorized: Bool {
        Self.isAuthorized(authorizationStatus)
    }

    @discardableResult
    func reconcile(enabledPreference: Bool) async -> Bool {
        await refreshAuthorizationStatus(reason: enabledPreference ? "enabledPreference" : "disabledPreference")

        switch Self.runtimePlan(
            enabledPreference: enabledPreference,
            authorizationStatus: authorizationStatus
        ) {
        case .disabled:
            return false
        case .requestAuthorization:
            return await requestAuthorization()
        case .enabled:
            return true
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            await refreshAuthorizationStatus(reason: "requestAuthorization")
            return granted && Self.isAuthorized(authorizationStatus)
        } catch {
            print("[Notifications] Authorization request failed: \(error)")
            await refreshAuthorizationStatus(reason: "requestAuthorizationFailed")
            return false
        }
    }

    func refreshAuthorizationStatus(reason: String) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        print("[Notifications] Authorization (\(reason)): \(authorizationStatus.rawValue)")
    }

    static func runtimePlan(
        enabledPreference: Bool,
        authorizationStatus: UNAuthorizationStatus
    ) -> RuntimePlan {
        guard enabledPreference else {
            return .disabled
        }

        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .enabled
        case .notDetermined:
            return .requestAuthorization
        case .denied:
            return .disabled
        @unknown default:
            return .disabled
        }
    }

    static func isAuthorized(_ authorizationStatus: UNAuthorizationStatus) -> Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }
}
