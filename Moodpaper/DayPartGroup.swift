import Foundation

/// Progressive-disclosure groups over the engine's nine detailed periods.
/// This is not Simple mode: Night stays its own group so solar Night timing
/// remains independently assignable.
enum DayPartGroup: String, CaseIterable, Identifiable {
    case morning
    case day
    case evening
    case night

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .morning: return "Morning"
        case .day: return "Day"
        case .evening: return "Evening"
        case .night: return "Night"
        }
    }

    var slots: [TimeSlot] {
        switch self {
        case .morning: return [.deepNight, .dawn, .sunrise, .morning]
        case .day: return [.midday, .afternoon]
        case .evening: return [.goldenHour, .dusk]
        case .night: return [.evening]
        }
    }
}

enum DayPartGroupRepresentation: Equatable {
    case usingVibePhotos
    case assigned(filenames: [String])
    case mixed
}
