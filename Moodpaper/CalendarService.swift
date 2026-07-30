import EventKit
import Foundation
internal import Combine

@MainActor
final class CalendarService: ObservableObject {
    static let shared = CalendarService()

    enum RuntimePlan: Equatable {
        case stopAndClear
        case startAndRefresh
    }

    @Published var isInMeeting: Bool = false
    @Published var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var currentMeetingTitle: String? = nil

    private let store = EKEventStore()
    private var timer: Timer?

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if authorizationStatus == .fullAccess {
            startMonitoring()
        }
    }

    // MARK: - Access

    func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            await MainActor.run {
                self.authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                if !granted {
                    self.clearMeetingState()
                }
            }
        } catch {
            print("CalendarService: Access request failed: \(error)")
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard timer == nil else { return }
        checkForMeeting()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.checkForMeeting()
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func reconcileRuntimeState(shouldMonitor: Bool, reason: String) {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        print("[CalendarService] Reconciling runtime state (\(reason)): status=\(authorizationStatus.rawValue), shouldMonitor=\(shouldMonitor)")

        switch Self.runtimePlan(authorizationStatus: authorizationStatus, shouldMonitor: shouldMonitor) {
        case .stopAndClear:
            stopMonitoring()
            clearMeetingState()
        case .startAndRefresh:
            startMonitoring()
            checkForMeeting()
        }
    }

    func reconcileAuthorizationStatus(reason: String) {
        reconcileRuntimeState(shouldMonitor: true, reason: reason)
    }

    static func runtimePlan(authorizationStatus: EKAuthorizationStatus, shouldMonitor: Bool) -> RuntimePlan {
        authorizationStatus == .fullAccess && shouldMonitor ? .startAndRefresh : .stopAndClear
    }

    // MARK: - Meeting Detection

    func checkForMeeting() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard authorizationStatus == .fullAccess else {
            clearMeetingState()
            return
        }

        let now = Date()
        let calendars = store.calendars(for: .event)
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-300), // 5 min buffer for late joiners
            end: now.addingTimeInterval(60),
            calendars: calendars
        )
        let events = store.events(matching: predicate)

        // Find an event actively happening right now
        let active = events.first { event in
            event.startDate <= now && event.endDate > now && !event.isAllDay
        }

        isInMeeting = active != nil
        currentMeetingTitle = active?.title
    }

    // MARK: - Helpers

    private func clearMeetingState() {
        isInMeeting = false
        currentMeetingTitle = nil
    }

    var statusDescription: String {
        switch authorizationStatus {
        case .fullAccess:
            return isInMeeting ? "In a meeting\(currentMeetingTitle.map { ": \($0)" } ?? "")" : "Not in a meeting"
        case .denied, .restricted:
            return "Calendar access denied"
        case .notDetermined:
            return "Calendar access not requested"
        case .writeOnly:
            return "Calendar Full Access required"
        @unknown default:
            return "Unknown"
        }
    }
}
