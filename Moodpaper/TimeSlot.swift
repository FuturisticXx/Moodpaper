import Foundation

enum TimeSlot: String, Codable, CaseIterable, Identifiable {
    case deepNight = "DeepNight"
    case dawn = "Dawn"
    case sunrise = "Sunrise"
    case morning = "Morning"
    case midday = "Midday"
    case afternoon = "Afternoon"
    case goldenHour = "GoldenHour"
    case dusk = "Dusk"
    case evening = "Evening"

    var id: String { rawValue }

    // Kebab-case ID matching the engine's slot convention ("deep-night", "golden-hour")
    var slotID: String {
        switch self {
        case .deepNight:  return "deep-night"
        case .dawn:       return "dawn"
        case .sunrise:    return "sunrise"
        case .morning:    return "morning"
        case .midday:     return "midday"
        case .afternoon:  return "afternoon"
        case .goldenHour: return "golden-hour"
        case .dusk:       return "dusk"
        case .evening:    return "evening"
        }
    }

    var displayName: String {
        switch self {
        case .deepNight: return "Deep Night"
        case .dawn: return "Dawn"
        case .sunrise: return "Sunrise"
        case .morning: return "Morning"
        case .midday: return "Midday"
        case .afternoon: return "Afternoon"
        case .goldenHour: return "Golden Hour"
        case .dusk: return "Dusk"
        case .evening: return "Night"
        }
    }

    var timeRange: String {
        switch self {
        case .deepNight: return "12 AM - 4 AM"
        case .dawn: return "4 AM - 6 AM"
        case .sunrise: return "6 AM - 8 AM"
        case .morning: return "8 AM - 12 PM"
        case .midday: return "12 PM - 3 PM"
        case .afternoon: return "3 PM - 5 PM"
        case .goldenHour: return "5 PM - 8 PM"
        case .dusk: return "8 PM - 10 PM"
        case .evening: return "10 PM - 12 AM"
        }
    }

    static func from(hour: Int) -> TimeSlot {
        switch hour {
        case 0..<4: return .deepNight
        case 4..<6: return .dawn
        case 6..<8: return .sunrise
        case 8..<12: return .morning
        case 12..<15: return .midday
        case 15..<17: return .afternoon
        case 17..<20: return .goldenHour
        case 20..<22: return .dusk
        default: return .evening
        }
    }
}
