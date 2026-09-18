import AppKit
import Foundation

// MARK: - Legacy library migration

// Sandboxed builds get a redirected Application Support directory, so a
// library that a non-sandboxed build wrote to
// ~/Library/Application Support/Moodpaper is somewhere the shipping app can
// no longer reach on its own. Rather than silently starting empty, the app
// offers a one-time import: an open panel hands the app access to the old
// folder, and every file is *copied* so the original install stays intact.
//
// Merging, never replacing: a legacy mood whose id already exists in the
// destination is skipped, so running the import twice can never overwrite
// newer work.
enum LegacyLibraryMigration {
    static let didImportKey = "legacyLibrary.didImport"

    struct Summary: Equatable {
        let moodCount: Int
        let imageCount: Int
        let preservedUserWallpaperCount: Int

        init(moodCount: Int, imageCount: Int, preservedUserWallpaperCount: Int = 0) {
            self.moodCount = moodCount
            self.imageCount = imageCount
            self.preservedUserWallpaperCount = preservedUserWallpaperCount
        }

        static let empty = Summary(moodCount: 0, imageCount: 0)

        func adding(images: Int) -> Summary {
            Summary(
                moodCount: moodCount,
                imageCount: imageCount + images,
                preservedUserWallpaperCount: preservedUserWallpaperCount
            )
        }
    }

    /// Destination already uses Catalog as source of truth, so a raw
    /// `Moods/` copy would be ignored. Route through `MoodStore` instead.
    struct CatalogBackedDestinationError: LocalizedError {
        var errorDescription: String? {
            "This library already uses the wallpaper catalog. Import through Moodpaper so the photos stay visible in your Vibes."
        }
    }

