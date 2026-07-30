import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
internal import Combine

// MARK: - Wallpaper Source

enum WallpaperSource: String, Codable, CaseIterable {
    case stock = "Stock"
    case user = "User"
    case mixed = "Mixed"

    var displayName: String {
        return rawValue
    }
}

// MARK: - Time Slot

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

// MARK: - Time Slot Configuration

struct TimeSlotConfig: Codable {
    let slot: TimeSlot
    var source: WallpaperSource?  // nil means use global setting

    func effectiveSource(global: WallpaperSource) -> WallpaperSource {
        return source ?? global
    }
}

// MARK: - User Wallpaper Manager

@MainActor
class UserWallpaperManager: ObservableObject {
    static let shared = UserWallpaperManager()

    @Published var globalSource: WallpaperSource {
        didSet {
            UserDefaults.standard.set(globalSource.rawValue, forKey: "globalWallpaperSource")
        }
    }

    @Published var slotConfigs: [TimeSlot: TimeSlotConfig] = [:]

    private let fileManager = FileManager.default
    private var baseURL: URL

    // 2-second TTL cache for directory enumeration so wallpaperCount(...) and
    // randomWallpaper(...) don't hit the filesystem on every settings re-render.
    // Invalidated explicitly after import/delete so user actions still see
    // fresh state immediately.
    private struct WallpaperListCacheEntry {
        let urls: [URL]
        let expiresAt: Date
    }
    private var wallpaperListCache: [URL: WallpaperListCacheEntry] = [:]
    private static let wallpaperListCacheTTL: TimeInterval = 2

    private init() {
        // Initialize with iCloud if available, otherwise local
        if let iCloudURL = fileManager.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents")
            .appendingPathComponent("Moodpaper") {
            baseURL = iCloudURL
        } else {
            baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Moodpaper")
        }

        // Load global source from UserDefaults
        if let savedSource = UserDefaults.standard.string(forKey: "globalWallpaperSource"),
           let source = WallpaperSource(rawValue: savedSource) {
            globalSource = source
        } else {
            globalSource = .stock
        }

        // Load "Use My Wallpapers" toggle

        // Initialize folder structure
        createFolderStructure()

        // Load slot configurations
        loadSlotConfigs()
    }

    // MARK: - Folder Management

    private func createFolderStructure() {
        let userWallpapersURL = baseURL.appendingPathComponent("UserWallpapers")

        for slot in TimeSlot.allCases {
            let slotURL = userWallpapersURL.appendingPathComponent(slot.rawValue)
            do {
                try fileManager.createDirectory(at: slotURL, withIntermediateDirectories: true)
            } catch {
                print("[UserWallpaperManager] Failed to create slot folder for \(slot.rawValue): \(error)")
            }
        }

        // Global pool folder for free-tier imports (not tied to any time slot)
        let globalURL = userWallpapersURL.appendingPathComponent("Global")
        do {
            try fileManager.createDirectory(at: globalURL, withIntermediateDirectories: true)
        } catch {
            print("[UserWallpaperManager] Failed to create global folder: \(error)")
        }
    }

    var globalFolderURL: URL {
        return baseURL
            .appendingPathComponent("UserWallpapers")
            .appendingPathComponent("Global")
    }

    func folderURL(for slot: TimeSlot) -> URL {
        return baseURL
            .appendingPathComponent("UserWallpapers")
            .appendingPathComponent(slot.rawValue)
    }

    // MARK: - Wallpaper Management

    func wallpapers(for slot: TimeSlot) -> [URL] {
        cachedWallpaperList(in: folderURL(for: slot), tag: slot.rawValue)
    }

    func wallpaperCount(for slot: TimeSlot) -> Int {
        return wallpapers(for: slot).count
    }

    /// All user wallpapers in the global pool (free-tier).
    func globalWallpapers() -> [URL] {
        cachedWallpaperList(in: globalFolderURL, tag: "Global")
    }

    private func cachedWallpaperList(in folderURL: URL, tag: String) -> [URL] {
        if let entry = wallpaperListCache[folderURL], entry.expiresAt > Date() {
            return entry.urls
        }
        let urls: [URL]
        do {
            let contents = try fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            urls = contents.filter { url in
                let ext = url.pathExtension.lowercased()
                return ["jpg", "jpeg", "png", "heic", "heif", "tiff", "bmp"].contains(ext)
            }
        } catch {
            print("[UserWallpaperManager] Failed to enumerate wallpapers for \(tag): \(error)")
            return []
        }
        wallpaperListCache[folderURL] = WallpaperListCacheEntry(
            urls: urls,
            expiresAt: Date().addingTimeInterval(Self.wallpaperListCacheTTL)
        )
        return urls
    }

