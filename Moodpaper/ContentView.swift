import SwiftUI
import AppKit
internal import Combine

struct ContentView: View {
    @Environment(\.openWindow) var openWindow
    @ObservedObject private var wallpaperManager = WallpaperManager.shared
    @StateObject private var userWallpaperManager = UserWallpaperManager.shared
    @ObservedObject private var moodStore = MoodStore.shared
    @State private var previewImage: NSImage?
    @State private var previewImageURL: URL?
    @AppStorage(HorizonScheduleDefaults.pauseRotationKey) private var pauseRotation: Bool = false
    @State private var showingUnpinAlert = false
    private let appDidBecomeActive = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    private let activeSpaceDidChange = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)

    private var wallpapersPerDay: Int {
        let stored = UserDefaults.standard.double(forKey: HorizonScheduleDefaults.wallpapersPerDayKey)
        return stored == 0 ? 8 : Int(stored)
    }

    /// Distinguishes a genuinely empty mood from a preview that just hasn't
    /// loaded yet, so the empty-state caption only appears when there is
    /// actually nothing to show.
    private var hasAnyMoodWallpapers: Bool {
        guard let mood = moodStore.activeMood else { return false }
        return moodStore.totalWallpaperCount(in: mood) > 0
    }

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack {
                VStack(alignment: .leading, spacing: HorizonSpacing.xs) {
                    Text("Moodpaper")
                        .font(HorizonTypography.title3)
                        .foregroundColor(.primary)
                    HStack(spacing: HorizonSpacing.xs) {
                        Image(systemName: currentTimeSlotIcon())
                            .font(HorizonTypography.caption)
                            .foregroundStyle(currentTimeSlotColor())
                            .accessibilityHidden(true)
                        Text(currentSlotName())
                            .font(HorizonTypography.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
            }
            .padding(.horizontal, HorizonSpacing.md)
            .padding(.vertical, HorizonSpacing.md)

            Divider()

            // Current wallpaper info
            VStack(spacing: HorizonSpacing.md) {
                ZStack {
                    // Current wallpaper preview
                    Color.clear
                        .overlay {
                            if let image = previewImage {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else if !hasAnyMoodWallpapers {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(currentSlotGradient())
                                    .overlay {
                                        VStack(spacing: HorizonSpacing.xs) {
                                            Image(systemName: "photo.badge.plus")
                                                .font(.system(size: 26, weight: .ultraLight))
                                                .foregroundColor(.white.opacity(0.4))
                                                .accessibilityHidden(true)
                                            Text("No wallpaper yet")
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundColor(.white.opacity(0.6))
                                        }
                                    }
                            } else {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(currentSlotGradient())
                                    .overlay {
                                        Image(systemName: "photo")
                                            .font(.system(size: 32, weight: .ultraLight))
                                            .foregroundColor(.white.opacity(0.3))
                                            .accessibilityHidden(true)
                                    }
                            }
                        }
                        .clipped()

                    // Overlay content
                    VStack {
                        // Pin indicator
                        HStack {
                            if pauseRotation {
                                Button {
                                    showingUnpinAlert = true
                                } label: {
                                    Image(systemName: "pin.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(Circle().fill(Color.yellow.opacity(0.8)))
                                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                                        .padding(8)
                                }
                                .buttonStyle(.plain)
                                .help("Click to unpin")
                                .accessibilityLabel("Unpin current wallpaper")
                            }
                            Spacer()
                        }

                        // Loading indicator
                        if wallpaperManager.isChangingWallpaper {
                            VStack(spacing: HorizonSpacing.xs) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .tint(.white)
                                Text("Changing wallpaper…")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.white)
                            }
                            .padding(HorizonSpacing.md)
                            .background(Color.black.opacity(0.5))
                            .cornerRadius(8)
                        }

                        Spacer()
                        HStack {
                            Text(currentSlotName())
                                .font(HorizonTypography.callout)
                                .foregroundColor(.white)
                                .padding(.horizontal, HorizonSpacing.xs)
                                .padding(.vertical, HorizonSpacing.xs)
                                .background(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                                .cornerRadius(6)
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.5)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    .alert("Unpin Wallpaper", isPresented: $showingUnpinAlert) {
                        Button("Cancel", role: .cancel) { }
                        Button("Unpin", role: .destructive) {
                            pauseRotation = false
                        }
                    } message: {
                        Text("Are you sure you want to unpin this wallpaper? Rotation will resume.")
                    }
                }
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(LiquidGlassTokens.strokeDefault, lineWidth: 1)
                )
                .shadow(color: LiquidGlassTokens.shadow2, radius: 10, y: 4)

                // Error display
                if let error = wallpaperManager.lastError {
                    HStack(spacing: HorizonSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                            .accessibilityHidden(true)
                        Text(error)
                            .font(HorizonTypography.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            wallpaperManager.lastError = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss error message")
                    }
                    .padding(HorizonSpacing.xs)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }

                // Next change countdown
                HStack {
                    Spacer()
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    Text("Next Change in \(wallpaperManager.nextChangeCountdown)")
                        .font(HorizonTypography.callout)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 4)
            }
            .padding(16)
            .liquidGlassCard(elevated: true, cornerRadius: LiquidGlassTokens.radiusLG)
            .onChange(of: wallpaperManager.currentWallpaperName) { _, newName in
                loadPreviewImage(newName)
            }
            .onAppear {
                loadPreviewImage(wallpaperManager.currentWallpaperName)
            }
            .onReceive(appDidBecomeActive) { _ in
                loadPreviewImage(wallpaperManager.currentWallpaperName)
            }
            .onReceive(activeSpaceDidChange) { _ in
                loadPreviewImage(wallpaperManager.currentWallpaperName)
            }

            Divider()

            // Quick actions
            VStack(spacing: HorizonSpacing.xs) {
                // Controls row
                HStack(spacing: HorizonSpacing.xs) {
                    ActionButton(icon: "shuffle", label: "Skip") {
                        wallpaperManager.skipToNext()
                    }
                    .disabled(wallpaperManager.isChangingWallpaper)
                    ActionButton(icon: pauseRotation ? "pin.fill" : "pin", label: "Pin", tint: pauseRotation ? .yellow : nil) {
                        pauseRotation.toggle()
                    }
                    ActionButton(icon: wallpaperManager.isRunning ? "pause.fill" : "play.fill",
                                 label: wallpaperManager.isRunning ? "Pause" : "Resume") {
                        if wallpaperManager.isRunning {
                            wallpaperManager.stopEngine()
                        } else {
                            wallpaperManager.startEngine()
                        }
                    }
                }

                Button(action: openSettingsAndBringToFront) {
                    HStack {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                        Text("Open Moodpaper Settings")
                            .font(.system(size: 12))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HorizonSpacing.xs)
                    .foregroundColor(.primary)
                }
                .buttonStyle(LiquidGlassActionButtonStyle())
                .accessibilityLabel("Open Moodpaper settings")
            }
            .padding(HorizonSpacing.md)
            .liquidGlassCard(cornerRadius: LiquidGlassTokens.radiusLG)

            Divider()

            // Quit button
            HStack {
                Text(formattedTime())
                    .font(HorizonTypography.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Quit Moodpaper") {
                    NSApplication.shared.terminate(nil)
                }
                .font(HorizonTypography.caption)
                .foregroundColor(.secondary)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, HorizonSpacing.md)
            .padding(.vertical, HorizonSpacing.xs)
        }
        .frame(width: 320)
        .onReceive(wallpaperManager.$currentWallpaperName) { _ in
            // Force view update when wallpaper changes (time slot might have changed)
        }
    }

    // MARK: - Time slot logic

    private func loadPreviewImage(_ wallpaperName: String) {
        wallpaperManager.syncCurrentWallpaperWithDesktop()

        let liveURL = wallpaperManager.liveDesktopImageURL()
        let fallbackURL = wallpaperManager.currentWallpaperURL()
        let candidateURL = WallpaperPreviewLoader.preferredPreviewURL(
            liveURL: liveURL,
            fallbackURL: fallbackURL
        )
        previewImageURL = candidateURL

        if let candidateURL {
            WallpaperPreviewLoader.shared.loadImage(from: candidateURL, fallbackURL: fallbackURL) { image in
                guard previewImageURL == candidateURL else { return }
                previewImage = image
            }
        } else {
            previewImage = nil
        }
    }

    func currentSlotName() -> String {
        let slot = wallpaperManager.currentTimeSlot()
        switch slot {
        case "deep-night": return "Deep Night"
        case "dawn": return "Dawn"
        case "sunrise": return "Sunrise"
        case "morning": return "Morning"
        case "midday": return "Midday"
        case "afternoon": return "Afternoon"
        case "golden-hour": return "Golden Hour"
        case "dusk": return "Dusk"
        case "evening": return "Night"
        default: return "Night"
        }
    }

    func currentTimeSlotIcon() -> String {
        let slot = wallpaperManager.currentTimeSlot()
        switch slot {
        case "deep-night": return "moon.stars.fill"
        case "dawn": return "sun.horizon.fill"
        case "sunrise": return "sun.and.horizon.fill"
        case "morning": return "sun.max.fill"
        case "midday": return "sun.max.fill"
        case "afternoon": return "sun.min.fill"
        case "golden-hour": return "sunset.fill"
        case "dusk": return "moon.fill"
        case "evening": return "moon.stars.fill"
        default: return "moon.stars.fill"
        }
    }

    func currentTimeSlotColor() -> Color {
        let slot = wallpaperManager.currentTimeSlot()
        switch slot {
        case "deep-night": return Color(hex: "7B6A9E")
        case "dawn": return Color(hex: "D4A574")
        case "sunrise": return Color(hex: "F2C47E")
        case "morning": return Color(hex: "7DCBF0")
        case "midday": return Color(hex: "5BA3D4")
        case "afternoon": return Color(hex: "4A90D9")
        case "golden-hour": return Color(hex: "E8A85C")
        case "dusk": return Color(hex: "C05D5D")
        case "evening": return Color(hex: "7B6A9E")
        default: return Color(hex: "7B6A9E")
        }
    }

    func currentSlotGradient() -> LinearGradient {
        switch wallpaperManager.currentTimeSlot() {
        case "deep-night":
            return LinearGradient(colors: [Color(hex: "0D0D1A"), Color(hex: "1A0D2E")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "dawn":
            return LinearGradient(colors: [Color(hex: "4A3B5C"), Color(hex: "D4A574")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "sunrise":
            return LinearGradient(colors: [Color(hex: "E8956D"), Color(hex: "F2C47E")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "morning":
            return LinearGradient(colors: [Color(hex: "7DCBF0"), Color(hex: "B8D9E8")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "midday":
            return LinearGradient(colors: [Color(hex: "5BA3D4"), Color(hex: "7DCBF0")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "afternoon":
            return LinearGradient(colors: [Color(hex: "4A90D9"), Color(hex: "5BA3D4")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "golden-hour":
            return LinearGradient(colors: [Color(hex: "E8A85C"), Color(hex: "E8956D")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "dusk":
            return LinearGradient(colors: [Color(hex: "C05D5D"), Color(hex: "4A4A7A")], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(colors: [Color(hex: "4A4A7A"), Color(hex: "1A1B2E")], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    func formattedTime() -> String {
        Self.timeFormatter.string(from: Date())
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    func openSettingsAndBringToFront() {
        // Use SwiftUI's openWindow to open or focus the settings window
        openWindow(id: "settings")

        // Bring the Settings window to front of all apps
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Find the Settings window and bring it to front
            if let settingsWindow = NSApplication.shared.windows.first(where: { window in
                // The settings window has id "settings" in the WindowGroup
                window.identifier?.rawValue == "settings" ||
                window.identifier?.rawValue.hasPrefix("settings-") == true
            }) {
                // Make the app active first so the window can come to front
                NSApp.activate(ignoringOtherApps: true)

                // Bring window to front and make it key
                settingsWindow.makeKeyAndOrderFront(nil)
                settingsWindow.orderFrontRegardless()
            }
        }
    }
}

// MARK: - Action Button Component

struct ActionButton: View {
    let icon: String
    let label: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: HorizonSpacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(tint ?? .primary)
                    .accessibilityHidden(true)
                Text(label)
                    .font(HorizonTypography.caption2)
                    .foregroundColor(tint ?? .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HorizonSpacing.xs)
        }
        .buttonStyle(LiquidGlassActionButtonStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
