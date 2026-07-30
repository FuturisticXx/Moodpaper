import Foundation
internal import Combine

// MARK: - Analytics Event Types

enum AnalyticsEvent: String, Codable {
    case appLaunch = "app_launch"
    case onboardingCompleted = "onboarding_completed"
    case wallpaperChanged = "wallpaper_changed"
    case settingsChanged = "settings_changed"
    case libraryOpened = "library_opened"
    case wallpaperPreviewed = "wallpaper_previewed"
    case wallpaperSet = "wallpaper_set"
    case focusModeToggled = "focus_mode_toggled"
    case moodCreated = "mood_created"
    case moodActivated = "mood_activated"
    case moodDeleted = "mood_deleted"
    case moodWallpaperImported = "mood_wallpaper_imported"
}

// MARK: - Analytics Event

struct AnalyticsEventLog: Codable {
    let eventType: AnalyticsEvent
    let timestamp: Date
    let metadata: [String: String]

    init(eventType: AnalyticsEvent, metadata: [String: String] = [:]) {
        self.eventType = eventType
        self.timestamp = Date()
        self.metadata = metadata
    }
}

// MARK: - Analytics Manager

@MainActor
class AnalyticsManager: ObservableObject {
    static let shared = AnalyticsManager()

    // Cap reduced from 1000 → 250. Analytics are local-only and every consumer
    // reads recent windows (uniqueDaysActive, eventsSince, eventCount), so the
    // older 750 events were never read — they just made every save re-encode
    // a ~100-200KB JSON blob to UserDefaults.
    private let maxEvents = 250
    private let eventsKey = "analytics_events"
    // Coalesce save bursts (wallpaper changes can fire several events in a
    // row) so we encode at most once every saveDebounceInterval seconds.
    private static let saveDebounceInterval: TimeInterval = 5
    private var saveDebounceTimer: Timer?

    @Published var events: [AnalyticsEventLog] = []

    private init() {
        loadEvents()
    }

    deinit {
        saveDebounceTimer?.invalidate()
    }

    // MARK: - Event Logging

    func log(_ eventType: AnalyticsEvent, metadata: [String: String] = [:]) {
        let event = AnalyticsEventLog(eventType: eventType, metadata: metadata)
        events.append(event)

        // Keep only the most recent events
        if events.count > maxEvents {
            events = Array(events.suffix(maxEvents))
        }

        scheduleDebouncedSave()
        print("[Analytics] \(eventType.rawValue) - \(metadata)")
    }

    private func scheduleDebouncedSave() {
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.saveDebounceInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveEvents()
            }
        }
    }

    // MARK: - Persistence

    private func loadEvents() {
        guard let data = UserDefaults.standard.data(forKey: eventsKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([AnalyticsEventLog].self, from: data)
            events = decoded
        } catch {
            print("[AnalyticsManager] Failed to decode events: \(error)")
        }
    }

    private func saveEvents() {
        do {
            let encoded = try JSONEncoder().encode(events)
            UserDefaults.standard.set(encoded, forKey: eventsKey)
        } catch {
            print("[AnalyticsManager] Failed to encode events: \(error)")
        }
    }

    // MARK: - Analytics Queries

    func eventCount(for eventType: AnalyticsEvent, since date: Date? = nil) -> Int {
        let filteredEvents: [AnalyticsEventLog]
        if let date = date {
            filteredEvents = events.filter { $0.timestamp >= date }
        } else {
            filteredEvents = events
        }
        return filteredEvents.filter { $0.eventType == eventType }.count
    }

    func eventsSince(_ date: Date) -> [AnalyticsEventLog] {
        events.filter { $0.timestamp >= date }
    }

    func uniqueDaysActive() -> Int {
        let calendar = Calendar.current
        let uniqueDays = Set(events.map { calendar.startOfDay(for: $0.timestamp) })
        return uniqueDays.count
    }

    // MARK: - Export

    func exportToCSV() -> String {
        var csv = "Event Type,Timestamp,Metadata\n"
        for event in events {
            let timestamp = ISO8601DateFormatter().string(from: event.timestamp)
            let sanitizedMetadata = sanitizedMetadataForExport(event.metadata)
            let metadataString = sanitizedMetadata.map { "\($0.key):\($0.value)" }.joined(separator: "|")
            csv += "\(event.eventType.rawValue),\(timestamp),\(metadataString)\n"
        }
        return csv
    }

    private func sanitizedMetadataForExport(_ metadata: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]
        for (key, value) in metadata {
            switch key {
            case "transaction_id", "url", "id":
                sanitized[key] = "[redacted]"
            default:
                sanitized[key] = value
            }
        }
        return sanitized
    }

    func clearEvents() {
        events = []
        saveDebounceTimer?.invalidate()
        saveDebounceTimer = nil
        UserDefaults.standard.removeObject(forKey: eventsKey)
        print("[Analytics] Events cleared")
    }
}
