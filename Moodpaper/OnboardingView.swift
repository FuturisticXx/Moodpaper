import SwiftUI
import CoreLocation
internal import Combine

/// Single source of truth for onboarding strings.
/// Tested in `MoodpaperTests/OnboardingViewTests.swift`.
///
/// The flow is three moments, not a feature tour: a living cover that
/// demonstrates the product before any click, a day dial the user scrubs to
/// watch the backdrop change mood, and a commit moment that changes the real
/// desktop exactly once.
///
/// Every moment runs on the nine bundled photographs in
/// `StarterWallpaperLibrary`, and those same nine files become the user's first
/// Vibe at the commit. Nothing shown during onboarding is a mock-up of a
/// capability the app does not have.
enum OnboardingCopy {
    static let coverEyebrow = "MOODPAPER"
    static let coverTitle = "Your desktop has moods."
    static let coverBody = "Wallpapers that drift through your day, from first light to deep night. You choose the feeling."
    static let coverCta = "Begin"

    static let dialEyebrow = "TURN THE DAY · 1 OF 2"
    static let dialTitle = "Drag the sun across your day."
    static let dialBody = "Every part of the day gets its own wallpaper. Drag to watch the light change."
    static let dialLocationPrompt = "Time these to your actual sunrise?"
    static let dialLocationCta = "Use My Location"
    static let dialLocationSkip = "Not now"
    static let dialLocationGranted = "Timed to your sky."
    static let dialLocationFallback = "Using standard times. You can refine with location anytime in Settings."
    static let dialCta = "Continue"

    static let nameEyebrow = "MAKE IT REAL · 2 OF 2"
    static let nameTitle = "Name this feeling."
    static let nameBody = "Your first Vibe starts with the day you just shaped. Swap in your own photos anytime."
    static let namePlaceholder = "Daybreak, Deep Focus, Cozy Weekend…"
    static let namePrefill = "Daybreak"
    static let namePrimaryCta = "Set My Desktop"
    static let nameSecondaryCta = "I'll do this later"
    static let nameCommittingLabel = "Setting your desktop…"
    static let nameCommitTimeout = "This is taking longer than usual. Your Vibe is saved, so you can close this and it will apply when macOS catches up."

    static let skipLink = "Skip"
    static let backLink = "Back"
}

enum VibeNaming {
    static let suggestions = ["Calm", "Focused", "Dreamy", "Energized"]

    /// Keeps the prefilled name from colliding with a Vibe the user already
    /// has. `MoodStore.create` allows duplicate names on purpose (so does the
    /// New Vibe button), which is fine when the user typed the name and not
    /// fine when onboarding filled it in for them: replaying the welcome and
    /// pressing the primary button would quietly mint a second "Daybreak".
    nonisolated static func uniqueName(_ base: String, existing: [String]) -> String {
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }
}

private enum OnboardingMoment: Int, CaseIterable {
    case cover = 0
    case dial = 1
    case name = 2
}

// MARK: - Root view

struct OnboardingView: View {
    /// 16:10, matching the aspect ratio of every Mac built-in display, so the
    /// backdrop reads as a desktop rather than as a picture of one. The window
    /// is fixed and centred; `AppDelegate.showOnboarding` sizes it from here.
    static let windowSize = CGSize(width: 1120, height: 700)

    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentMoment: OnboardingMoment = .cover
    @StateObject private var locationManager = LocationPermissionManager()

    /// Bundled starter photography, slotID → file URL. Resolved from the app
    /// bundle, so this is populated before the first frame is drawn.
    @State private var artURLs: [String: URL] = StarterWallpaperLibrary.allURLs()

    @StateObject private var imageStore = OnboardingImageStore()

    /// The display the window currently sits on. Drives the decode resolution,
    /// which matters now that the window can be dragged between displays.
    @State private var hostScreen: NSScreen?