    private func invalidateWallpaperListCache() {
        wallpaperListCache.removeAll()
    }

    /// Total count of wallpapers in the global pool.
    var globalWallpaperCount: Int {
        globalWallpapers().count
    }

    /// Import wallpapers to the global pool (free-tier, not tied to any time slot).
    func importToGlobalPool(_ urls: [URL]) throws {
        let destination = globalFolderURL
        for url in urls {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

            do {
                let finalDestination = try normalizedImportDestination(for: url, in: destination)
                try writeNormalizedImage(from: url, to: finalDestination)
                print("Horizon: Imported wallpaper \(finalDestination.lastPathComponent) to Global pool")
            } catch {
                print("Horizon: Failed to import \(url.lastPathComponent) to Global pool — \(error.localizedDescription)")
                throw error
            }
        }
        invalidateWallpaperListCache()
        objectWillChange.send()
    }

    // MARK: - Import Wallpapers

    func importWallpapers(_ urls: [URL], to slot: TimeSlot) throws {
        let destinationFolder = folderURL(for: slot)

        for url in urls {
            // Security-scoped access required for files from fileImporter
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

            do {
                let finalDestination = try normalizedImportDestination(for: url, in: destinationFolder)
                try writeNormalizedImage(from: url, to: finalDestination)
                print("Horizon: Imported wallpaper \(finalDestination.lastPathComponent) to \(slot.displayName)")
            } catch {
                print("Horizon: Failed to import \(url.lastPathComponent) — \(error.localizedDescription)")
                throw error
            }
        }

        invalidateWallpaperListCache()
        objectWillChange.send()
    }

    func deleteWallpaper(_ url: URL) throws {
        try fileManager.removeItem(at: url)
        invalidateWallpaperListCache()
        objectWillChange.send()
    }

    // MARK: - Slot Configuration

    func setSource(_ source: WallpaperSource?, for slot: TimeSlot) {
        var config = slotConfigs[slot] ?? TimeSlotConfig(slot: slot, source: nil)
        config.source = source
        slotConfigs[slot] = config
        saveSlotConfigs()
    }

    func effectiveSource(for slot: TimeSlot) -> WallpaperSource {
        slotConfigs[slot]?.effectiveSource(global: globalSource) ?? globalSource
    }

    private func loadSlotConfigs() {
        let configURL = baseURL.appendingPathComponent("slot-configs.json")

        do {
            let data = try Data(contentsOf: configURL)
            let configs = try JSONDecoder().decode([TimeSlotConfig].self, from: data)
            for config in configs {
                slotConfigs[config.slot] = config
            }
        } catch {
            print("[UserWallpaperManager] Failed to load slot configs: \(error)")
        }
    }

    private func saveSlotConfigs() {
        let configURL = baseURL.appendingPathComponent("slot-configs.json")
        let configs = Array(slotConfigs.values)

        do {
            let data = try JSONEncoder().encode(configs)
            try data.write(to: configURL)
        } catch {
            print("[UserWallpaperManager] Failed to save slot configs: \(error)")
        }
    }

    // MARK: - iCloud Status

    var isUsingiCloud: Bool {
        return baseURL.path.contains("Mobile Documents")
    }

    private func normalizedImportDestination(for sourceURL: URL, in directory: URL) throws -> URL {
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

    private func writeNormalizedImage(from sourceURL: URL, to destinationURL: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw NSError(domain: "HorizonImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Image could not be decoded"])
        }

        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        let sourceWidth = sourceProperties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let sourceHeight = sourceProperties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxDimension = max(sourceWidth, sourceHeight)

        let transformedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxDimension, 1)
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            transformedOptions as CFDictionary
        ) else {
            throw NSError(domain: "HorizonImport", code: -1, userInfo: [NSLocalizedDescriptionKey: "Image could not be decoded"])
        }

        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "HorizonImport", code: -2, userInfo: [NSLocalizedDescriptionKey: "Image destination could not be created"])
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "HorizonImport", code: -3, userInfo: [NSLocalizedDescriptionKey: "Image normalization context could not be created"])
        }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let normalizedImage = context.makeImage() else {
            throw NSError(domain: "HorizonImport", code: -4, userInfo: [NSLocalizedDescriptionKey: "Image normalization failed"])
        }

        CGImageDestinationAddImage(destination, normalizedImage, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            throw NSError(domain: "HorizonImport", code: -5, userInfo: [NSLocalizedDescriptionKey: "Image write failed"])
        }
    }
}