    private static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "bmp"
    ]

    // MARK: Locating the legacy folder

    /// The user's real home directory. `NSHomeDirectory()` returns the
    /// container path under sandboxing, which is the folder we are importing
    /// *into*, not the one we are looking for.
    static var realHomeDirectoryURL: URL {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else {
            return URL(fileURLWithPath: NSHomeDirectory())
        }
        return URL(fileURLWithPath: String(cString: dir))
    }

    /// Where a non-sandboxed build would have written its library. Used only
    /// to point the open panel at the right place; the app still needs the
    /// user's selection to gain read access.
    static var suggestedLegacyRootURL: URL {
        realHomeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Moodpaper", isDirectory: true)
    }

    /// Distinguishes a real library from an arbitrary folder the user picked.
    static func looksLikeLibrary(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: metadataURL(in: root).path)
    }

    // MARK: Import

    /// Copy the mood catalog and its images from `legacyRoot` into
    /// `destinationRoot`. Both roots are library roots (the folder containing
    /// `Moods/`), not the `Moods/` folder itself.
    @discardableResult
    static func importLibrary(from legacyRoot: URL, into destinationRoot: URL) throws -> Summary {
        if (try? LibraryMigration.loadCatalog(from: destinationRoot))?.isReady == true {
            throw CatalogBackedDestinationError()
        }

        let scoped = legacyRoot.startAccessingSecurityScopedResource()
        defer { if scoped { legacyRoot.stopAccessingSecurityScopedResource() } }

        let fileManager = FileManager.default
        let leftoverCount = LegacyUserWallpapers.inventory(in: legacyRoot).count
        let legacyMoods = try decodeMoods(at: metadataURL(in: legacyRoot))
        guard !legacyMoods.isEmpty else {
            return leftoverCount == 0
                ? .empty
                : Summary(moodCount: 0, imageCount: 0, preservedUserWallpaperCount: leftoverCount)
        }

        let destinationMoodsRoot = destinationRoot.appendingPathComponent("Moods", isDirectory: true)
        try fileManager.createDirectory(at: destinationMoodsRoot, withIntermediateDirectories: true)

        var merged = (try? decodeMoods(at: metadataURL(in: destinationRoot))) ?? []
        let existingIDs = Set(merged.map(\.id))

        var importedMoods = 0
        var importedImages = 0

        for mood in legacyMoods where !existingIDs.contains(mood.id) {
            let source = legacyRoot
                .appendingPathComponent("Moods", isDirectory: true)
                .appendingPathComponent(mood.id, isDirectory: true)
            guard fileManager.fileExists(atPath: source.path) else { continue }

            let destination = destinationMoodsRoot.appendingPathComponent(mood.id, isDirectory: true)
            importedImages += try copyImageTree(from: source, to: destination)
            merged.append(mood)
            importedMoods += 1
        }

        if importedMoods > 0 {
            let data = try JSONEncoder().encode(merged)
            try data.write(to: metadataURL(in: destinationRoot))
        }

        return Summary(
            moodCount: importedMoods,
            imageCount: importedImages,
            preservedUserWallpaperCount: leftoverCount
        )
    }

    // MARK: Helpers

    private static func metadataURL(in root: URL) -> URL {
        root
            .appendingPathComponent("Moods", isDirectory: true)
            .appendingPathComponent("moods.json")
    }

    private static func decodeMoods(at url: URL) throws -> [Mood] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Mood].self, from: data)
    }

    static func moods(in libraryRoot: URL) throws -> [Mood] {
        try decodeMoods(at: metadataURL(in: libraryRoot))
    }

    /// Image files under one legacy Vibe, mapped to placements. Folder paths
    /// are a layout hint only, never identity.
    static func wallpaperFiles(forMoodID moodID: String, in libraryRoot: URL) -> [(url: URL, placement: WallpaperPlacement)] {
        let moodRoot = libraryRoot
            .appendingPathComponent("Moods", isDirectory: true)
            .appendingPathComponent(moodID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: moodRoot.path) else { return [] }

        var files: [(url: URL, placement: WallpaperPlacement)] = []
        let enumerator = FileManager.default.enumerator(
            at: moodRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            guard isFile, supportedImageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            files.append((url, placement(forLegacyMoodFile: url, moodRoot: moodRoot)))
        }
        return files
    }

    private static func placement(forLegacyMoodFile url: URL, moodRoot: URL) -> WallpaperPlacement {
        let relative = url.deletingLastPathComponent().path
            .replacingOccurrences(of: moodRoot.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let folder = relative.split(separator: "/").first.map(String.init) ?? ""
        if folder == MoodStore.allDayFolderName || folder.isEmpty {
            return .throughoutTheDay
        }
        if let slot = TimeSlot(rawValue: folder) {
            return .during(slot)
        }
        return .throughoutTheDay
    }

    /// Recursively copy every supported image, preserving the slot-folder
    /// layout. Individual failures are skipped rather than aborting the whole
    /// import, so one unreadable file cannot cost the user their library.
    private static func copyImageTree(from source: URL, to destination: URL) throws -> Int {
        let fileManager = FileManager.default
        var copied = 0

        let entries = (try? fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for entry in entries {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isDirectory {
                copied += try copyImageTree(
                    from: entry,
                    to: destination.appendingPathComponent(entry.lastPathComponent, isDirectory: true)
                )
                continue
            }

            guard supportedImageExtensions.contains(entry.pathExtension.lowercased()) else { continue }
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            do {
                try fileManager.copyItem(at: entry, to: target)
                copied += 1
            } catch {
                print("[LegacyLibraryMigration] Skipped \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return copied
    }
}

// MARK: - Open panel

extension LegacyLibraryMigration {
    /// Picking one of the folders *inside* the library is the easy mistake,
    /// so a wrong choice is reported back rather than silently doing nothing.
    enum Selection {
        case cancelled
        case notALibrary(URL)
        case selected(URL)
    }

    /// Ask the user to point at their previous library.
    @MainActor
    static func promptForLegacyRoot() -> Selection {
        let panel = NSOpenPanel()
        panel.title = "Import Previous Library"
        panel.message = "Choose your previous Moodpaper folder to bring its Vibes and wallpapers into this version."
        panel.prompt = "Import"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = suggestedLegacyRootURL

        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        return looksLikeLibrary(at: url) ? .selected(url) : .notALibrary(url)
    }
}