    /// Dial position, seeded to the current time of day so the first thing
    /// the user sees under their cursor is "now".
    @State private var dayPosition: Double = OnboardingDayDial.position(
        forSlotIndex: OnboardingView.currentTimeSlotIndex(),
        slotCount: HorizonScheduleDefaults.orderedSlotIDs.count
    )
    @State private var coverSlotIndex = 0
    @State private var isCommitting = false

    /// Set when the commit poll gives up. The Vibe is already created and
    /// activated at that point, so this is a "still working on it" state, not
    /// an error to retry: re-pressing the CTA would create a duplicate Vibe.
    @State private var commitTimedOut = false

    /// Slow ambient cycle for the cover moment. The cover is the product
    /// demonstrating itself, so it starts moving before any button is pressed.
    ///
    /// 4.2s per frame rather than 3s: with real photographs there is something
    /// to look at, and a faster cut reads as a slideshow instead of weather.
    private let coverTimer = Timer.publish(every: 4.2, on: .main, in: .common).autoconnect()
    private static var coverCycle: [String] { StarterWallpaperLibrary.coverSequence }

    private var slotIDs: [String] { HorizonScheduleDefaults.orderedSlotIDs }

    private var dialSlotID: String {
        let index = OnboardingDayDial.slotIndex(for: dayPosition, slotCount: slotIDs.count)
        return slotIDs.indices.contains(index) ? slotIDs[index] : "morning"
    }

    nonisolated static func currentTimeSlotIndex(date: Date = Date()) -> Int {
        let hour = Calendar.current.component(.hour, from: date)
        let slotID = TimeSlot.from(hour: hour).slotID
        return HorizonScheduleDefaults.orderedSlotIDs.firstIndex(of: slotID) ?? 3
    }

    private var currentTimeSlotID: String {
        let index = Self.currentTimeSlotIndex()
        return slotIDs.indices.contains(index) ? slotIDs[index] : "morning"
    }

    private var backdropSlotID: String {
        switch currentMoment {
        case .cover:
            // Reduce Motion: no ambient loop; hold the current time of day.
            return reduceMotion ? currentTimeSlotID : Self.coverCycle[coverSlotIndex]
        case .dial:
            return dialSlotID
        case .name:
            // Settle on "now" so the window backdrop and the real desktop
            // show the same image at the commit moment.
            return currentTimeSlotID
        }
    }

