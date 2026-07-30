import AppKit
import Foundation
import ImageIO

final class WallpaperPreviewLoader {
    static let shared = WallpaperPreviewLoader()

    private let cache = NSCache<NSString, NSImage>()
    // ImageIO's CGImageSourceCreateThumbnailAtIndex offloads the real decode to
    // its own internal worker threads, which run at Default QoS. If THIS queue is
    // .userInitiated, our decode thread blocks waiting on those Default-QoS
    // workers — a priority inversion (high waiting on low) that Xcode's Thread
    // Performance Checker flags as a Hang Risk and that can stall the preview.
    // Elevating above Default gained nothing, because ImageIO caps the work at
    // Default regardless. Match Default so the waiter never outranks what it
    // waits on, which removes the inversion.
    private let queue = DispatchQueue(label: "com.horizon.preview-loader", qos: .default)

    // Coalesces concurrent loadImage calls for the same URL. When two views
    // (sidebar wallpaper card + dashboard wallpaper card) both refresh on
    // currentWallpaperName change, they used to enqueue two separate
    // decodes on the serial queue. The first completion fired ~10-30ms
    // before the second, so SwiftUI rendered them in different frames
    // and the user saw the two cards update out of sync. With coalescing,
    // the second caller piggybacks on the first decode and all waiters'
    // completions fire in the same DispatchQueue.main.async block so
    // SwiftUI batches their @State writes into a single render pass.
    private let pendingLock = NSLock()
    private var pendingCompletions: [String: [(NSImage?) -> Void]] = [:]

    private init() {
        cache.countLimit = 64
    }

    static func preferredPreviewURL(
        liveURL: URL?,
        fallbackURL: URL?,
        authoritativeURL: URL? = nil,
        isReadable: (URL) -> Bool = WallpaperPreviewLoader.isReadablePreviewFile
    ) -> URL? {
        // A wallpaper Horizon just applied itself is authoritative: it outranks
        // the live-desktop read, which NSWorkspace can briefly report stale right
        // after a set (the stale-preview-over-applied-wallpaper bug).
        if let authoritativeURL, isReadable(authoritativeURL) {
            return authoritativeURL
        }
        if let liveURL, isReadable(liveURL) {
            return liveURL
        }
        if let fallbackURL, isReadable(fallbackURL) {
            return fallbackURL
        }
        return nil
    }

    nonisolated static func isReadablePreviewFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    func loadImage(from url: URL, maxPixelSize: CGFloat = 1200, completion: @escaping (NSImage?) -> Void) {
        loadImage(from: url, fallbackURL: nil, maxPixelSize: maxPixelSize, completion: completion)
    }

    func loadImage(
        from url: URL,
        fallbackURL: URL?,
        maxPixelSize: CGFloat = 1200,
        completion: @escaping (NSImage?) -> Void
    ) {
        let cacheKey = url.path as NSString
        if let cached = cache.object(forKey: cacheKey) {
            completion(cached)
            return
        }

        // Coalescing key includes maxPixelSize so a request for a 400px
        // thumbnail doesn't accidentally satisfy a waiter that asked for 1200px.
        let coalesceKey = "\(Int(maxPixelSize))|\(url.path)"
        pendingLock.lock()
        if pendingCompletions[coalesceKey] != nil {
            // Decode is already in flight for this URL; piggyback.
            pendingCompletions[coalesceKey]?.append(completion)
            pendingLock.unlock()
            return
        }
        pendingCompletions[coalesceKey] = [completion]
        pendingLock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let start = CFAbsoluteTimeGetCurrent()
            var loadedURL = url
            var image = self.makeThumbnail(for: url, maxPixelSize: maxPixelSize)
            if image == nil,
               let fallbackURL,
               fallbackURL.path != url.path {
                loadedURL = fallbackURL
                image = self.makeThumbnail(for: fallbackURL, maxPixelSize: maxPixelSize)
            }
            let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            if let image {
                self.cache.setObject(image, forKey: loadedURL.path as NSString)
            }

            // Snapshot and clear the pending list under the lock so any
            // request that arrives after we cleared the entry takes the
            // fresh-decode path again (or hits the cache we just populated).
            self.pendingLock.lock()
            let waiters = self.pendingCompletions.removeValue(forKey: coalesceKey) ?? []
            self.pendingLock.unlock()

            DispatchQueue.main.async {
                AppPerformanceMetrics.shared.recordPreviewDecode(durationMs: durationMs)
                HorizonDebugLog.shared.log("preview.decode", fields: [
                    "url": loadedURL.lastPathComponent,
                    "durationMs": Int(durationMs.rounded()),
                    "waiters": waiters.count
                ])
                // Fire every waiter in the same main dispatch so SwiftUI
                // batches the resulting @State writes into one render pass.
                for callback in waiters {
                    callback(image)
                }
            }
        }
    }

    func invalidate(_ url: URL?) {
        guard let url else { return }
        cache.removeObject(forKey: url.path as NSString)
    }

    private func makeThumbnail(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard Self.isReadablePreviewFile(url) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: cgImage, size: .zero)
        }

        return NSImage(contentsOf: url)
    }
}
