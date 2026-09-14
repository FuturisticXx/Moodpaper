import Foundation
import SwiftUI
internal import Combine

// MARK: - Mood

// A Mood is the app's organizing concept after the Moodpaper pivot: a named,
// saveable set of per-slot wallpaper assignments. The user creates Moods
// (for example "Work Week" or "Cozy Weekend"), fills each time slot with
// their own images, and switches the whole desktop personality in one click.
//
// Assignments are Catalog v2 memberships once migrated (one canonical file,
// many Vibes). Until migration, legacy folder copies under
// Moodpaper/Moods/<moodID>/<slotID>/ remain the assignment.
struct Mood: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    let createdAt: Date
    var updatedAt: Date
    /// Copies per day while this Vibe is active. Nil only on catalogs written
    /// before Phase 4; `MoodStore` fills it from the then-current global
    /// cadence on first load.
    var wallpapersPerDay: Double?

    var isUnnamed: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayName: String {
        isUnnamed ? "My Wallpapers" : name
    }
}

struct WallpaperImportSummary: Equatable, Sendable {
    let discoveredCount: Int
    let importedCount: Int
    let failedCount: Int
}

/// Where a wallpaper lives inside a Vibe. The AllDay folder remains the
/// internal fallback pool; user-facing copy says "throughout the day."
enum WallpaperPlacement: Equatable, Hashable {
    case throughoutTheDay
    case during(TimeSlot)

    var badgeTitle: String {
        switch self {
        case .throughoutTheDay:
            return "Throughout the day"
        case .during(let slot):
            return slot.displayName
        }
    }
}

struct WallpaperLibraryItem: Identifiable, Hashable {
    let url: URL
    let placement: WallpaperPlacement
    var assetID: String? = nil
    /// Multi-Vibe membership when Catalog v2 is the source of truth.
    var vibeIDs: [String] = []
    var id: URL { url }
}

// MARK: - Mood Store

// Owns the Mood catalog and its files.
//
// Persistence:
// - Vibe metadata lives in moods.json inside the Moods folder.
// - Catalog v2 (catalog.json + Catalog/Assets) is the source of truth for
//   wallpaper identity, memberships, and time-slot assignments once migrated.
// - Legacy Moods/<moodID>/<slotID>/ folders remain until a later cleanup.
// - The active mood ID lives in UserDefaults ("moods.activeID").
@MainActor
final class MoodStore: ObservableObject {
    static let shared = MoodStore()

    static let activeMoodIDKey = "moods.activeID"
    static let allDayFolderName = "AllDay"

