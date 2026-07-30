import Foundation

enum HorizonRuntimeStyle {
    static var forceLegacyGlass: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-MoodpaperForceLegacyGlass"),
           arguments.indices.contains(index + 1) {
            return ["1", "true", "yes"].contains(arguments[index + 1].lowercased())
        }
        return UserDefaults.standard.bool(forKey: "MoodpaperForceLegacyGlass")
        #else
        return false
        #endif
    }
}