    var body: some View {
        ZStack {
            // Layer 3: top chrome (page dots + skip/back)
            VStack {
                HStack {
                    PageDots(current: currentMoment.rawValue, total: OnboardingMoment.allCases.count)
                    Spacer()
                    if currentMoment == .cover {
                        TextLinkButton(title: OnboardingCopy.skipLink) {
                            completeOnboarding()
                        }
                    } else {
                        TextLinkButton(title: OnboardingCopy.backLink) {
                            goTo(OnboardingMoment(rawValue: currentMoment.rawValue - 1) ?? .cover)
                        }
                    }
                }
                .padding(.top, 22)
                .padding(.horizontal, 32)

                Spacer()
            }

            // Layer 4: bottom-anchored floating glass content card
            VStack {
                Spacer()
                HStack {
                    contentCard
                    Spacer()
                }
                .padding(.horizontal, 44)
                .padding(.bottom, 44)
            }
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        // The wallpaper and its legibility scrim bleed past the safe area as
        // a background, which does not participate in the content layout.
        // As sibling layers that each ignored the safe area themselves, they
        // resized the stack and shifted the card 110pt left, clipping it
        // against the window edge (seen in live verification).
        .background {
            ZStack {
                Color.black
                OnboardingBackdropView(
                    slotID: backdropSlotID,
                    slotIDs: slotIDs,
                    store: imageStore,
                    // The cover dissolves like weather; the dial answers the
                    // pointer, so it has to keep up with the drag.
                    fadeDuration: currentMoment == .cover ? 1.6 : 0.28,
                    isDrifting: currentMoment == .cover
                )
                OnboardingScrim()
            }
            .ignoresSafeArea()
        }
        // Onboarding is always a dark photographic surface, whatever the
        // system appearance is. Without this the materials and the name field
        // render in Light Mode: the glass card turns into a milky grey slab
        // that is *brighter* than a night photograph behind it, and the text
        // field arrives as a white box with a blue focus ring. Seen in live
        // verification; not visible from reading the code.
        .environment(\.colorScheme, .dark)
        .background(WindowScreenObserver(screen: $hostScreen))
        .onAppear { configureImageStore() }
        .onChange(of: hostScreen) { configureImageStore() }
        .onReceive(coverTimer) { _ in
            guard currentMoment == .cover, !reduceMotion else { return }
            coverSlotIndex = (coverSlotIndex + 1) % Self.coverCycle.count
        }
        // Every close path posts this, including the title bar's red button.
        // Clearing the flag makes the in-flight poll's `finish()` guard fall
        // through, so no menu bar pulse and no second close arrive after the
        // window is gone. The wallpaper it started is left to land on its own.
        .onReceive(NotificationCenter.default.publisher(for: .moodpaperOnboardingWindowWillClose)) { _ in
            isCommitting = false
        }
    }

    @ViewBuilder
    private var contentCard: some View {
        Group {
            switch currentMoment {
            case .cover:
                CoverCard(
                    store: imageStore,
                    onContinue: { goTo(.dial) }
                )
            case .dial:
                DayDialCard(
                    dayPosition: $dayPosition,
                    slotIDs: slotIDs,
                    locationManager: locationManager,
                    onContinue: { goTo(.name) }
                )
            case .name:
                NameVibeCard(
                    isCommitting: isCommitting,
                    hasTimedOut: commitTimedOut,
                    defaultName: VibeNaming.uniqueName(
                        OnboardingCopy.namePrefill,
                        existing: MoodStore.shared.moods.map(\.name)
                    ),
                    onCommit: { name in commitStarterVibe(named: name) },
                    onLater: { completeOnboarding() }
                )
            }
        }
        .id(currentMoment)
        .transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 14)),
                    removal: .opacity
                )
        )
    }

    private func goTo(_ moment: OnboardingMoment) {
        if reduceMotion {
            currentMoment = moment
        } else {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                currentMoment = moment
            }
        }
    }

    /// Point the image store at the bundled frames, sized for this display.
    ///
    /// Detail decodes are matched to the window's backing pixels plus the
    /// cover's 6% drift headroom, so a Retina backdrop is never upscaled from a
    /// smaller decode and never decoded larger than it can show.
    private func configureImageStore() {
        // The window's own screen, not `NSScreen.main`: the user can park
        // onboarding on a 1x external display while the key window is
        // elsewhere, and decoding for the wrong scale factor either wastes
        // memory or leaves the backdrop soft.
        let scale = hostScreen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let detailPixels = Self.windowSize.width * scale * 1.08
        imageStore.configure(urls: artURLs, detailPixelSize: detailPixels)
    }

    /// The one moment the real desktop changes: create the starter Vibe from
    /// the generated art, activate it, and let the engine's coalesced refresh
    /// apply it while the window backdrop already shows the same image.
    private func commitStarterVibe(named name: String) {
        guard !isCommitting, !commitTimedOut else { return }
        isCommitting = true

        // Touching the singleton first guarantees startEngine() has wired
        // MoodStore.onActiveMoodChange before any activation below fires it.
        _ = WallpaperManager.shared

        let store = MoodStore.shared
        guard let mood = store.create(name: name) else {
            isCommitting = false
            return
        }

        // The generated files are already normalized JPEGs, so a plain copy
        // into the slot folders is enough; the folder IS the assignment.
        for (slotID, url) in artURLs {
            guard let slot = TimeSlot.allCases.first(where: { $0.slotID == slotID }) else { continue }
            let destination = store.folderURL(for: slot, in: mood)
                .appendingPathComponent("starter-\(slotID).jpg")
            if !FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.copyItem(at: url, to: destination)
            }
        }

        // First mood: create() already activated it and scheduled the engine
        // refresh (which runs after this synchronous block, so the files
        // above are in place). Any other case: activate() schedules it here.
        store.activate(mood)

        waitForDesktopChange()
    }

    /// Holds the window open until the engine has actually put the new
    /// wallpaper on screen, then lingers a beat so the change is watched
    /// rather than discovered. Preparing the image takes a few seconds, so a
    /// fixed delay closed the window before anything happened, which loses
    /// the one moment the whole flow exists to deliver. The timeout keeps a
    /// stalled engine from trapping the user in onboarding.
    private func waitForDesktopChange() {
        let manager = WallpaperManager.shared
        let before = manager.currentWallpaperName
        let deadline = Date().addingTimeInterval(12)

        func finish() {
            guard isCommitting else { return }
            isCommitting = false
            NotificationCenter.default.post(name: .moodpaperOnboardingCommitted, object: nil)
            completeOnboarding()
        }

        func poll() {
            if manager.currentWallpaperName != before {
                // Let the applied wallpaper sit on screen before the window
                // fades, so the user sees it change and not just the result.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { finish() }
                return
            }
            guard Date() < deadline else {
                // Closing silently here was indistinguishable from success and
                // left the user with an unchanged desktop and no explanation.
                // Hold the window open, say what happened, and let them leave
                // on their own. The Vibe is already active, so the wallpaper
                // may still land after they go.
                guard isCommitting else { return }
                isCommitting = false
                commitTimedOut = true
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
        }
        poll()
    }

    /// Closes the onboarding window. Persistence (the `hasCompletedOnboarding`
    /// flag and the `onboardingCompleted` analytics event) is handled by the
    /// `NSWindow.willCloseNotification` observer in `AppDelegate.showOnboarding`,
    /// so closing via the red traffic light produces the same effect.
    private func completeOnboarding() {
        withAnimation { isPresented = false }
    }
}