    private nonisolated static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "bmp"
    ]

    @Published private(set) var moods: [Mood] = []
    @Published private(set) var activeMoodID: String? = nil
    /// Catalog v2 when migration (or first catalog-backed import) has completed.
    private(set) var catalog: WallpaperCatalog?

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
    /// never touch real user state. XCTest hosts must not load or migrate
    /// that live Application Support path.
    init(baseURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let base = baseURL ?? LibraryMigration.resolvedLiveLibraryRoot()
        self.moodsRootURL = base.appendingPathComponent("Moods")
        if LibraryMigration.testHostMustNotLoadLibrary(at: base) {
            return
        }
        load()
        adoptCatalogIfNeeded()
        migrateVibeCadencesIfNeeded()
        restoreActiveMoodIfNeeded()
    }

    var usesCatalog: Bool { catalog?.isReady == true }

    // MARK: - Read helpers

    /// The library root (the folder containing `Moods/`). Sandboxed and
    /// non-sandboxed builds resolve this to different places, which is what
    /// `LegacyLibraryMigration` exists to bridge.
    var storageRootURL: URL {
        moodsRootURL.deletingLastPathComponent()
    }

    /// True when the catalog holds no images at all — either no Vibes, or
    /// only empty ones. Both are states a fresh sandbox container lands in
    /// when the user's real library was written by a non-sandboxed build.
    var isLibraryEmpty: Bool {
        moods.allSatisfy { totalWallpaperCount(in: $0) == 0 }
    }

    /// Re-read the catalog after files changed underneath the store.
    func reload() {
        if LibraryMigration.testHostMustNotLoadLibrary(at: storageRootURL) {
            return
        }
        load()
        adoptCatalogIfNeeded()
        migrateVibeCadencesIfNeeded()
        restoreActiveMoodIfNeeded()
    }

    /// Copy a previous install's library in, then adopt it. Returns the
    /// summary so callers can report what arrived.
    @discardableResult
    func importLegacyLibrary(from legacyRoot: URL) throws -> LegacyLibraryMigration.Summary {
        let summary = try LegacyLibraryMigration.importLibrary(
            from: legacyRoot,
            into: storageRootURL
        )
        reload()
        if activeMoodID == nil {
            setActiveMoodID(moods.first?.id)
        }
        defaults.set(true, forKey: LegacyLibraryMigration.didImportKey)
        return summary
    }

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

    /// Shared fallback pool used whenever a mood has no wallpapers assigned
    /// specifically to the current time slot.
    func allDayFolderURL(in mood: Mood) -> URL {
        let url = moodsRootURL
            .appendingPathComponent(mood.id)
            .appendingPathComponent(Self.allDayFolderName)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The images assigned to one slot of a mood, sorted by filename so
    /// ordering is stable across launches.
    func wallpapers(for slot: TimeSlot, in mood: Mood) -> [URL] {
        if usesCatalog {
            return catalogURLs(in: mood) { $0.includes(slot: slot) }
        }
        let folder = moodsRootURL
            .appendingPathComponent(mood.id)
            .appendingPathComponent(slot.rawValue)
        return wallpaperURLs(in: folder)
    }

    func allDayWallpapers(in mood: Mood) -> [URL] {
        if usesCatalog {
            return catalogURLs(in: mood) { $0.throughoutTheDay }
        }
        let folder = moodsRootURL
            .appendingPathComponent(mood.id)
            .appendingPathComponent(Self.allDayFolderName)
        return wallpaperURLs(in: folder)
    }

    /// Slot-specific choices intentionally override the shared pool. Empty
    /// slots inherit All Day, keeping simple moods simple without weakening
    /// the existing per-time-slot customization model.
    func effectiveWallpapers(for slot: TimeSlot, in mood: Mood) -> [URL] {
        let slotWallpapers = wallpapers(for: slot, in: mood)
        return slotWallpapers.isEmpty ? allDayWallpapers(in: mood) : slotWallpapers
    }

    private func wallpaperURLs(in folder: URL) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { Self.supportedImageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func wallpaperCount(for slot: TimeSlot, in mood: Mood) -> Int {
        wallpapers(for: slot, in: mood).count
    }

    func totalWallpaperCount(in mood: Mood) -> Int {
        if usesCatalog {
            return Set((catalog?.memberships(forMoodID: mood.id) ?? []).map(\.assetID)).count
        }
        return allDayWallpapers(in: mood).count
            + TimeSlot.allCases.reduce(0) { $0 + wallpaperCount(for: $1, in: mood) }
    }

    // MARK: - CRUD

    /// Create a Vibe. An empty name is allowed: playback does not require
    /// naming a style first. New Vibes inherit the Settings default cadence.
    @discardableResult
    func create(name: String) -> Mood? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let mood = Mood(
            id: UUID().uuidString.lowercased(),
            name: trimmed,
            createdAt: Date(),
            updatedAt: Date(),
            wallpapersPerDay: defaultWallpapersPerDayForNewVibes
        )
        moods.append(mood)
        try? fileManager.createDirectory(
            at: moodsRootURL.appendingPathComponent(mood.id),
            withIntermediateDirectories: true
        )
        save()
        if activeMoodID == nil {
            setActiveMoodID(mood.id)
        }
        AnalyticsManager.shared.log(.moodCreated, metadata: ["id": mood.id])
        return mood
    }

    /// A playable Vibe so wallpapers can be added without a naming step.
    /// Reuses the active Vibe, otherwise the first catalog entry, otherwise
    /// creates an unnamed default.
    @discardableResult
    func ensurePlayableVibe() -> Mood {
        if let activeMood {
            return activeMood
        }
        if let first = moods.first {
            activate(first)
            return first
        }
        return create(name: "")!
    }

    func rename(_ mood: Mood, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = moods.firstIndex(where: { $0.id == mood.id }) else { return }
        guard moods[idx].name != trimmed else { return }
        moods[idx].name = trimmed
        moods[idx].updatedAt = Date()
        save()
    }

    func effectiveWallpapersPerDay(for mood: Mood?) -> Double {
        if let stored = mood?.wallpapersPerDay {
            return HorizonScheduleDefaults.resolvedWallpapersPerDay(stored)
        }
        return defaultWallpapersPerDayForNewVibes
    }

    func setWallpapersPerDay(_ value: Double, for mood: Mood) {
        guard let idx = moods.firstIndex(where: { $0.id == mood.id }) else { return }
        let capped = min(max(value, 1), 48)
        guard moods[idx].wallpapersPerDay != capped else { return }
        moods[idx].wallpapersPerDay = capped
        moods[idx].updatedAt = Date()
        save()
        objectWillChange.send()
        if mood.id == activeMoodID {
            WallpaperManager.shared.updateNextChangeCountdown()
        }
    }

    var defaultWallpapersPerDayForNewVibes: Double {
        HorizonScheduleDefaults.resolvedWallpapersPerDay(
            defaults.double(forKey: HorizonScheduleDefaults.wallpapersPerDayKey)
        )
    }

    /// Existing Vibes without a stored cadence copy the current global value
    /// so the user's effective frequency does not jump to a silent 8.
    func migrateVibeCadencesIfNeeded() {
        let fallback = defaultWallpapersPerDayForNewVibes
        var changed = false
        for index in moods.indices where moods[index].wallpapersPerDay == nil {
            moods[index].wallpapersPerDay = fallback
            changed = true
        }
        if changed {
            save()
        }
    }

    /// Duplicate a mood including every slot's images. Returns nil when the
    /// source mood no longer exists or the file copy fails.
    @discardableResult
    func duplicate(_ mood: Mood) -> Mood? {
        guard moods.contains(where: { $0.id == mood.id }) else { return nil }
        let copyName = mood.isUnnamed ? "" : "\(mood.name) Copy"
        guard let copy = create(name: copyName) else { return nil }
        setWallpapersPerDay(effectiveWallpapersPerDay(for: mood), for: copy)
        let sourceRoot = moodsRootURL.appendingPathComponent(mood.id)
        let destinationRoot = moodsRootURL.appendingPathComponent(copy.id)
        do {
            if usesCatalog {
                try duplicateCatalogMemberships(from: mood, to: copy)
            } else {
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
            }
        } catch {
            print("[MoodStore] Failed to duplicate mood files: \(error)")
            delete(copy)
            return nil
        }
        // `copy` is the snapshot `create` handed back, taken before the
        // cadence was stored. Return the persisted entry so callers see it.
        return moods.first { $0.id == copy.id } ?? copy
    }

    /// Delete a mood and its files. The active mood falls back to the first
    /// remaining mood, or to no active mood when the user deletes the last.
    func delete(_ mood: Mood) {
        guard let idx = moods.firstIndex(where: { $0.id == mood.id }) else { return }
        moods.remove(at: idx)
        if usesCatalog, var catalog {
            catalog.memberships.removeAll { $0.moodID == mood.id }
            self.catalog = catalog
            saveCatalog()
        }
        try? fileManager.removeItem(at: moodsRootURL.appendingPathComponent(mood.id))
        if activeMoodID == mood.id {
            setActiveMoodID(moods.first?.id)
        }
        save()
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

    /// Imports image files, folders, or a mixture of both into one time slot
    /// of a mood. Shares the All Day pipeline, so a slot import walks folders
    /// recursively and one unreadable file never discards the rest — before
    /// this the slot importer threw on the first failure and abandoned every
    /// remaining file with nothing surfaced to the user.
    func importWallpapers(
        from urls: [URL],
        to slot: TimeSlot,
        in mood: Mood
    ) async throws -> WallpaperImportSummary {
        try ensureCatalogUnlessMigrationBlocked()
        return try await importItems(
            from: urls,
            to: folderURL(for: slot, in: mood),
            in: mood,
            placement: .during(slot),
            slotName: slot.rawValue
        )
    }

    /// Imports image files, folders, or a mixture of both into a mood's All
    /// Day pool. Folder contents are discovered recursively, non-images are
    /// ignored, and individual decode failures don't discard successful work.
    func importAllDayWallpapers(from urls: [URL], in mood: Mood) async throws -> WallpaperImportSummary {
        try ensureCatalogUnlessMigrationBlocked()
        return try await importItems(
            from: urls,
            to: allDayFolderURL(in: mood),
            in: mood,
            placement: .throughoutTheDay,
            slotName: Self.allDayFolderName
        )
    }

    /// Copy-on-import: every discovered image is decoded and rewritten as a
    /// normalized JPEG inside `destinationFolder`, so the original file can
    /// move or disappear without breaking the mood. One decision point for
    /// All Day and slot imports alike, so neither can drift from the other.
    private func importItems(
        from urls: [URL],
        to destinationFolder: URL,
        in mood: Mood,
        placement: WallpaperPlacement,
        slotName: String
    ) async throws -> WallpaperImportSummary {
        let summary: WallpaperImportSummary
        if usesCatalog {
            let collected = try await Task.detached(priority: .userInitiated) {
                try Self.discoveredImageURLs(urls)
            }.value
            var imported = 0
            var failed = collected.failedCount
            for sourceURL in collected.urls {
                do {
                    try ingestImportedFile(sourceURL, into: mood, placement: placement)
                    imported += 1
                } catch {
                    failed += 1
                    print("[MoodStore] Failed to import \(sourceURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
            summary = WallpaperImportSummary(
                discoveredCount: collected.urls.count + collected.failedCount,
                importedCount: imported,
                failedCount: failed
            )
        } else {
            summary = try await Task.detached(priority: .userInitiated) {
                try Self.importItems(urls, to: destinationFolder)
            }.value
        }

        if summary.importedCount > 0 {
            touch(mood)
            objectWillChange.send()
            AnalyticsManager.shared.log(.moodWallpaperImported, metadata: [
                "moodID": mood.id,
                "slot": slotName,
                "count": "\(summary.importedCount)"
            ])
        }
        return summary
    }

    /// Remove from this Vibe only. The canonical asset stays in Moodpaper.
    func removeWallpaper(_ url: URL, from mood: Mood) throws {
        if usesCatalog {
            try removeWallpaperMembership(url, from: mood)
            return
        }
        try fileManager.removeItem(at: url)
        touch(mood)
        objectWillChange.send()
    }

    /// Destroy the asset and every Vibe membership / assignment.
    func deleteWallpaperFromMoodpaper(_ url: URL) throws {
        try ensureCatalog()
        guard var catalog, let asset = resolveAsset(for: url) else {
            throw NSError(domain: "MoodStore", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Wallpaper is not in the catalog"
            ])
        }
        let canonical = LibraryMigration.canonicalURL(for: asset, libraryRoot: storageRootURL)
        catalog.removeAssetAndMemberships(id: asset.id)
        self.catalog = catalog
        saveCatalog()
        try? fileManager.removeItem(at: canonical)
        objectWillChange.send()
    }

    func addWallpaper(_ url: URL, to mood: Mood, placement: WallpaperPlacement = .throughoutTheDay) throws {
        try ensureCatalog()
        try ingestExistingFile(url, into: mood, placement: placement, copyIfUntracked: true)
        touch(mood)
        objectWillChange.send()
    }

    /// Every wallpaper in the Vibe, including the shared fallback pool and
    /// slot-specific files. The engine still resolves empty slots through
    /// `effectiveWallpapers`; this list is for the unified Wallpapers grid.
    func libraryItems(in mood: Mood) -> [WallpaperLibraryItem] {
        if usesCatalog {
            return catalogLibraryItems(in: mood, uniqueAssets: true)
        }
        var items: [WallpaperLibraryItem] = allDayWallpapers(in: mood).map {
            WallpaperLibraryItem(url: $0, placement: .throughoutTheDay)
        }
        for slot in TimeSlot.allCases {
            items.append(contentsOf: wallpapers(for: slot, in: mood).map {
                WallpaperLibraryItem(url: $0, placement: .during(slot))
            })
        }
        return items.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    /// Moves a wallpaper between the shared fallback pool and a time-slot
    /// folder. Slot-specific files still override the fallback internally.
    func setWallpaperPlacement(
        _ placement: WallpaperPlacement,
        for url: URL,
        in mood: Mood
    ) throws {
        if usesCatalog {
            try setCatalogPlacement(placement, for: url, in: mood)
            return
        }
        let destinationFolder: URL
        switch placement {
        case .throughoutTheDay:
            destinationFolder = allDayFolderURL(in: mood)
        case .during(let slot):
            destinationFolder = folderURL(for: slot, in: mood)
        }

        let currentFolder = url.deletingLastPathComponent().standardizedFileURL
        if currentFolder == destinationFolder.standardizedFileURL {
            return
        }

        var destination = destinationFolder.appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            destination = Self.importDestination(for: url, in: destinationFolder)
        }
        try fileManager.moveItem(at: url, to: destination)
        touch(mood)
        objectWillChange.send()
    }

    func dayPartRepresentation(for group: DayPartGroup, in mood: Mood) -> DayPartGroupRepresentation {
        if usesCatalog {
            let idSets: [Set<String>] = group.slots.map { slot in
                Set((catalog?.memberships(forMoodID: mood.id) ?? []).compactMap { membership in
                    membership.includes(slot: slot) ? membership.assetID : nil
                })
            }
            if idSets.allSatisfy(\.isEmpty) {
                return .usingVibePhotos
            }
            let first = idSets[0]
            if idSets.allSatisfy({ $0 == first }) {
                let names = first.compactMap { assetID -> String? in
                    catalog?.asset(id: assetID)?.originalFilename
                }.sorted()
                return .assigned(filenames: names)
            }
            return .mixed
        }
        let filenameSets = group.slots.map { slot in
            Set(wallpapers(for: slot, in: mood).map(\.lastPathComponent))
        }
        if filenameSets.allSatisfy(\.isEmpty) {
            return .usingVibePhotos
        }
        let first = filenameSets[0]
        if filenameSets.allSatisfy({ $0 == first }) {
            return .assigned(filenames: first.sorted())
        }
        return .mixed
    }

    /// Copies a wallpaper into every detailed period in the group. The source
    /// file stays where it is so Vibe-wide playback is preserved.
    func assignWallpaper(_ url: URL, to group: DayPartGroup, in mood: Mood) throws {
        for slot in group.slots {
            try addWallpaperAssignment(url, to: slot, in: mood)
        }
    }

    func unassignWallpaper(_ url: URL, from group: DayPartGroup, in mood: Mood) throws {
        for slot in group.slots {
            if let assigned = wallpaper(named: url.lastPathComponent, for: slot, in: mood) {
                try removeWallpaperAssignment(assigned, from: slot, in: mood)
            }
        }
    }

    func playThroughoutTheDay(_ url: URL, in mood: Mood) throws {
        if usesCatalog {
            try mutateMembership(for: url, in: mood) { membership in
                membership.throughoutTheDay = true
                membership.slotIDs = []
            }
            return
        }
        try ensureThroughoutTheDayCopy(of: url, in: mood)
        for slot in TimeSlot.allCases {
            if let assigned = wallpaper(named: url.lastPathComponent, for: slot, in: mood) {
                try removeWallpaperAssignment(assigned, from: slot, in: mood)
            }
        }
    }

    func addWallpaperAssignment(_ url: URL, to slot: TimeSlot, in mood: Mood) throws {
        if usesCatalog {
            try mutateMembership(for: url, in: mood) { membership in
                if !membership.slotIDs.contains(slot.rawValue) {
                    membership.slotIDs.append(slot.rawValue)
                    membership.slotIDs.sort()
                }
            }
            return
        }
        let destinationFolder = folderURL(for: slot, in: mood)
        let destination = destinationFolder.appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            return
        }
        try fileManager.copyItem(at: url, to: destination)
        touch(mood)
        objectWillChange.send()
    }

    func removeWallpaperAssignment(_ url: URL, from slot: TimeSlot, in mood: Mood) throws {
        if usesCatalog {
            try mutateMembership(for: url, in: mood) { membership in
                membership.slotIDs.removeAll { $0 == slot.rawValue }
                if membership.slotIDs.isEmpty && !membership.throughoutTheDay {
                    membership.throughoutTheDay = true
                }
            }
            return
        }
        let folder = folderURL(for: slot, in: mood).standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL == folder else { return }
        try ensureThroughoutTheDayCopyIfLastAssignment(url, in: mood)
        try fileManager.removeItem(at: url)
        touch(mood)
        objectWillChange.send()
    }

    func vibeSourceItems(in mood: Mood) -> [WallpaperLibraryItem] {
        if usesCatalog {
            return catalogLibraryItems(in: mood, uniqueAssets: true)
        }
        var seen = Set<String>()
        var items: [WallpaperLibraryItem] = []
        for url in allDayWallpapers(in: mood) {
            seen.insert(url.lastPathComponent)
            items.append(WallpaperLibraryItem(url: url, placement: .throughoutTheDay))
        }
        for slot in TimeSlot.allCases {
            for url in wallpapers(for: slot, in: mood) where seen.insert(url.lastPathComponent).inserted {
                items.append(WallpaperLibraryItem(url: url, placement: .during(slot)))
            }
        }
        return items.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    private func wallpaper(named filename: String, for slot: TimeSlot, in mood: Mood) -> URL? {
        wallpapers(for: slot, in: mood).first { $0.lastPathComponent == filename }
    }

    private func ensureThroughoutTheDayCopy(of url: URL, in mood: Mood) throws {
        let destination = allDayFolderURL(in: mood).appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            return
        }
        try fileManager.copyItem(at: url, to: destination)
        touch(mood)
        objectWillChange.send()
    }

    private func ensureThroughoutTheDayCopyIfLastAssignment(_ url: URL, in mood: Mood) throws {
        let name = url.lastPathComponent
        let remainsElsewhere = TimeSlot.allCases.contains { slot in
            wallpapers(for: slot, in: mood).contains {
                $0.lastPathComponent == name && $0.standardizedFileURL != url.standardizedFileURL
            }
        }
        let inVibePool = allDayWallpapers(in: mood).contains { $0.lastPathComponent == name }
        if remainsElsewhere || inVibePool {
            return
        }
        try ensureThroughoutTheDayCopy(of: url, in: mood)
    }

    /// Sanitized, collision-free destination filename. Same rule as
    /// UserWallpaperManager.normalizedImportDestination.
    nonisolated static func importDestination(for sourceURL: URL, in directory: URL) -> URL {
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

    private nonisolated static func importItems(
        _ sourceURLs: [URL],
        to destinationFolder: URL
    ) throws -> WallpaperImportSummary {
        var securityScopedRoots: [URL] = []
        for url in sourceURLs where url.startAccessingSecurityScopedResource() {
            securityScopedRoots.append(url)
        }
        defer {
            for url in securityScopedRoots {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        var discovered = Set<URL>()
        var discoveryFailureCount = 0

        for sourceURL in sourceURLs {
            guard let values = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                if supportedImageExtensions.contains(sourceURL.pathExtension.lowercased()) {
                    discoveryFailureCount += 1
                }
                continue
            }
            if values.isDirectory == true {
                let enumerator = fileManager.enumerator(
                    at: sourceURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in
                        discoveryFailureCount += 1
                        return true
                    }
                )
                while let candidate = enumerator?.nextObject() as? URL {
                    guard supportedImageExtensions.contains(candidate.pathExtension.lowercased()) else { continue }
                    let candidateValues = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
                    if candidateValues?.isRegularFile == true {
                        discovered.insert(candidate)
                    }
                }
            } else if values.isRegularFile == true,
                      supportedImageExtensions.contains(sourceURL.pathExtension.lowercased()) {
                discovered.insert(sourceURL)
            }
        }

        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        var importedCount = 0
        var failedCount = discoveryFailureCount

        for sourceURL in discovered.sorted(by: { $0.path < $1.path }) {
            let destination = importDestination(for: sourceURL, in: destinationFolder)
            do {
                try writeNormalizedImage(from: sourceURL, to: destination)
                importedCount += 1
            } catch {
                failedCount += 1
                try? fileManager.removeItem(at: destination)
                print("[MoodStore] Failed to import \(sourceURL.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return WallpaperImportSummary(
            discoveredCount: discovered.count + discoveryFailureCount,
            importedCount: importedCount,
            failedCount: failedCount
        )
    }

    // MARK: - Persistence

    private var metadataURL: URL {
        moodsRootURL.appendingPathComponent("moods.json")
    }

    private func load() {
        if LibraryMigration.testHostMustNotLoadLibrary(at: storageRootURL) {
            return
        }
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

    /// Preserve existing catalogs while repairing a missing or stale active
    /// selection. A fresh catalog intentionally stays empty until the user
    /// creates their first Vibe.
    private func restoreActiveMoodIfNeeded() {
        if activeMood == nil, !moods.isEmpty {
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

    // MARK: - Catalog v2

    func resolveCanonicalURL(forPlaybackIdentifier identifier: String) -> URL? {
        guard usesCatalog, identifier.hasPrefix("/") else { return nil }
        if let asset = catalog?.assets.first(where: {
            $0.legacySourcePaths.contains(identifier)
                || LibraryMigration.canonicalURL(for: $0, libraryRoot: storageRootURL).path == identifier
        }) {
            let url = LibraryMigration.canonicalURL(for: asset, libraryRoot: storageRootURL)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        return nil
    }

    /// Adopts an existing catalog or migrates the legacy folders into one.
    /// On a protected root without explicit authorization neither happens:
    /// a stale catalog.json is ignored and the store stays on the legacy
    /// Moods model.
    private func adoptCatalogIfNeeded() {
        if LibraryMigration.isMigrationBlocked(for: storageRootURL) {
            catalog = nil
            print("[MoodStore] \(LibraryMigration.blockedDiagnostic)")
            return
        }
        if let loaded = try? LibraryMigration.loadCatalog(from: storageRootURL), loaded.isReady {
            catalog = loaded
            return
        }
        guard LibraryMigration.needsMigration(libraryRoot: storageRootURL) else { return }
        do {
            _ = try LibraryMigration.migrateIfNeeded(libraryRoot: storageRootURL)
            catalog = try LibraryMigration.loadCatalog(from: storageRootURL)
        } catch {
            print("[MoodStore] Catalog migration deferred: \(error.localizedDescription)")
            catalog = nil
        }
    }

    /// Imports keep working on the legacy folder model when migration is
    /// blocked; catalog-only operations go through `ensureCatalog` and fail
    /// closed instead.
    private func ensureCatalogUnlessMigrationBlocked() throws {
        if LibraryMigration.isMigrationBlocked(for: storageRootURL) { return }
        try ensureCatalog()
    }

    func ensureCatalog() throws {
        if usesCatalog { return }
        if LibraryMigration.isMigrationBlocked(for: storageRootURL) {
            throw LibraryMigration.MigrationBlockedError()
        }
        if LibraryMigration.needsMigration(libraryRoot: storageRootURL) {
            _ = try LibraryMigration.migrateIfNeeded(libraryRoot: storageRootURL)
        }
        if let loaded = try? LibraryMigration.loadCatalog(from: storageRootURL), loaded.isReady {
            catalog = loaded
            return
        }
        catalog = WallpaperCatalog.readyEmpty()
        try persistCatalog()
    }

    private func saveCatalog() {
        try? persistCatalog()
    }

    private func persistCatalog() throws {
        guard let catalog else { return }
        if LibraryMigration.isMigrationBlocked(for: storageRootURL) {
            throw LibraryMigration.MigrationBlockedError()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(catalog).write(
            to: WallpaperCatalogFile.catalogURL(in: storageRootURL),
            options: .atomic
        )
    }

    private func catalogURLs(in mood: Mood, where predicate: (WallpaperMembership) -> Bool) -> [URL] {
        guard let catalog else { return [] }
        let urls = catalog.memberships(forMoodID: mood.id).filter(predicate).compactMap { membership -> URL? in
            guard let asset = catalog.asset(id: membership.assetID) else { return nil }
            return LibraryMigration.canonicalURL(for: asset, libraryRoot: storageRootURL)
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func catalogLibraryItems(in mood: Mood, uniqueAssets: Bool) -> [WallpaperLibraryItem] {
        guard let catalog else { return [] }
        var items: [WallpaperLibraryItem] = []
        var seen = Set<String>()
        for membership in catalog.memberships(forMoodID: mood.id) {
            guard let asset = catalog.asset(id: membership.assetID) else { continue }
            if uniqueAssets, !seen.insert(asset.id).inserted { continue }
            let url = LibraryMigration.canonicalURL(for: asset, libraryRoot: storageRootURL)
            let placement: WallpaperPlacement
            if membership.throughoutTheDay {
                placement = .throughoutTheDay
            } else if let raw = membership.slotIDs.first, let slot = TimeSlot(rawValue: raw) {
                placement = .during(slot)
            } else {
                placement = .throughoutTheDay
            }
            items.append(
                WallpaperLibraryItem(
                    url: url,
                    placement: placement,
                    assetID: asset.id,
                    vibeIDs: catalog.moodIDs(forAssetID: asset.id)
                )
            )
        }
        return items.sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    private func resolveAsset(for url: URL) -> WallpaperAsset? {
        guard let catalog else { return nil }
        let path = url.standardizedFileURL.path
        if let match = catalog.assets.first(where: {
            LibraryMigration.canonicalURL(for: $0, libraryRoot: storageRootURL).path == path
                || $0.legacySourcePaths.contains(path)
                || $0.legacySourcePaths.contains(url.path)
        }) {
            return match
        }
        return catalog.asset(matchingURL: url)
    }

    private func removeWallpaperMembership(_ url: URL, from mood: Mood) throws {
        guard var catalog, let asset = resolveAsset(for: url) else {
            throw NSError(domain: "MoodStore", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Wallpaper is not in this Vibe"
            ])
        }
        catalog.removeMembership(assetID: asset.id, moodID: mood.id)
        self.catalog = catalog
        saveCatalog()
        touch(mood)
        objectWillChange.send()
    }

    private func setCatalogPlacement(
        _ placement: WallpaperPlacement,
        for url: URL,
        in mood: Mood
    ) throws {
        try mutateMembership(for: url, in: mood) { membership in
            switch placement {
            case .throughoutTheDay:
                membership.throughoutTheDay = true
                membership.slotIDs = []
            case .during(let slot):
                membership.throughoutTheDay = false
                membership.slotIDs = [slot.rawValue]
            }
        }
    }

    private func mutateMembership(
        for url: URL,
        in mood: Mood,
        _ body: (inout WallpaperMembership) -> Void
    ) throws {
        guard var catalog, let asset = resolveAsset(for: url) else {
            throw NSError(domain: "MoodStore", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Wallpaper is not in this Vibe"
            ])
        }
        var membership = catalog.memberships.first {
            $0.assetID == asset.id && $0.moodID == mood.id
        } ?? WallpaperMembership(
            assetID: asset.id,
            moodID: mood.id,
            throughoutTheDay: false,
            slotIDs: []
        )
        body(&membership)
        catalog.replaceMembership(membership)
        self.catalog = catalog
        saveCatalog()
        touch(mood)
        objectWillChange.send()
    }

    private func duplicateCatalogMemberships(from source: Mood, to copy: Mood) throws {
        guard var catalog else { return }
        for membership in catalog.memberships(forMoodID: source.id) {
            var duplicated = membership
            duplicated.moodID = copy.id
            catalog.replaceMembership(duplicated)
        }
        self.catalog = catalog
        saveCatalog()
    }

    private func ingestImportedFile(
        _ sourceURL: URL,
        into mood: Mood,
        placement: WallpaperPlacement
    ) throws {
        try fileManager.createDirectory(
            at: WallpaperCatalogFile.assetsRoot(in: storageRootURL),
            withIntermediateDirectories: true
        )
        let temp = WallpaperCatalogFile.assetsRoot(in: storageRootURL)
            .appendingPathComponent("import-\(UUID().uuidString.lowercased()).jpg")
        do {
            try writeNormalizedImage(from: sourceURL, to: temp)
            try ingestExistingFile(
                temp,
                into: mood,
                placement: placement,
                copyIfUntracked: false,
                originalFilename: sourceURL.lastPathComponent
            )
            if fileManager.fileExists(atPath: temp.path), resolveAsset(for: temp) == nil {
                try? fileManager.removeItem(at: temp)
            }
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
    }

    private func ingestExistingFile(
        _ fileURL: URL,
        into mood: Mood,
        placement: WallpaperPlacement,
        copyIfUntracked: Bool,
        originalFilename: String? = nil
    ) throws {
        try ensureCatalog()
        guard var catalog else { return }
        if let existing = resolveAsset(for: fileURL) {
            var membership = catalog.memberships.first {
                $0.assetID == existing.id && $0.moodID == mood.id
            } ?? WallpaperMembership(
                assetID: existing.id,
                moodID: mood.id,
                throughoutTheDay: false,
                slotIDs: []
            )
            apply(placement, to: &membership)
            catalog.replaceMembership(membership)
            self.catalog = catalog
            saveCatalog()
            return
        }

        let hash = try WallpaperIdentity.sha256Hex(of: fileURL)
        let byteCount = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let metadata = WallpaperIdentity.imageMetadata(at: fileURL)
        if let metadata {
            let identity = WallpaperAssetIdentity(
                contentHash: hash,
                byteCount: byteCount,
                pixelWidth: metadata.width,
                pixelHeight: metadata.height
            )
            if let match = catalog.assets.first(where: { $0.identityKey == identity }) {
                var membership = catalog.memberships.first {
                    $0.assetID == match.id && $0.moodID == mood.id
                } ?? WallpaperMembership(
                    assetID: match.id,
                    moodID: mood.id,
                    throughoutTheDay: false,
                    slotIDs: []
                )
                apply(placement, to: &membership)
                catalog.replaceMembership(membership)
                if fileURL.deletingLastPathComponent().standardizedFileURL
                    == WallpaperCatalogFile.assetsRoot(in: storageRootURL).standardizedFileURL {
                    try? fileManager.removeItem(at: fileURL)
                }
                self.catalog = catalog
                saveCatalog()
                return
            }
        }

        let assetID = UUID().uuidString.lowercased()
        let ext = fileURL.pathExtension.isEmpty ? "jpg" : fileURL.pathExtension.lowercased()
        let relative = "\(WallpaperCatalogFile.assetsFolderName)/\(WallpaperCatalogFile.assetsDirectoryName)/\(assetID).\(ext)"
        let destination = WallpaperCatalogFile.assetsRoot(in: storageRootURL)
            .appendingPathComponent("\(assetID).\(ext)")
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if copyIfUntracked {
            if fileManager.fileExists(atPath: destination.path) == false {
                try fileManager.copyItem(at: fileURL, to: destination)
            }
        } else {
            if fileURL != destination {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: fileURL, to: destination)
            }
        }
        let asset = WallpaperAsset(
            id: assetID,
            originalFilename: originalFilename ?? fileURL.lastPathComponent,
            relativePath: relative,
            contentHash: try WallpaperIdentity.sha256Hex(of: destination),
            byteCount: try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? byteCount,
            pixelWidth: metadata?.width,
            pixelHeight: metadata?.height,
            uti: metadata?.uti,
            createdAt: Date(),
            legacySourcePaths: [fileURL.standardizedFileURL.path]
        )
        catalog.upsert(asset)
        var membership = WallpaperMembership(
            assetID: assetID,
            moodID: mood.id,
            throughoutTheDay: false,
            slotIDs: []
        )
        apply(placement, to: &membership)
        catalog.replaceMembership(membership)
        self.catalog = catalog
        saveCatalog()
    }

    private func apply(_ placement: WallpaperPlacement, to membership: inout WallpaperMembership) {
        switch placement {
        case .throughoutTheDay:
            membership.throughoutTheDay = true
        case .during(let slot):
            if !membership.slotIDs.contains(slot.rawValue) {
                membership.slotIDs.append(slot.rawValue)
                membership.slotIDs.sort()
            }
        }
    }

    private struct DiscoveredImages: Sendable {
        let urls: [URL]
        let failedCount: Int
    }

    private nonisolated static func discoveredImageURLs(_ sourceURLs: [URL]) throws -> DiscoveredImages {
        var securityScopedRoots: [URL] = []
        for url in sourceURLs where url.startAccessingSecurityScopedResource() {
            securityScopedRoots.append(url)
        }
        defer {
            for url in securityScopedRoots {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        var discovered = Set<URL>()
        var discoveryFailureCount = 0

        for sourceURL in sourceURLs {
            guard let values = try? sourceURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else {
                if supportedImageExtensions.contains(sourceURL.pathExtension.lowercased()) {
                    discoveryFailureCount += 1
                }
                continue
            }
            if values.isDirectory == true {
                let enumerator = fileManager.enumerator(
                    at: sourceURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in
                        discoveryFailureCount += 1
                        return true
                    }
                )
                while let candidate = enumerator?.nextObject() as? URL {
                    guard supportedImageExtensions.contains(candidate.pathExtension.lowercased()) else { continue }
                    let candidateValues = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
                    if candidateValues?.isRegularFile == true {
                        discovered.insert(candidate)
                    }
                }
            } else if values.isRegularFile == true,
                      supportedImageExtensions.contains(sourceURL.pathExtension.lowercased()) {
                discovered.insert(sourceURL)
            }
        }

        return DiscoveredImages(
            urls: discovered.sorted(by: { $0.path < $1.path }),
            failedCount: discoveryFailureCount
        )
    }
}
