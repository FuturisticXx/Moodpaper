import Foundation

/// Leftover files from the retired global `UserWallpapers/` tree.
///
/// This folder is never a source of truth and must never be created
/// automatically. Existing files are detected, left in place, and imported
/// only through `MoodStore` APIs so Catalog identity stays content-based.
enum LegacyUserWallpapers {
    static let directoryName = "UserWallpapers"
    static let globalFolderName = "Global"

    struct File: Equatable {
        let url: URL
        let placement: WallpaperPlacement
    }

    static func directoryURL(in libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func inventory(in libraryRoot: URL) -> [File] {
        let root = directoryURL(in: libraryRoot)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        var files: [File] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let url = enumerator?.nextObject() as? URL {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            guard isFile else { continue }
            let ext = url.pathExtension.lowercased()
            guard ["jpg", "jpeg", "png", "heic", "heif", "tiff", "bmp"].contains(ext) else { continue }
            files.append(File(url: url, placement: placement(for: url, root: root)))
        }
        return files.sorted { $0.url.path < $1.url.path }
    }

    private static func placement(for url: URL, root: URL) -> WallpaperPlacement {
        let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
        let folder = relative.split(separator: "/").first.map(String.init) ?? ""
        if folder == globalFolderName {
            return .throughoutTheDay
        }
        if let slot = TimeSlot(rawValue: folder) {
            return .during(slot)
        }
        return .throughoutTheDay
    }
}
