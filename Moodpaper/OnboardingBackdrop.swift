import AppKit
import ImageIO
import SwiftUI
internal import Combine

// MARK: - Image store

/// Two-tier image store for the onboarding backdrop.
///
/// The bundled frames are 3840px. Decoding all nine at presentation size would
/// cost well over 100 MB of bitmaps for a window that lives for one minute, and
/// decoding on demand would stutter the dial scrub. So:
///
/// - **proxy tier**: all nine at 640px, resident. ~5 MB total, decoded once.
///   Guarantees a scrub never lands on an empty frame, however fast it moves.
/// - **detail tier**: the current slot and its neighbours at presentation size,
///   capped at three. Fades in over the proxy when it arrives.
///
/// The shared `WallpaperPreviewLoader` is deliberately not used here: it keys
/// its cache on path alone, so a 640px decode and a 2400px decode of the same
/// URL overwrite each other. It also holds 64 entries app-wide, which these
/// large frames should not occupy after onboarding closes.
@MainActor
final class OnboardingImageStore: ObservableObject {
    @Published private(set) var proxies: [String: NSImage] = [:]
    @Published private(set) var details: [String: NSImage] = [:]

    private var detailOrder: [String] = []
    private var inFlight: Set<String> = []
    private let detailLimit = 3
    private let proxyPixelSize: CGFloat = 640

    private var urls: [String: URL] = [:]

    /// Presentation size for the detail tier, in pixels. Set from the live
    /// window so a Retina backdrop is not upscaled from a smaller decode.
    private var detailPixelSize: CGFloat = 2400

    func configure(urls: [String: URL], detailPixelSize: CGFloat) {
        self.urls = urls
        let requested = max(detailPixelSize, 1200)

        // The window can be dragged between displays of different scale
        // factors. Moving onto a sharper display has to invalidate the frames
        // already decoded for the duller one, or the backdrop stays soft.
        // Moving the other way keeps them: downscaling a larger decode costs
        // nothing and re-decoding would only churn.
        if requested > self.detailPixelSize * 1.15 {
            details.removeAll()
            detailOrder.removeAll()
        }
        self.detailPixelSize = requested
        loadProxies()
    }

    /// Decodes every frame small. Runs once; cheap enough to do up front.
    private func loadProxies() {
        for (slotID, url) in urls where proxies[slotID] == nil {
            Task.detached(priority: .utility) { [proxyPixelSize] in
                let image = Self.decode(url, maxPixelSize: proxyPixelSize)
                await MainActor.run { [weak self] in
                    guard let self, let image else { return }
                    self.proxies[slotID] = image
                }
            }
        }
    }

    /// Requests full-size decodes for `slotID` and the slots on either side, so
    /// a continuing scrub finds them already warm.
    func prepareDetail(around slotID: String, in slotIDs: [String]) {
        guard let index = slotIDs.firstIndex(of: slotID) else { return }
        var wanted = [slotID]
        if index > 0 { wanted.append(slotIDs[index - 1]) }
        if index + 1 < slotIDs.count { wanted.append(slotIDs[index + 1]) }

        for slot in wanted { loadDetail(slot) }
        trimDetail(keeping: wanted)
    }

    private func loadDetail(_ slotID: String) {
        guard details[slotID] == nil, !inFlight.contains(slotID),
              let url = urls[slotID] else { return }
        inFlight.insert(slotID)
        Task.detached(priority: .userInitiated) { [detailPixelSize] in
            let image = Self.decode(url, maxPixelSize: detailPixelSize)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight.remove(slotID)
                guard let image else { return }
                self.details[slotID] = image
                self.detailOrder.removeAll { $0 == slotID }
                self.detailOrder.append(slotID)
            }
        }
    }

    /// Drops the least recently requested detail frames once over the cap.
    /// `keeping` is never evicted, so the visible frame cannot be pulled out
    /// from under the view.
    private func trimDetail(keeping: [String]) {
        guard detailOrder.count > detailLimit else { return }
        var order = detailOrder
        for slotID in order where !keeping.contains(slotID) {
            guard order.count > detailLimit else { break }
            details.removeValue(forKey: slotID)
            order.removeAll { $0 == slotID }
        }
        detailOrder = order
    }

    nonisolated static func decode(_ url: URL, maxPixelSize: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}

// MARK: - Backdrop

/// Full-bleed photographic backdrop that crossfades as the day slot changes.
///
/// In-window only by design: the real desktop changes exactly once, at the
/// commit moment, never during the scrub.
struct OnboardingBackdropView: View {
    let slotID: String
    let slotIDs: [String]
    @ObservedObject var store: OnboardingImageStore
    var fadeDuration: Double = 0.35
    /// Slow scale drift. Off for the dial, where the user's own scrubbing is
    /// the movement and a second motion competes with it.
    var isDrifting: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var driftIn = false

    private var image: NSImage? {
        store.details[slotID] ?? store.proxies[slotID]
    }

    /// Reduce Motion removes the drift but keeps the crossfade: the image
    /// change carries meaning here, so it dissolves rather than disappearing.
    private var driftScale: CGFloat {
        guard isDrifting, !reduceMotion else { return 1.0 }
        return driftIn ? 1.06 : 1.0
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Palette floor. Covers the frames before the first decode and
                // keeps the window from flashing black on a slow disk.
                LinearGradient(
                    colors: [
                        HorizonColors.accentForSlot(slotID).opacity(0.85),
                        HorizonColors.colorForSlot(slotID),
                        .black
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        // Aspect-fill only. The frames are 3:2 and 16:9 while
                        // the window is 16:10, so something must crop; nothing
                        // may stretch.
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(driftScale)
                        .clipped()
                        .id(slotID)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: fadeDuration), value: slotID)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: image)
        .onAppear {
            store.prepareDetail(around: slotID, in: slotIDs)
            startDriftIfNeeded()
        }
        .onChange(of: slotID) {
            store.prepareDetail(around: slotID, in: slotIDs)
        }
        .onChange(of: isDrifting) { startDriftIfNeeded() }
        .accessibilityHidden(true)
    }

    private func startDriftIfNeeded() {
        guard isDrifting, !reduceMotion else {
            driftIn = false
            return
        }
        withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
            driftIn = true
        }
    }
}

// MARK: - Legibility scrim

/// Shaped scrim that buys contrast for the glass card without flattening the
/// photograph.
///
/// A single top-to-bottom gradient was enough over generated gradients but not
/// over real photographs: a bright horizon (midday, sunrise) sits exactly where
/// the card's title lands. This adds a horizontal weight on the card's side and
/// keeps the opposite corner clear so the image still reads as an image.
struct OnboardingScrim: View {
    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.00), location: 0.00),
                    .init(color: .black.opacity(0.10), location: 0.45),
                    .init(color: .black.opacity(0.45), location: 0.78),
                    .init(color: .black.opacity(0.72), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.52), location: 0.00),
                    .init(color: .black.opacity(0.18), location: 0.38),
                    .init(color: .black.opacity(0.00), location: 0.70)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            // Lifts the top chrome (page dots, Skip) off bright skies.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.34), location: 0.00),
                    .init(color: .black.opacity(0.00), location: 0.16)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .accessibilityHidden(true)
    }
}
