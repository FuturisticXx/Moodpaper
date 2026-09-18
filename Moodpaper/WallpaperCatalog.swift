import Foundation
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

/// Catalog v2: wallpapers are first-class assets with stable identity and one
/// canonical stored file. Vibes hold memberships (including per-period
/// assignments), not copies of the file.
struct WallpaperCatalog: Codable, Equatable {
    static let schemaVersion = 2
    /// Phase 6A catalog migration. Bump only when the migrator itself changes.
    static let migrationVersion = 1
    static let sourceOfTruthCatalog = "catalog"

    var schemaVersion: Int
    var migrationVersion: Int
    var sourceOfTruth: String
    var legacyFoldersPreserved: Bool
    var assets: [WallpaperAsset]
    var memberships: [WallpaperMembership]

    var isReady: Bool {
        schemaVersion == Self.schemaVersion
            && migrationVersion == Self.migrationVersion
            && sourceOfTruth == Self.sourceOfTruthCatalog
    }

    static func readyEmpty() -> WallpaperCatalog {
        WallpaperCatalog(
            schemaVersion: schemaVersion,
            migrationVersion: migrationVersion,
            sourceOfTruth: sourceOfTruthCatalog,
            legacyFoldersPreserved: true,
            assets: [],
            memberships: []
        )
    }

    func asset(id: String) -> WallpaperAsset? {
        assets.first { $0.id == id }
    }

    func asset(matchingURL url: URL) -> WallpaperAsset? {
        let standardized = url.standardizedFileURL.path
        return assets.first { asset in
            asset.relativePath == relativePath(matching: url)
                || asset.legacySourcePaths.contains(standardized)
                || asset.legacySourcePaths.contains(url.path)
        }
    }

    private func relativePath(matching url: URL) -> String? {
        assets.first { url.path.hasSuffix($0.relativePath) }?.relativePath
    }

    func memberships(forMoodID moodID: String) -> [WallpaperMembership] {
        memberships.filter { $0.moodID == moodID }
    }

    func moodIDs(forAssetID assetID: String) -> [String] {
        Array(Set(memberships.filter { $0.assetID == assetID }.map(\.moodID))).sorted()
    }

    mutating func upsert(_ asset: WallpaperAsset) {
        if let index = assets.firstIndex(where: { $0.id == asset.id }) {
            assets[index] = asset
        } else {
            assets.append(asset)
        }
    }

    mutating func replaceMembership(_ membership: WallpaperMembership) {
        memberships.removeAll {
            $0.assetID == membership.assetID && $0.moodID == membership.moodID
        }
        if membership.isEmpty {
            return
        }
        memberships.append(membership)
    }

    mutating func removeMembership(assetID: String, moodID: String) {
        memberships.removeAll { $0.assetID == assetID && $0.moodID == moodID }
    }

    mutating func removeAssetAndMemberships(id: String) {
        assets.removeAll { $0.id == id }
        memberships.removeAll { $0.assetID == id }
    }
}

struct WallpaperAsset: Codable, Equatable, Identifiable {
    let id: String
    var originalFilename: String
    var relativePath: String
    var contentHash: String
    var byteCount: Int
    var pixelWidth: Int?
    var pixelHeight: Int?
    var uti: String?
    var createdAt: Date
    var legacySourcePaths: [String]

    var hasValidatedIdentity: Bool {
        pixelWidth != nil && pixelHeight != nil && pixelWidth! > 0 && pixelHeight! > 0
    }

    var identityKey: WallpaperAssetIdentity? {
        guard hasValidatedIdentity, let width = pixelWidth, let height = pixelHeight else {
            return nil
        }
        return WallpaperAssetIdentity(
            contentHash: contentHash,
            byteCount: byteCount,
            pixelWidth: width,
            pixelHeight: height
        )
    }
}

/// Duplicate merging is allowed only when content hash and validated pixel
/// metadata agree. Filename is never an identity key.
struct WallpaperAssetIdentity: Hashable {
    let contentHash: String
    let byteCount: Int
    let pixelWidth: Int
    let pixelHeight: Int
}

struct WallpaperMembership: Codable, Equatable {
    var assetID: String
    var moodID: String
    var throughoutTheDay: Bool
    var slotIDs: [String]

    var isEmpty: Bool { !throughoutTheDay && slotIDs.isEmpty }

    func includes(slot: TimeSlot) -> Bool {
        slotIDs.contains(slot.rawValue)
    }
}

enum WallpaperCatalogFile {
    static let catalogFileName = "catalog.json"
    static let assetsFolderName = "Catalog"
    static let assetsDirectoryName = "Assets"
    static let migrationFolderName = "Migration"
    static let journalFileName = "journal.json"
    static let backupsFolderName = "Backups"
    static let stagingFolderName = "Staging"

    static func catalogURL(in libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent(catalogFileName)
    }

    static func assetsRoot(in libraryRoot: URL) -> URL {
        libraryRoot
            .appendingPathComponent(assetsFolderName, isDirectory: true)
            .appendingPathComponent(assetsDirectoryName, isDirectory: true)
    }

    static func migrationRoot(in libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent(migrationFolderName, isDirectory: true)
    }

    static func journalURL(in libraryRoot: URL) -> URL {
        migrationRoot(in: libraryRoot).appendingPathComponent(journalFileName)
    }

    static func backupsRoot(in libraryRoot: URL) -> URL {
        migrationRoot(in: libraryRoot).appendingPathComponent(backupsFolderName, isDirectory: true)
    }

    static func stagingRoot(in libraryRoot: URL) -> URL {
        migrationRoot(in: libraryRoot).appendingPathComponent(stagingFolderName, isDirectory: true)
    }
}

enum WallpaperIdentity {
    static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func imageMetadata(at url: URL) -> (width: Int, height: Int, uti: String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let uti = CGImageSourceGetType(source).map { $0 as String }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = intValue(properties[kCGImagePropertyPixelWidth])
        let height = intValue(properties[kCGImagePropertyPixelHeight])
        guard let width, let height, width > 0, height > 0 else { return nil }
        return (width, height, uti ?? UTType.jpeg.identifier)
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }
}
