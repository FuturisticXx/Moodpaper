import Foundation

enum HorizonScheduleDefaults {
    static let slotEnabledKey = "schedule.slotEnabled"
    static let wallpapersPerDayKey = "schedule.wallpapersPerDay"
    static let moodPresetEnabledKey = "mood.presetEnabled"
    static let timeSlotModeKey = "schedule.timeSlotMode"
    static let pauseRotationKey = "schedule.pauseRotation"
    static let debugLoggingEnabledKey = "diagnostics.debugLoggingEnabled"
    static let nightStartKey = "schedule.nightStart"
    static let notifyOnSlotChangeKey = "notifyOnSlotChange"
    static let syncAllSpacesKey = "schedule.syncAllSpaces"

    /// Default value for `syncAllSpacesKey` when the user has never explicitly
    /// toggled it. Returned from getters as the `object(forKey:) as? Bool ?? default`
    /// fallback so explicit-false stays false and never-touched flips to the
    /// product default.
    static let syncAllSpacesDefault = true

    /// User-facing preference values for when the "Night" slot begins.
    /// Stored as a string in UserDefaults so it's human-readable during debugging.
    enum NightStart: String, CaseIterable, Identifiable {
        case atSunset       = "atSunset"
        case oneHourAfter   = "oneHourAfter"   // default
        case twoHoursAfter  = "twoHoursAfter"
        case tenPM          = "tenPM"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .atSunset:      return "At sunset"
            case .oneHourAfter:  return "1 hour after sunset"
            case .twoHoursAfter: return "2 hours after sunset"
            case .tenPM:         return "At 10 PM"
            }
        }
    }

    static var currentNightStart: NightStart {
        let raw = UserDefaults.standard.string(forKey: nightStartKey) ?? NightStart.oneHourAfter.rawValue
        return NightStart(rawValue: raw) ?? .oneHourAfter
    }

    /// Minutes-from-midnight when the Night ("evening") slot begins, given the Dusk
    /// start (sunset) in minutes. Clamped so Night never precedes Dusk and never
    /// runs past 23:30, preserving at least a 30-minute Night band.
    static func eveningStartMinutes(duskStart: Int) -> Int {
        eveningStartMinutes(duskStart: duskStart, nightStart: currentNightStart)
    }

    static func eveningStartMinutes(duskStart: Int, nightStart: NightStart) -> Int {
        let ceiling = 23 * 60 + 30
        // Polar regions can produce duskStart >= ceiling (midnight sun). Without
        // this guard the standard clamp inverts (floor > ceiling) and returns a
        // value earlier than dusk, which corrupts slot duration math downstream.
        guard duskStart < ceiling else { return ceiling }
        let raw: Int
        switch nightStart {
        case .atSunset:      raw = duskStart
        case .oneHourAfter:  raw = duskStart + 60
        case .twoHoursAfter: raw = duskStart + 120
        case .tenPM:         raw = 22 * 60
        }
        return min(max(raw, duskStart), ceiling)
    }

    static let orderedSlotIDs: [String] = [
        "deep-night",
        "dawn",
        "sunrise",
        "morning",
        "midday",
        "afternoon",
        "golden-hour",
        "dusk",
        "evening",
    ]

    static let simpleSlotIDs: [String] = [
        "morning",
        "afternoon",
        "evening",
    ]

    static func slotIDs(for mode: String) -> [String] {
        mode == "Simple" ? simpleSlotIDs : orderedSlotIDs
    }

    static func normalizedSlot(_ slot: String, mode: String) -> String {
        guard mode == "Simple" else { return slot }
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

    static func enabledSlotIDs(mode: String, defaults: UserDefaults = .standard) -> [String] {
        let slots = slotIDs(for: mode)
        var enabledMap = slots.reduce(into: [String: Bool]()) {
            $0[$1] = true
        }

        if let data = defaults.data(forKey: slotEnabledKey),
           let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) {
            for slotID in slots {
                if let value = decoded[slotID] {
                    enabledMap[slotID] = value
                }
            }
        }

        return slots.filter { enabledMap[$0] ?? true }
    }

    static func validatedFocusSlot(
        preferred slot: String,
        mode: String,
        defaults: UserDefaults = .standard
    ) -> String {
        let slots = slotIDs(for: mode)
        let enabledSlots = enabledSlotIDs(mode: mode, defaults: defaults)
        let fallbackSlots = enabledSlots.isEmpty ? slots : enabledSlots
        let normalized = normalizedSlot(slot, mode: mode)

        if fallbackSlots.contains(normalized) {
            return normalized
        }

        return fallbackSlots.first ?? "morning"
    }
}
