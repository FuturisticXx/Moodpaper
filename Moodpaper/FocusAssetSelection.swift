import Foundation

/// The user's explicit Focus wallpapers: Catalog asset IDs and nothing else.
/// Stored as a sorted, deduplicated JSON array in UserDefaults so identity
/// survives file moves, Vibe edits, and Vibe deletion. An empty or entirely
/// unresolvable set means "use the Focus time slot", the original behavior.
enum FocusAssetSelection {
    static let defaultsKey = "focus.assetIDs"

    static func assetIDs(defaults: UserDefaults = .standard) -> [String] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return normalized(decoded)
    }

    static func setAssetIDs(_ ids: [String], defaults: UserDefaults = .standard) {
        let normalizedIDs = normalized(ids)
        guard !normalizedIDs.isEmpty else {
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        if let data = try? JSONEncoder().encode(normalizedIDs) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    static func contains(_ assetID: String, defaults: UserDefaults = .standard) -> Bool {
        assetIDs(defaults: defaults).contains(assetID)
    }

    static func add(_ assetID: String, defaults: UserDefaults = .standard) {
        setAssetIDs(assetIDs(defaults: defaults) + [assetID], defaults: defaults)
    }

    static func remove(_ assetID: String, defaults: UserDefaults = .standard) {
        setAssetIDs(assetIDs(defaults: defaults).filter { $0 != assetID }, defaults: defaults)
    }

    static func toggle(_ assetID: String, defaults: UserDefaults = .standard) {
        if contains(assetID, defaults: defaults) {
            remove(assetID, defaults: defaults)
        } else {
            add(assetID, defaults: defaults)
        }
    }

    /// Only well-formed asset IDs are kept: never a path, never empty.
    static func isValidAssetID(_ candidate: String) -> Bool {
        !candidate.isEmpty && !candidate.contains("/") && !candidate.contains("\\")
    }

    /// Sorted and deduplicated so persisted order never depends on user
    /// click order or dictionary iteration.
    static func normalized(_ ids: [String]) -> [String] {
        Array(Set(ids.filter(isValidAssetID))).sorted()
    }
}