// MARK: - Top chrome

private struct PageDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { idx in
                Capsule()
                    .fill(idx == current ? .white : .white.opacity(0.3))
                    .frame(width: idx == current ? 22 : 8, height: 4)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current)
            }
        }
    }
}

private struct TextLinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(.white.opacity(0.10))
                )
                .overlay(
                    Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Floating content cards

private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    /// Fixed content width. Constraining the card from the outside let the
    /// intrinsic width of the longest line win, which pushed the card past
    /// the window's left edge and clipped it (seen in live verification).
    static var contentWidth: CGFloat { 468 }

    var body: some View {
        content()
            .frame(width: Self.contentWidth, alignment: .leading)
            .padding(36)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                    // Contrast floor. The material alone tracks the photograph
                    // behind it, so over a bright morning frame the eyebrow
                    // and body text lost almost all contrast. This tint keeps
                    // white text legible over every frame in the set while
                    // still letting the image's shape read through the glass.
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.black.opacity(0.34), .black.opacity(0.16)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    // Specular edge light, the part that makes it read as
                    // glass rather than as a dark rectangle.
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.13), .white.opacity(0.0)],
                                startPoint: .topLeading,
                                endPoint: .bottom
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 34, y: 20)
    }
}

private struct CardEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.65))
    }
}

