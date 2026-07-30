import Foundation
import SwiftUI
internal import Combine

// MARK: - Mood

// A Mood is the app's organizing concept after the Moodpaper pivot: a named,
// saveable set of per-slot wallpaper assignments. The user creates Moods
// (for example "Work Week" or "Cozy Weekend"), fills each time slot with
// their own images, and switches the whole desktop personality in one click.
//
// Assignments are the filesystem, not a stored list: the images living in
// Moodpaper/Moods/<moodID>/<slotID>/ ARE the assignment for that slot.
// Copy-on-import (the established UserWallpaperManager pattern) means moved
// or deleted source files can never leave a Mood pointing at nothing.
struct Mood: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    let createdAt: Date
    var updatedAt: Date
}

// MARK: - Mood Store

// Owns the Mood catalog and its files.
//
// Persistence:
// - Metadata (the mood list) lives in moods.json inside the Moods folder,
//   so the catalog travels with the image files it describes.
// - The active mood ID lives in UserDefaults ("moods.activeID"), following
//   the app's one-direction flow: UI writes defaults, the engine reads them.
// - Wallpaper files live under Application Support at
//   Moodpaper/Moods/<moodID>/<slotID>/ .
@MainActor
final class MoodStore: ObservableObject {
    static let shared = MoodStore()

    static let activeMoodIDKey = "moods.activeID"
    static let starterMoodName = "Everyday"

    @Published private(set) var moods: [Mood] = []
    @Published private(set) var activeMoodID: String? = nil

    /// Fired whenever the active mood actually changes (activate, or the
    /// fallback after deleting the active mood). The engine subscribes so a
    /// mood switch refreshes the desktop immediately; the store owns the
    /// side effect so no UI call site can forget it (lessons.md 2026-07-13).
    var onActiveMoodChange: (() -> Void)?

    private let fileManager = FileManager.default
    private let defaults: UserDefaults
    private let moodsRootURL: URL

    // MARK: Init

    /// The shared instance stores under Application Support/Moodpaper/Moods.
    /// Tests inject a scratch directory and a private defaults suite so they
    /// never touch real user state.
    init(baseURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let base = baseURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moodpaper")
        self.moodsRootURL = base.appendingPathComponent("Moods")
        load()
        ensureStarterMood()
    }

    // MARK: - Read helpers

    var activeMood: Mood? {
        guard let id = activeMoodID else { return nil }
        return moods.first { $0.id == id }
    }

    func mood(id: String) -> Mood? {
        moods.first { $0.id == id }
    }