private struct CardTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 32, weight: .semibold))
            .tracking(-0.4)
            .foregroundStyle(.white)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CardBody: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .regular))
            .lineSpacing(4)
            .foregroundStyle(.white.opacity(0.78))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PrimaryCTAButton: View {
    let title: String
    var icon: String? = nil
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(
                LinearGradient(
                    colors: [.white, .white.opacity(0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .shadow(color: .white.opacity(0.18), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }
}

private struct SecondaryGhostButton: View {
    let title: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.20), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }
}

/// Non-interactive stand-in for the primary CTA while the desktop change is
/// in flight. Deliberately not a disabled button: preparing the wallpaper
/// takes several seconds, and a dimmed button reads as frozen rather than as
/// working, which is what made reaching for an exit the rational move.
private struct CommittingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 9) {
            // Reduce Motion: the spinner is the one thing here that cannot
            // hold still, so it is replaced with a static glyph.
            if reduceMotion {
                Image(systemName: "hourglass")
                    .font(.system(size: 13, weight: .semibold))
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .tint(.white)
            }
            Text(OnboardingCopy.nameCommittingLabel)
                .font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 18)
        .frame(height: 40)
        .background(.white.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(OnboardingCopy.nameCommittingLabel)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Moment 1: Living cover

private struct CoverCard: View {
    @ObservedObject var store: OnboardingImageStore
    let onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 22) {
                CardEyebrow(text: OnboardingCopy.coverEyebrow)
                CardTitle(text: OnboardingCopy.coverTitle)
                CardBody(text: OnboardingCopy.coverBody)

                // Reduce Motion replaces the ambient backdrop loop with a
                // static day-arc strip: same idea, no movement.
                if reduceMotion {
                    HStack(spacing: 10) {
                        ForEach(["sunrise", "golden-hour", "deep-night"], id: \.self) { slotID in
                            ArtThumbnail(slotID: slotID, image: store.proxies[slotID])
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Sunrise, golden hour, and night wallpapers from the starter set")
                }

                HStack(spacing: 12) {
                    PrimaryCTAButton(title: OnboardingCopy.coverCta, action: onContinue)
                }
                .padding(.top, 4)
            }
        }
    }
}

/// Reuses the backdrop store's proxy decode rather than starting its own, so
/// the strip costs no extra image memory.
private struct ArtThumbnail: View {
    let slotID: String
    let image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(HorizonColors.colorForSlot(slotID))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 96, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Moment 2: Day dial

private struct DayDialCard: View {
    @Binding var dayPosition: Double
    let slotIDs: [String]
    @ObservedObject var locationManager: LocationPermissionManager
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var locationDismissed = false

    private var currentSlot: TimeSlot? {
        let index = OnboardingDayDial.slotIndex(for: dayPosition, slotCount: slotIDs.count)
        guard slotIDs.indices.contains(index) else { return nil }
        return TimeSlot.allCases.first { $0.slotID == slotIDs[index] }
    }

    /// The location ask surfaces only when the user scrubs into a slot that
    /// location actually improves (sunrise/dusk timing), and only while the
    /// system would still show the real prompt. Just-in-time by design.
    private var showsLocationAsk: Bool {
        guard !locationDismissed else { return false }
        guard currentSlot == .sunrise || currentSlot == .dusk || currentSlot == .dawn else { return false }
        switch locationManager.authorizationStatus {
        case .notDetermined: return true
        default: return false
        }
    }

    private var locationStatusLine: (symbol: String, tint: Color, text: String)? {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return ("checkmark.circle.fill", .green, OnboardingCopy.dialLocationGranted)
        case .denied, .restricted:
            return ("clock.fill", .white.opacity(0.6), OnboardingCopy.dialLocationFallback)
        default:
            return locationDismissed
                ? ("clock.fill", .white.opacity(0.6), OnboardingCopy.dialLocationFallback)
                : nil
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                CardEyebrow(text: OnboardingCopy.dialEyebrow)
                CardTitle(text: OnboardingCopy.dialTitle)
                CardBody(text: OnboardingCopy.dialBody)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(currentSlot?.displayName ?? "")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(reduceMotion ? .identity : .numericText())
                        Text(currentSlot?.timeRange ?? "")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: currentSlot)

                    OnboardingDayDial(dayPosition: $dayPosition, slotIDs: slotIDs)
                }

                locationZone

                HStack(spacing: 12) {
                    PrimaryCTAButton(title: OnboardingCopy.dialCta, action: onContinue)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var locationZone: some View {
        if showsLocationAsk {
            HStack(spacing: 10) {
                Image(systemName: "location.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(OnboardingCopy.dialLocationPrompt)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 8)
                Button(OnboardingCopy.dialLocationCta) {
                    locationManager.requestPermission()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(.white, in: Capsule())
                Button(OnboardingCopy.dialLocationSkip) {
                    locationDismissed = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            }
            .padding(12)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity.combined(with: .offset(y: 8))
            )
        } else if let status = locationStatusLine {
            HStack(spacing: 8) {
                Image(systemName: status.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(status.tint)
                Text(status.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Moment 3: Make it real

private struct NameVibeCard: View {
    let isCommitting: Bool
    let hasTimedOut: Bool
    let defaultName: String
    let onCommit: (String) -> Void
    let onLater: () -> Void
    @State private var name: String
    @FocusState private var isNameFocused: Bool

    init(
        isCommitting: Bool,
        hasTimedOut: Bool,
        defaultName: String,
        onCommit: @escaping (String) -> Void,
        onLater: @escaping () -> Void
    ) {
        self.isCommitting = isCommitting
        self.hasTimedOut = hasTimedOut
        self.defaultName = defaultName
        self.onCommit = onCommit
        self.onLater = onLater
        _name = State(initialValue: defaultName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 18) {
                CardEyebrow(text: OnboardingCopy.nameEyebrow)
                CardTitle(text: OnboardingCopy.nameTitle)
                CardBody(text: OnboardingCopy.nameBody)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Vibe name")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                    // Plain style with our own chrome: the stock bordered field
                    // arrives as a system-grey box with a blue focus ring,
                    // which reads as a form control dropped onto the glass.
                    // The focus state is still drawn, just in the card's own
                    // language rather than the system's.
                    TextField(OnboardingCopy.namePlaceholder, text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    .white.opacity(isNameFocused ? 0.55 : 0.20),
                                    lineWidth: isNameFocused ? 2 : 1
                                )
                        )
                        .focused($isNameFocused)
                        .onSubmit(commit)
                }

                HStack(spacing: 8) {
                    ForEach(VibeNaming.suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            name = suggestion
                            isNameFocused = true
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Vibe name suggestions")

                HStack(spacing: 12) {
                    if isCommitting {
                        CommittingIndicator()
                    } else {
                        PrimaryCTAButton(
                            title: OnboardingCopy.namePrimaryCta,
                            icon: "sparkles",
                            isDisabled: trimmedName.isEmpty || hasTimedOut,
                            action: commit
                        )
                    }
                    // The only exit that stays live during the commit is the
                    // title bar's close button, which cancels the handoff.
                    // Leaving this one enabled too would let a user close the
                    // window a beat before the change they came here to see.
                    SecondaryGhostButton(
                        title: OnboardingCopy.nameSecondaryCta,
                        isDisabled: isCommitting,
                        action: onLater
                    )
                }
                .padding(.top, 4)

                if hasTimedOut {
                    Text(OnboardingCopy.nameCommitTimeout)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                isNameFocused = true
            }
        }
    }

    private func commit() {
        guard !trimmedName.isEmpty, !isCommitting, !hasTimedOut else { return }
        onCommit(trimmedName)
    }
}

// MARK: - Permission manager (unchanged)

@MainActor
class LocationPermissionManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private let locationManager = CLLocationManager()
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        locationManager.delegate = self
        authorizationStatus = LocationService.shared.authorizationStatus

        LocationService.shared.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.authorizationStatus = status
                self?.startSharedLocationIfAuthorized()
            }
            .store(in: &cancellables)

        if isAuthorized(authorizationStatus) {
            LocationService.shared.startUpdatingLocation()
        }
    }

    func requestPermission() {
        UserDefaults.standard.set(true, forKey: "useDeviceLocation")
        LocationService.shared.startUpdatingLocation(requestPermissionIfNeeded: true)
        authorizationStatus = locationManager.authorizationStatus
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        startSharedLocationIfAuthorized()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        authorizationStatus = status
        startSharedLocationIfAuthorized()
    }

    private func startSharedLocationIfAuthorized() {
        if isAuthorized(authorizationStatus) {
            LocationService.shared.startUpdatingLocation()
        }
    }

    private func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways || status == .authorized
    }
}