    /// Folder holding a mood's images for one slot. Created on demand so
    /// callers can always write into it.
    func folderURL(for slot: TimeSlot, in mood: Mood) -> URL {
        let url = moodsRootURL
            .appendingPathComponent(mood.id)
            .appendingPathComponent(slot.rawValue)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The images assigned to one slot of a mood, sorted by filename so
    /// ordering is stable across launches.
    func wallpapers(for slot: TimeSlot, in mood: Mood) -> [URL] {
        let folder = moodsRootURL
            .appendingPathComponent(mood.id)
            .appendingPathComponent(slot.rawValue)
        let contents = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { ["jpg", "jpeg", "png", "heic", "heif", "tiff", "bmp"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func wallpaperCount(for slot: TimeSlot, in mood: Mood) -> Int {
        wallpapers(for: slot, in: mood).count
    }

    func totalWallpaperCount(in mood: Mood) -> Int {
        TimeSlot.allCases.reduce(0) { $0 + wallpaperCount(for: $1, in: mood) }
    }

    // MARK: - CRUD

    /// Create a new mood. Returns nil when the trimmed name is empty.
    @discardableResult
    func create(name: String) -> Mood? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let mood = Mood(
            id: UUID().uuidString.lowercased(),
            name: trimmed,
            createdAt: Date(),
            updatedAt: Date()
        )
        moods.append(mood)
        try? fileManager.createDirectory(
            at: moodsRootURL.appendingPathComponent(mood.id),
            withIntermediateDirectories: true
        )
        save()
        AnalyticsManager.shared.log(.moodCreated, metadata: ["id": mood.id])
        return mood
    }

    func rename(_ mood: Mood, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = moods.firstIndex(where: { $0.id == mood.id }) else { return }
        guard moods[idx].name != trimmed else { return }
        moods[idx].name = trimmed
        moods[idx].updatedAt = Date()
        save()
    }

    /// Duplicate a mood including every slot's images. Returns nil when the
    /// source mood no longer exists or the file copy fails.
    @discardableResult
    func duplicate(_ mood: Mood) -> Mood? {
        guard moods.contains(where: { $0.id == mood.id }) else { return nil }
        guard let copy = create(name: "\(mood.name) Copy") else { return nil }
        let sourceRoot = moodsRootURL.appendingPathComponent(mood.id)
        let destinationRoot = moodsRootURL.appendingPathComponent(copy.id)
        do {
            for slotFolder in (try? fileManager.contentsOfDirectory(
                at: sourceRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? [] {
                let destination = destinationRoot.appendingPathComponent(slotFolder.lastPathComponent)
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: slotFolder, to: destination)
            }
        } catch {
            print("[MoodStore] Failed to duplicate mood files: \(error)")
            delete(copy)
            return nil
        }
        return copy
    }

    /// Delete a mood and its files. The active mood falls back to the first
    /// remaining mood; deleting the last mood recreates the starter so the
    /// app never has zero moods.
    func delete(_ mood: Mood) {
        guard let idx = moods.firstIndex(where: { $0.id == mood.id }) else { return }
        moods.remove(at: idx)
        try? fileManager.removeItem(at: moodsRootURL.appendingPathComponent(mood.id))
        if activeMoodID == mood.id {
            setActiveMoodID(moods.first?.id)
        }
        save()
        ensureStarterMood()
        AnalyticsManager.shared.log(.moodDeleted, metadata: ["id": mood.id])
    }

    // MARK: - Active mood

    func activate(_ mood: Mood) {
        guard moods.contains(where: { $0.id == mood.id }) else { return }
        guard activeMoodID != mood.id else { return }
        setActiveMoodID(mood.id)
        AnalyticsManager.shared.log(.moodActivated, metadata: ["id": mood.id])
    }

    // MARK: - Wallpaper files

    /// Copy-on-import: each image is decoded and rewritten as a normalized
    /// JPEG inside the mood's slot folder, so the original file can move or
    /// disappear without breaking the mood.
    func importWallpapers(_ urls: [URL], to slot: TimeSlot, in mood: Mood) throws {
        let destinationFolder = folderURL(for: slot, in: mood)
        for url in urls {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
            let destination = Self.importDestination(for: url, in: destinationFolder)
            try writeNormalizedImage(from: url, to: destination)
            print("Horizon: Imported wallpaper \(destination.lastPathComponent) to mood \(mood.name), slot \(slot.displayName)")
        }
        touch(mood)
        objectWillChange.send()
        AnalyticsManager.shared.log(.moodWallpaperImported, metadata: [
            "moodID": mood.id,
            "slot": slot.rawValue,
            "count": "\(urls.count)"
        ])
    }

    func removeWallpaper(_ url: URL, from mood: Mood) throws {
        try fileManager.removeItem(at: url)
        touch(mood)
        objectWillChange.send()
    }

    /// Sanitized, collision-free destination filename. Same rule as
    /// UserWallpaperManager.normalizedImportDestination.
    static func importDestination(for sourceURL: URL, in directory: URL) -> URL {
        let rawBaseName = sourceURL.deletingPathExtension().lastPathComponent
        let sanitizedBaseName = rawBaseName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
        let baseName = sanitizedBaseName.isEmpty ? "wallpaper" : sanitizedBaseName
        let uniqueSuffix = UUID().uuidString.lowercased().prefix(8)
        return directory.appendingPathComponent("\(baseName)-\(uniqueSuffix).jpg")
    }

    // MARK: - Persistence

    private var metadataURL: URL {
        moodsRootURL.appendingPathComponent("moods.json")
    }

    private func load() {
        try? fileManager.createDirectory(at: moodsRootURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder().decode([Mood].self, from: data) {
            moods = decoded
        }
        let storedActiveID = defaults.string(forKey: Self.activeMoodIDKey)
        activeMoodID = moods.contains { $0.id == storedActiveID } ? storedActiveID : nil
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(moods)
            try data.write(to: metadataURL)
        } catch {
            print("[MoodStore] Failed to save moods.json: \(error)")
        }
    }

    /// Guarantee at least one mood exists and one is active. Runs at init
    /// (first run creates the starter) and after deletes.
    private func ensureStarterMood() {
        if moods.isEmpty {
            create(name: Self.starterMoodName)
        }
        if activeMood == nil {
            setActiveMoodID(moods.first?.id)
        }
    }

    private func setActiveMoodID(_ id: String?) {
        let changed = activeMoodID != id
        activeMoodID = id
        if let id {
            defaults.set(id, forKey: Self.activeMoodIDKey)
        } else {
            defaults.removeObject(forKey: Self.activeMoodIDKey)
        }
        if changed {
            onActiveMoodChange?()
        }
    }

    private func touch(_ mood: Mood) {
        guard let idx = moods.firstIndex(where: { $0.id == mood.id }) else { return }
        moods[idx].updatedAt = Date()
        save()
    }
}
