import SwiftUI
import AppKit
import EventKit
import ServiceManagement
import UserNotifications
import UniformTypeIdentifiers
internal import Combine

// MARK: - Support links

enum MoodpaperSupportLinks {
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/2damaxdevelopement")!
}

// MARK: - Schedule model

@MainActor
final class HorizonScheduleSettings: ObservableObject {
    struct TimeSlot: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let swatch: (red: Double, green: Double, blue: Double)
    }

    static let timeSlots: [TimeSlot] = [
        TimeSlot(id: "deep-night",  title: "Deep Night",  symbol: "moon.stars.fill",    swatch: (0.05, 0.05, 0.10)),
        TimeSlot(id: "dawn",        title: "Dawn",         symbol: "sun.horizon.fill",   swatch: (0.49, 0.42, 0.62)),
        TimeSlot(id: "sunrise",     title: "Sunrise",      symbol: "sunrise.fill",        swatch: (0.91, 0.58, 0.43)),
        TimeSlot(id: "morning",     title: "Morning",      symbol: "cloud.sun.fill",      swatch: (0.49, 0.80, 0.94)),
        TimeSlot(id: "midday",      title: "Midday",       symbol: "sun.max.fill",        swatch: (0.36, 0.64, 0.83)),
        TimeSlot(id: "afternoon",   title: "Afternoon",    symbol: "sun.haze.fill",       swatch: (0.29, 0.57, 0.85)),
        TimeSlot(id: "golden-hour", title: "Golden Hour",  symbol: "camera.macro",        swatch: (0.91, 0.66, 0.36)),
        TimeSlot(id: "dusk",        title: "Dusk",         symbol: "sunset.fill",         swatch: (0.75, 0.36, 0.36)),
        TimeSlot(id: "evening",     title: "Night",        symbol: "sparkles",            swatch: (0.29, 0.29, 0.49)),
    ]

    static let simpleTimeSlots: [TimeSlot] = [
        TimeSlot(id: "morning",   title: "Morning",   symbol: "cloud.sun.fill", swatch: (0.49, 0.80, 0.94)),
        TimeSlot(id: "afternoon", title: "Afternoon", symbol: "sun.haze.fill",  swatch: (0.29, 0.57, 0.85)),
        TimeSlot(id: "evening",   title: "Night",     symbol: "sparkles",       swatch: (0.29, 0.29, 0.49)),
    ]

    @Published var slotEnabled: [String: Bool] = [:] {
        didSet { persistIfReady() }
    }
    @Published var wallpapersPerDay: Double = 8 {
        didSet {
            AnalyticsManager.shared.log(.settingsChanged, metadata: ["setting": "wallpapers_per_day", "value": String(wallpapersPerDay)])
            persistIfReady()
        }
    }

    private var isBootstrapping = true

    init() {
        loadFromDefaults()
        isBootstrapping = false
        persistIfReady()
    }

    func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { self.slotEnabled[id] ?? true },
            set: { self.slotEnabled[id] = $0 }
        )
    }

    private func persistIfReady() {
        guard !isBootstrapping else { return }

        let defaults = UserDefaults.standard
        let cappedValue = min(max(wallpapersPerDay, 1), 48)
        defaults.set(cappedValue, forKey: HorizonScheduleDefaults.wallpapersPerDayKey)

        do {
            let data = try JSONEncoder().encode(slotEnabled)
            defaults.set(data, forKey: HorizonScheduleDefaults.slotEnabledKey)
        } catch {
            print("[HorizonSettingsView] Failed to encode slotEnabled: \(error)")
        }
    }

    private func loadFromDefaults() {
        let defaults = UserDefaults.standard

        let storedFrequency = defaults.double(forKey: HorizonScheduleDefaults.wallpapersPerDayKey)
        wallpapersPerDay = storedFrequency == 0 ? 8 : min(max(storedFrequency, 1), 48)

        var enabledMap = HorizonScheduleDefaults.orderedSlotIDs.reduce(into: [String: Bool]()) {
            $0[$1] = true
        }

        if let data = defaults.data(forKey: HorizonScheduleDefaults.slotEnabledKey) {
            do {
                let decoded = try JSONDecoder().decode([String: Bool].self, from: data)
                for slotID in HorizonScheduleDefaults.orderedSlotIDs {
                    if let value = decoded[slotID] {
                        enabledMap[slotID] = value
                    }
                }
            } catch {
                print("[HorizonSettingsView] Failed to decode slotEnabled: \(error)")
            }
        }

        slotEnabled = enabledMap
    }
}

// MARK: - Sidebar

enum HorizonSettingsSection: String, CaseIterable, Identifiable {
    case dashboard, schedule, library, moods, focusMode, multiDisplay, appSettings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard:    return "Dashboard"
        case .schedule:     return "Schedule"
        case .library:      return "Library"
        case .moods:        return "Moods"
        case .focusMode:    return "Focus Mode"
        case .multiDisplay: return "Multi-Display"
        case .appSettings:  return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .dashboard:    return "square.grid.2x2.fill"
        case .schedule:     return "calendar.day.timeline.left"
        case .library:      return "photo.on.rectangle.angled"
        case .moods:        return "paintpalette.fill"
        case .focusMode:    return "person.fill.viewfinder"
        case .multiDisplay: return "rectangle.split.2x1"
        case .appSettings:  return "gearshape.fill"
        }
    }
    var colors: [Color] {
        switch self {
        case .dashboard:    return [Color.blue, Color.cyan]
        case .schedule:     return [Color.purple, Color.pink]
        case .library:      return [Color.orange, Color.yellow]
        case .moods:        return [Color.pink, Color.purple]
        case .focusMode:    return [Color.blue, Color.teal]
        case .multiDisplay: return [Color.green, Color.mint]
        case .appSettings:  return [Color.primary, Color.secondary]
        }
    }
}

// MARK: - Window transparency bridge

/// Wraps NSVisualEffectView to give the window true behind-window vibrancy:
/// the desktop blurs through the entire window the way Finder, Mail, Notes,
/// and System Settings do. SwiftUI's `.regularMaterial` only blurs content
/// *within* the window, which on a transparent window shows an unblurred
/// desktop. `.behindWindow` is what makes the look feel native.
private struct VibrantBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

private struct WindowTransparencyBridge: NSViewRepresentable {
    static let minimumSize = NSSize(width: 1168, height: 792)

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window)
            enforceMinimumSize(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            configure(window)
        }
    }

    private func configure(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.minSize = Self.minimumSize
    }

    /// `minSize` only blocks future shrinking. If the window restored from a
    /// saved frame smaller than the new minimum, it stays at the saved size
    /// until the user resizes it. This force-grows the window to the minimum
    /// once on first appearance so the layout is never below spec.
    private func enforceMinimumSize(_ window: NSWindow) {
        var frame = window.frame
        var changed = false
        if frame.width < Self.minimumSize.width {
            frame.size.width = Self.minimumSize.width
            changed = true
        }
        if frame.height < Self.minimumSize.height {
            frame.size.height = Self.minimumSize.height
            changed = true
        }
        if changed {
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

// MARK: - Root

struct HorizonSettingsRootView: View {
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    @StateObject private var scheduleSettings = HorizonScheduleSettings()
    @State private var selectedSection: HorizonSettingsSection? = .dashboard
    private let sidebarWidth: CGFloat = 220

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                HorizonSidebar(selectedSection: $selectedSection)
                    .environmentObject(wallpaperManager)
                    .frame(width: sidebarWidth)

                detailContent
                    .frame(width: max(0, proxy.size.width - sidebarWidth), height: proxy.size.height)
                    .clipped()
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(VibrantBackground(material: .popover).ignoresSafeArea())
        .frame(minWidth: 1168, minHeight: 792)
        .background(WindowTransparencyBridge())
        .onReceive(NotificationCenter.default.publisher(for: .navigateToMoods)) { _ in
            selectedSection = .moods
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToUserWallpapers)) { _ in
            selectedSection = .library
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selectedSection ?? .dashboard {
        case .dashboard:
            DashboardView()
                .environmentObject(wallpaperManager)
        case .schedule:
            ScheduleSettingsView()
                .environmentObject(scheduleSettings)
        case .library:
            LibraryView()
                .environmentObject(wallpaperManager)
        case .moods:
            MoodsView()
        case .focusMode:
            FocusModeSettingsView()
        case .multiDisplay:
            MultiDisplaySettingsView()
                .environmentObject(wallpaperManager)
        case .appSettings:
            AppSettingsView()
                .environmentObject(wallpaperManager)
        }
    }
}

// MARK: - Header

private struct SettingsHeaderBar: View {
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "sun.horizon.fill")
                    .font(.system(size: 28, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Moodpaper")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Your Photos, Your Moods")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            CurrentWallpaperPreview()
                .environmentObject(wallpaperManager)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.06)
        }
    }
}

private struct CurrentWallpaperPreview: View {
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    @AppStorage(HorizonScheduleDefaults.pauseRotationKey) private var pauseRotation: Bool = false
    @State private var showingUnpinAlert = false
    @State private var previewImage: NSImage?
    @State private var previewImageURL: URL?

    var body: some View {
        ZStack {
            Group {
                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(
                            colors: [
                                Color(nsColor: NSColor(red: 0.2, green: 0.22, blue: 0.35, alpha: 1)),
                                Color(nsColor: NSColor(red: 0.12, green: 0.12, blue: 0.18, alpha: 1)),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.25))
                    }
                }
            }
            .frame(width: 132, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Pin indicator overlay
            if pauseRotation {
                VStack {
                    HStack {
                        Button {
                            showingUnpinAlert = true
                        } label: {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(Circle().fill(Color.yellow.opacity(0.8)))
                                .padding(6)
                        }
                        .buttonStyle(.plain)
                        .help("Click to unpin")
                        .accessibilityLabel("Unpin current wallpaper")
                        Spacer()
                    }
                    Spacer()
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
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .onAppear { loadPreviewImage() }
        .onChange(of: wallpaperManager.currentWallpaperName) { _, _ in loadPreviewImage() }
    }

    private func loadPreviewImage() {
        guard let url = wallpaperManager.currentWallpaperURL() else {
            previewImage = nil
            previewImageURL = nil
            return
        }
        previewImageURL = url
        WallpaperPreviewLoader.shared.loadImage(from: url, maxPixelSize: 400) { image in
            guard previewImageURL == url else { return }
            previewImage = image
        }
    }
}

// MARK: - Schedule

struct ScheduleSettingsView: View {
    @EnvironmentObject private var scheduleSettings: HorizonScheduleSettings
    @AppStorage(HorizonScheduleDefaults.timeSlotModeKey) private var timeSlotMode = "Detailed"
    @StateObject private var userWallpaperManager = UserWallpaperManager.shared

    private var activeSlots: [HorizonScheduleSettings.TimeSlot] {
        timeSlotMode == "Simple" ? HorizonScheduleSettings.simpleTimeSlots : HorizonScheduleSettings.timeSlots
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Schedule", systemImage: "calendar.day.timeline.left")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Enable Time Slots and Control How Often Wallpapers Change.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(Array(activeSlots.enumerated()), id: \.element.id) { index, slot in
                        ScheduleSlotRow(slot: slot, enabled: scheduleSettings.binding(for: slot.id))
                        if index < activeSlots.count - 1 {
                            Divider().opacity(0.35).padding(.leading, 52)
                        }
                    }
                }
                .padding(.vertical, 4)
                .liquidGlassCard()

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Wallpapers per day", systemImage: "square.stack.3d.up.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("\(Int(scheduleSettings.wallpapersPerDay))")
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    Slider(value: $scheduleSettings.wallpapersPerDay, in: 1...48, step: 1) {
                        Text("Frequency")
                    } minimumValueLabel: {
                        Text("1").font(.caption).foregroundStyle(.tertiary)
                    } maximumValueLabel: {
                        Text("48").font(.caption).foregroundStyle(.tertiary)
                    }
                    .tint(.orange)
                }
                .padding(16)
                .liquidGlassCard(elevated: true)

                PauseRotationCard()

            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Pause Rotation Card

private struct PauseRotationCard: View {
    @AppStorage(HorizonScheduleDefaults.pauseRotationKey) private var pauseRotation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: pauseRotation ? "pause.circle.fill" : "pause.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pauseRotation ? Color.yellow : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pause Rotation")
                        .font(.system(size: 13, weight: .semibold))
                    if pauseRotation {
                        Text("PAUSED")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.yellow.opacity(0.15)))
                    }
                }
                Spacer()
                Toggle("", isOn: $pauseRotation)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.yellow)
                    .accessibilityLabel("Pause Rotation")
            }
            Text("Stops automatic wallpaper changes. The current wallpaper stays until you turn this off or set a new one.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .liquidGlassCard()
        .overlay {
            if pauseRotation {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.yellow.opacity(0.6), lineWidth: 1.5)
            }
        }
    }
}

private struct ScheduleSlotRow: View {
    let slot: HorizonScheduleSettings.TimeSlot
    @Binding var enabled: Bool
    @State private var isHovered = false
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: slot.swatch.red, green: slot.swatch.green, blue: slot.swatch.blue))
                .frame(width: 32, height: 32)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
            Image(systemName: slot.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(slot.title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Toggle("", isOn: $enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("\(slot.title) time slot")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .opacity(enabled ? 1 : 0.55)
        .liquidGlassHoverRow(
            isHovered: isHovered,
            glowColor: HorizonColors.colorForSlot(slot.id)
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Multi Display

struct MultiDisplaySettingsView: View {
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    @AppStorage(HorizonScheduleDefaults.syncAllSpacesKey) private var showSpacesCards: Bool = HorizonScheduleDefaults.syncAllSpacesDefault

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                // Page header
                VStack(alignment: .leading, spacing: 6) {
                    Label("Multi-Display", systemImage: "rectangle.split.2x1")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Control How Moodpaper Behaves Across Your Connected Displays.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                // Connected displays list
                VStack(spacing: 0) {
                    ForEach(Array(wallpaperManager.connectedScreenNames().enumerated()), id: \.element) { index, name in
                        DisplayRow(screenName: name)
                            .environmentObject(wallpaperManager)
                        if index < wallpaperManager.connectedScreenNames().count - 1 {
                            Divider().opacity(0.35).padding(.leading, 52)
                        }
                    }
                }
                .padding(.vertical, 4)
                .liquidGlassCard()

                // Sync transition timing toggle
                SyncTransitionTimingCard()

                // Sync to all Spaces toggle
                AllSpacesSyncCard(onToggle: { enabled in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSpacesCards = enabled
                    }
                })

                // Space pinning, only shown when Spaces sync is on
                if showSpacesCards {
                    SpacePinningCard()
                        .environmentObject(wallpaperManager)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SyncTransitionTimingCard: View {
    @AppStorage("schedule.syncTransitionTiming") private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("Sync Transition Timing")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Sync Transition Timing")
            }
            Text("All displays change wallpaper at the same moment, even when running in Independent mode.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .liquidGlassCard()
    }
}

private struct AllSpacesSyncCard: View {
    @AppStorage(HorizonScheduleDefaults.syncAllSpacesKey) private var enabled: Bool = HorizonScheduleDefaults.syncAllSpacesDefault
    var onToggle: ((Bool) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("Sync to all Spaces")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Sync to all Spaces")
                    .onChange(of: enabled) { _, newValue in
                        WallpaperManager.shared.syncAllSpaces = newValue
                        onToggle?(newValue)
                    }
            }
            Text("Re-applies the current wallpaper each time you switch Spaces. macOS sets wallpaper per-Space, so Moodpaper must apply it fresh on every visit.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .liquidGlassCard()
    }
}

private struct SpacePinningCard: View {
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    private let slots = HorizonScheduleDefaults.orderedSlotIDs
    private let spaceKeys = (1...6).map { "\($0)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .accessibilityHidden(true)
                Text("Per-Space Wallpaper Style")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            Text("Each Space can follow the time-of-day schedule or always use a specific wallpaper style.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 0) {
                ForEach(Array(spaceKeys.enumerated()), id: \.element) { index, key in
                    SpacePinRow(spaceKey: key, spaceLabel: "Space \(key)", slots: slots)
                        .environmentObject(wallpaperManager)
                    if index < spaceKeys.count - 1 {
                        Divider().opacity(0.35).padding(.leading, 46)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(16)
        .liquidGlassCard()
    }
}

private struct SpacePinRow: View {
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    let spaceKey: String
    let spaceLabel: String
    let slots: [String]

    private var slotOptions: [(id: String, title: String)] {
        [("", "Follow schedule")] + slots.map { id in
            let title = HorizonScheduleSettings.timeSlots.first(where: { $0.id == id })?.title ?? id
            return (id: id, title: title)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            Text(spaceLabel)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Picker("", selection: Binding(
                get: { wallpaperManager.pinnedSlot(forSpace: spaceKey) ?? "" },
                set: { newVal in
                    wallpaperManager.setPinForSpace(spaceKey, slotID: newVal.isEmpty ? nil : newVal)
                    wallpaperManager.coveredSpaceIDs.removeAll()
                }
            )) {
                ForEach(slotOptions, id: \.id) { option in
                    Text(option.title).tag(option.id)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 150)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct SpaceCoverageCard: View {
    @EnvironmentObject private var wallpaperManager: WallpaperManager

    var covered: Int { wallpaperManager.coveredSpaceIDs.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.rectangle.stack.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [.green, .mint], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                Text("Space Activity")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(covered) switch\(covered == 1 ? "" : "es")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(covered > 0 ? Color.green : Color.secondary)
            }
            Text(covered == 0
                 ? "No Space switches yet this session. Moodpaper will sync the wallpaper automatically each time you switch Spaces."
                 : "Moodpaper has applied the wallpaper across \(covered) Space switch\(covered == 1 ? "" : "es") this session.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if covered > 0 {
                Button("Reset Count") {
                    wallpaperManager.coveredSpaceIDs.removeAll()
                }
                .font(.system(size: 12))
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .liquidGlassCard()
    }
}

private struct DisplayRow: View {
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    let screenName: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color.blue.opacity(0.25), Color.cyan.opacity(0.15)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 32, height: 32)
                Image(systemName: "display")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(screenName)
                    .font(.system(size: 13, weight: .medium))
                Text(wallpaperManager.mode(for: screenName).subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { wallpaperManager.mode(for: screenName) },
                set: { wallpaperManager.setMode($0, for: screenName) }
            )) {
                ForEach(DisplayMode.availableCases(), id: \.self) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 160)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .liquidGlassHoverRow(isHovered: isHovered, glowColor: .blue)
        .onHover { isHovered = $0 }
    }
}

// MARK: - App Settings

struct AppSettingsView: View {
    @EnvironmentObject private var runtimeState: AppRuntimeState
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    @StateObject private var locationService = LocationService.shared
    @State private var launchAtLogin = false
    @AppStorage("showMenuBarIcon")       private var showMenuBarIcon = true
    @AppStorage("respectDoNotDisturb")   private var respectDoNotDisturb = true
    @AppStorage(HorizonScheduleDefaults.notifyOnSlotChangeKey) private var notifyOnSlotChange = false
    @AppStorage("shortcutsEnabled")      private var shortcutsEnabled = false
    @AppStorage("useDeviceLocation")     private var useDeviceLocation = true
    @AppStorage("temperatureUnit")       private var temperatureUnit = "Fahrenheit"
    @AppStorage("windSpeedUnit")         private var windSpeedUnit = "mph"
    @AppStorage(HorizonScheduleDefaults.timeSlotModeKey) private var timeSlotMode = "Detailed"

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(version) (\(build))"
    }

    private var shortcutSubtitle: String {
        if shortcutsEnabled && !runtimeState.shortcutsAuthorized {
            return "Enabled in settings, but Accessibility access is still required."
        }
        return "Enable global shortcuts. Requires Accessibility access."
    }

    private var notificationSubtitle: String {
        if notifyOnSlotChange && !runtimeState.notificationsAuthorized {
            return "Enabled in settings, but notification access is still required."
        }
        if !notifyOnSlotChange && !runtimeState.notificationsAuthorized {
            return "Show a notification when entering a new time of day. Requires notification access."
        }
        return "Show a notification when entering a new time of day"
    }

    private var locationSubtitle: String {
        if !useDeviceLocation {
            return "Using approximate daylight timing until device location is turned back on"
        }
        if !runtimeState.locationAuthorized {
            return "Location access is unavailable. Moodpaper is using approximate daylight timing"
        }
        return locationService.currentLocation != nil ? locationService.locationName : "Updating current location"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {

                VStack(alignment: .leading, spacing: 6) {
                    Label("Settings", systemImage: "gearshape.fill")
                        .font(.system(size: 22, weight: .semibold))
                    Text("General Preferences, Permissions, and Display Options.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                // MARK: General
                SettingsGroup(title: "General") {
                    SettingsToggleRow(
                        title: "Launch at Login",
                        subtitle: "Start Moodpaper Automatically When You Log In",
                        symbol: "power",
                        isOn: $launchAtLogin
                    )
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else        { try SMAppService.mainApp.unregister() }
                        } catch {
                            print("Horizon: Launch at login error: \(error.localizedDescription)")
                        }
                    }

                    Divider().opacity(0.35).padding(.leading, 52)

                    SettingsToggleRow(
                        title: "Respect Do Not Disturb",
                        subtitle: "Unavailable in this release. Focus Mode can still pause during meetings.",
                        symbol: "moon.fill",
                        isOn: .constant(false),
                        isEnabled: false
                    )

                    Divider().opacity(0.35).padding(.leading, 52)

                    SettingsToggleRow(
                        title: "Notify On Time Slot Change",
                        subtitle: notificationSubtitle,
                        symbol: "bell.fill",
                        isOn: $notifyOnSlotChange
                    )
                    .onChange(of: notifyOnSlotChange) { _, enabled in
                        Task { @MainActor in
                            let allowed = await NotificationPermissionManager.shared.reconcile(enabledPreference: enabled)
                            if enabled && !allowed {
                                notifyOnSlotChange = false
                            }
                            await runtimeState.refresh(reason: "notificationPreferenceChanged")
                        }
                    }

                    Divider().opacity(0.35).padding(.leading, 52)

                    SettingsToggleRow(
                        title: "Keyboard Shortcuts",
                        subtitle: shortcutSubtitle,
                        symbol: "command",
                        isOn: $shortcutsEnabled
                    )
                    .onChange(of: shortcutsEnabled) { _, enabled in
                        Task { @MainActor in
                            if enabled {
                                if !GlobalShortcutManager.shared.start() {
                                    shortcutsEnabled = false
                                }
                            } else {
                                GlobalShortcutManager.shared.stop()
                            }
                        }
                    }

                    Divider().opacity(0.35).padding(.leading, 52)

                    HStack(spacing: 14) {
                        SettingsIconBox(symbol: "clock.fill", color: .purple, gradient: [.purple, .indigo])
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Time Slot Mode")
                                .font(.system(size: 13, weight: .medium))
                            Text(timeSlotMode == "Detailed" ? "9 Slots: Deep Night through Night" : "3 Slots: Morning, Afternoon, Night")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $timeSlotMode) {
                            Text("Detailed").tag("Detailed")
                            Text("Simple").tag("Simple")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                        .onChange(of: timeSlotMode) { _, _ in
                            WallpaperManager.shared.resetSlotAndRecheck()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider().opacity(0.35).padding(.leading, 52)

                    NightStartRow()
                }

                // MARK: Location and Time
                SettingsGroup(title: "Location and Time") {
                    HStack(spacing: 14) {
                        SettingsIconBox(symbol: "location.fill", color: .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use Device Location")
                                .font(.system(size: 13, weight: .medium))
                            Text("Improves sunrise, sunset, and local weather accuracy")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $useDeviceLocation)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .accessibilityLabel("Use Device Location")
                            .onChange(of: useDeviceLocation) { _, newValue in
                                if newValue { locationService.startUpdatingLocation(requestPermissionIfNeeded: true) }
                                else        { locationService.disableLocationUsage() }
                            }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider().opacity(0.35).padding(.leading, 52)

                    HStack(spacing: 14) {
                        SettingsIconBox(symbol: "mappin.circle.fill", color: .red, gradient: [.red, .pink])
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Location")
                                .font(.system(size: 13, weight: .medium))
                            Text(locationSubtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button("Refresh") { locationService.refreshLocation(requestPermissionIfNeeded: true) }
                            .font(.system(size: 12))
                            .buttonStyle(.bordered)
                            .disabled(!useDeviceLocation)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider().opacity(0.35).padding(.leading, 52)

                    HStack(spacing: 14) {
                        SettingsIconBox(symbol: "sunrise.fill", color: .orange, gradient: [.orange, .yellow])
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sunrise and Sunset")
                                .font(.system(size: 13, weight: .medium))
                            Text("Used to align time-based wallpaper changes with your day")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let sunrise = locationService.formattedSunriseTime,
                           let sunset  = locationService.formattedSunsetTime {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(sunrise).font(.system(size: 12, weight: .medium))
                                Text(sunset).font(.system(size: 12, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            Text("Waiting for location or using fallback").font(.system(size: 12)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                // MARK: Weather Units
                SettingsGroup(title: "Weather Units") {
                    HStack(spacing: 14) {
                        SettingsIconBox(symbol: "thermometer.medium", color: .red, gradient: [.red, .orange])
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Temperature")
                                .font(.system(size: 13, weight: .medium))
                            Text("Choose Fahrenheit or Celsius")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $temperatureUnit) {
                            Text("°F").tag("Fahrenheit")
                            Text("°C").tag("Celsius")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider().opacity(0.35).padding(.leading, 52)

                    HStack(spacing: 14) {
                        SettingsIconBox(symbol: "wind", color: .blue, gradient: [.blue, .cyan])
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wind Speed")
                                .font(.system(size: 13, weight: .medium))
                            Text("Choose Miles per Hour or Kilometers per Hour")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("", selection: $windSpeedUnit) {
                            Text("mph").tag("mph")
                            Text("km/h").tag("km/h")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }

                // MARK: About
                SettingsGroup(title: "About") {
                    HStack(spacing: 14) {
                        SettingsIconBox(symbol: "sun.horizon.fill", color: .orange, gradient: [.orange, .yellow])
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Moodpaper: Your Photos, Your Moods")
                                .font(.system(size: 13, weight: .medium))
                            Text(appVersion)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider().opacity(0.35).padding(.leading, 52)

                    HStack(spacing: 14) {
                        SettingsIconBox(symbol: "cup.and.saucer.fill", color: .brown, gradient: [.brown, .orange])
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Support Moodpaper")
                                .font(.system(size: 13, weight: .medium))
                            Text("Moodpaper is free. If it's useful, buy me a coffee.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Buy Me a Coffee") {
                            NSWorkspace.shared.open(MoodpaperSupportLinks.buyMeACoffee)
                        }
                        .font(.system(size: 12))
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Buy me a coffee, opens in your browser")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Shared Settings Components

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
            VStack(spacing: 0) {
                content
            }
            .liquidGlassCard()
        }
    }
}

private struct NightStartRow: View {
    @AppStorage(HorizonScheduleDefaults.nightStartKey) private var nightStartRaw: String = HorizonScheduleDefaults.NightStart.oneHourAfter.rawValue
    @State private var isHovered = false

    private var subtitle: String {
        switch HorizonScheduleDefaults.NightStart(rawValue: nightStartRaw) ?? .oneHourAfter {
        case .atSunset:      return "Skips Dusk, jumps straight to Night at sunset"
        case .oneHourAfter:  return "Default. Dusk runs the hour after sunset"
        case .twoHoursAfter: return "Longer Dusk, later Night"
        case .tenPM:         return "Fixed: Night always starts at 10 PM"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            SettingsIconBox(symbol: "moon.stars.fill", color: .indigo, gradient: [.indigo, .blue])
            VStack(alignment: .leading, spacing: 2) {
                Text("Night Starts")
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $nightStartRaw) {
                ForEach(HorizonScheduleDefaults.NightStart.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)
            .onChange(of: nightStartRaw) { _, _ in
                WallpaperManager.shared.resetSlotAndRecheck()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .liquidGlassHoverRow(isHovered: isHovered, glowColor: .indigo)
        .onHover { isHovered = $0 }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    @Binding var isOn: Bool
    var isEnabled = true
    @State private var isHovered = false
    var body: some View {
        HStack(spacing: 14) {
            SettingsIconBox(symbol: symbol, color: .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!isEnabled)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .liquidGlassHoverRow(isHovered: isHovered, glowColor: .orange)
        .onHover { isHovered = $0 }
        .opacity(isEnabled ? 1 : 0.6)
    }
}

private struct SettingsIconBox: View {
    let symbol: String
    let color: Color
    var gradient: [Color]?

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                gradient != nil ?
                    AnyShapeStyle(LinearGradient(
                        colors: gradient?.map { $0.opacity(0.15) } ?? [],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )) :
                    AnyShapeStyle(color.opacity(0.2))
            )
            .frame(width: 32, height: 32)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        gradient != nil ?
                            AnyShapeStyle(LinearGradient(
                                colors: gradient ?? [],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )) :
                            AnyShapeStyle(color)
                    )
            )
    }
}

// MARK: - Placeholder

private struct SettingsPlaceholderView: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Conditional glass modifier

private struct ConditionalGlass: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            if #available(macOS 26.0, *), !HorizonRuntimeStyle.forceLegacyGlass {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(.white.opacity(0.16), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
            }
        } else {
            content
        }
    }
}

// MARK: - Colorful Sidebar Label

// MARK: - Custom Apple-Style Sidebar

private struct HorizonSidebar: View {
    private enum BrandStyle {
        case native
        case premium
    }

    private let brandStyle: BrandStyle = .premium

    @Binding var selectedSection: HorizonSettingsSection?
    @EnvironmentObject var wallpaperManager: WallpaperManager
    private let titlebarInset: CGFloat = 54

    var body: some View {
        VStack(spacing: 0) {
            // Branding: sits at top of sidebar, unified with the column
            brandHeader
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, titlebarInset)
            .padding(.bottom, 14)

            // Nav items
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    SidebarItem(section: .dashboard, selected: $selectedSection)

                    SidebarSectionHeader("Wallpapers", color: .orange)
                    SidebarItem(section: .schedule,  selected: $selectedSection)
                    SidebarItem(section: .library,   selected: $selectedSection)

                    SidebarSectionHeader("Features", color: .purple)
                    SidebarItem(section: .moods,        selected: $selectedSection)
                    SidebarItem(section: .multiDisplay, selected: $selectedSection)
                    SidebarItem(section: .focusMode,    selected: $selectedSection)

                    SidebarSectionHeader("Account", color: .teal)
                    SidebarItem(section: .appSettings,  selected: $selectedSection)

                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)

            // Current wallpaper preview
            SidebarWallpaperPreview()
                .environmentObject(wallpaperManager)

            // Active indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Moodpaper is active")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background {
            VibrantBackground(material: .sidebar)
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: 12,
                        bottomTrailingRadius: 12,
                        topTrailingRadius: 12,
                        style: .continuous
                    )
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.24),
                                .white.opacity(0.04)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                )
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 12,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 12,
                topTrailingRadius: 12,
                style: .continuous
            )
        )
        .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 2)
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private var brandHeader: some View {
        switch brandStyle {
        case .native:
            HStack(spacing: 9) {
                Image(systemName: "sun.horizon.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)

                Text("Moodpaper")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HorizonColors.textPrimary)
            }
        case .premium:
            HStack(spacing: 10) {
                Image(systemName: "sun.horizon.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        Color(red: 0.98, green: 0.75, blue: 0.37),
                        Color(red: 0.86, green: 0.48, blue: 0.22)
                    )

                Text("Moodpaper")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(0.1)
                    .foregroundStyle(HorizonColors.textPrimary)
            }
        }
    }
}

private struct SidebarWallpaperPreview: View {
    @EnvironmentObject var wallpaperManager: WallpaperManager
    @State private var hostingScreen: NSScreen?

    var body: some View {
        // Fixed-size container with the image as an overlay. Separates sizing
        // from image rendering so cards stay identical regardless of source
        // aspect ratio. Same pattern as LibraryView.WallpaperCard
        // (see tasks/lessons.md 2026-05-02).
        //
        // Reads the shared WallpaperManager.currentPreviewImage so this card
        // and the dashboard's CurrentWallpaperCard always render the same
        // image. Previously each had its own @State previewImage with
        // different refresh triggers, which let the two surfaces drift.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .overlay {
                if let previewImage = wallpaperManager.currentPreviewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay(
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 18))
                                .foregroundStyle(.tertiary)
                        )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            )
            .background(
                WindowScreenObserver(screen: $hostingScreen)
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .onAppear { wallpaperManager.refreshCurrentPreview(preferredScreen: hostingScreen) }
            .onChange(of: hostingScreen?.localizedName) { _, _ in
                wallpaperManager.refreshCurrentPreview(preferredScreen: hostingScreen)
            }
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    let color: Color

    init(_ title: String, color: Color = .secondary) {
        self.title = title
        self.color = color
    }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color.opacity(0.8))
            .kerning(0.5)
            .padding(.horizontal, 10)
            .padding(.top, 20)
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SidebarItem: View {
    let section: HorizonSettingsSection
    @Binding var selected: HorizonSettingsSection?
    @State private var isHovered = false

    private var isSelected: Bool { selected == section }
    private var glowColor: Color { section.colors.first ?? .accentColor }
    private var iconGradient: LinearGradient {
        LinearGradient(colors: section.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        Button {
            selected = section
        } label: {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(
                        isSelected
                            ? AnyShapeStyle(glowColor.opacity(0.85))
                            : AnyShapeStyle(Color.secondary)
                    )
                    .frame(width: 18, alignment: .center)

                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(glowColor.opacity(0.08))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(LiquidGlassTokens.strokeFocus, lineWidth: 0.75)
                        }
                        .shadow(color: glowColor.opacity(0.25), radius: 8, y: 2)
                        .shadow(color: LiquidGlassTokens.shadow1, radius: 3, y: 1)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(LiquidGlassTokens.strokeSubtle, lineWidth: 0.5)
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
    }
}

// MARK: - Focus Mode Settings

struct FocusModeSettingsView: View {
    @EnvironmentObject private var runtimeState: AppRuntimeState
    @StateObject private var calendarService = CalendarService.shared
    @AppStorage(HorizonScheduleDefaults.timeSlotModeKey) private var timeSlotMode = "Detailed"
    @State private var focusEnabled: Bool = WallpaperManager.shared.focusModePreference
    @State private var focusSlot: String = WallpaperManager.shared.focusSlot
    @State private var showingFocusFilePicker = false
    @State private var focusSlotWasAdjusted = false

    private var focusSlotIDs: [String] {
        let enabledSlots = HorizonScheduleDefaults.enabledSlotIDs(mode: timeSlotMode)
        let modeSlots = HorizonScheduleDefaults.slotIDs(for: timeSlotMode)
        return enabledSlots.isEmpty ? modeSlots : enabledSlots
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HorizonSpacing.xl) {

                // Header
                VStack(alignment: .leading, spacing: HorizonSpacing.sm) {
                    Text("Focus Mode")
                        .font(HorizonTypography.title2)
                        .foregroundColor(HorizonColors.textPrimary)
                    Text(runtimeState.calendarAuthorized
                         ? "Automatically switch wallpapers when you're in a calendar meeting."
                         : "Calendar access is required before Focus Mode can react to meetings.")
                        .font(HorizonTypography.callout)
                        .foregroundColor(HorizonColors.textSecondary)
                }

                    // Calendar Access
                    FocusCalendarAccessCard(calendarService: calendarService)

                    // Denied/restricted warning — shown instead of the toggle
                    if calendarService.authorizationStatus == .denied || calendarService.authorizationStatus == .restricted {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.system(size: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Calendar Access Denied")
                                    .font(HorizonTypography.headline)
                                    .foregroundColor(HorizonColors.textPrimary)
                                Text("Open System Settings > Privacy & Security > Calendars and enable access for Moodpaper.")
                                    .font(HorizonTypography.caption)
                                    .foregroundColor(HorizonColors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button("Open Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .font(.system(size: 12))
                            .buttonStyle(.bordered)
                        }
                        .padding(HorizonSpacing.lg)
                        .horizonGlassCard(style: .standard, padding: 0)
                        .padding(.horizontal, HorizonSpacing.lg)
                        .onAppear {
                            // Auto-disable the toggle so stored state matches reality
                            if focusEnabled {
                                focusEnabled = false
                                WallpaperManager.shared.setFocusModeEnabled(false, reason: "calendarAccessUnavailable")
                            }
                        }
                    }

                    // Toggle + Slot Picker (only when access granted)
                    if calendarService.authorizationStatus == .fullAccess {
                        // Enable toggle
                        VStack(alignment: .leading, spacing: HorizonSpacing.md) {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Auto Focus Mode")
                                        .font(HorizonTypography.headline)
                                        .foregroundColor(HorizonColors.textPrimary)
                                    Text("Switch to your focus wallpaper during meetings")
                                        .font(HorizonTypography.callout)
                                        .foregroundColor(HorizonColors.textSecondary)
                                }
                                Spacer()
                                Toggle("", isOn: $focusEnabled)
                                    .toggleStyle(.switch)
                                    .labelsHidden()
                                    .accessibilityLabel("Auto Focus Mode")
                            }
                        }
                        .horizonGlassCard(style: .standard, padding: HorizonSpacing.lg)

                        // Wallpaper slot picker
                        if focusEnabled {
                            VStack(alignment: .leading, spacing: HorizonSpacing.md) {
                                Text("Focus Wallpaper Style")
                                    .font(HorizonTypography.headline)
                                    .foregroundColor(HorizonColors.textPrimary)
                                Text("Choose which time slot's wallpapers to use during meetings")
                                    .font(HorizonTypography.callout)
                                    .foregroundColor(HorizonColors.textSecondary)

                                if focusSlotWasAdjusted {
                                    HStack(spacing: HorizonSpacing.sm) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.green)
                                        Text("Focus wallpaper style was updated to an enabled schedule slot.")
                                            .font(HorizonTypography.caption)
                                            .foregroundColor(HorizonColors.textSecondary)
                                    }
                                }

                                LazyVGrid(columns: [
                                    GridItem(.flexible()),
                                    GridItem(.flexible()),
                                    GridItem(.flexible())
                                ], spacing: HorizonSpacing.sm) {
                                    ForEach(focusSlotIDs, id: \.self) { slotID in
                                        FocusSlotButton(
                                            slotID: slotID,
                                            isSelected: focusSlot == slotID,
                                            action: {
                                                focusSlot = slotID
                                                // The setter writes the same UserDefaults key; no need for a raw write here.
                                                WallpaperManager.shared.focusSlot = slotID
                                                if WallpaperManager.shared.focusModeEnabled {
                                                    WallpaperManager.shared.resetSlotAndRecheck()
                                                }
                                            }
                                        )
                                    }
                                }
                            }
                            .horizonGlassCard(style: .standard, padding: HorizonSpacing.lg)

                            // Custom wallpaper picker for premium users
                            VStack(alignment: .leading, spacing: HorizonSpacing.md) {
                                HStack(spacing: HorizonSpacing.sm) {
                                    HorizonIconContainer(
                                        icon: "photo.on.rectangle.angled",
                                        color: HorizonColors.primaryAccent,
                                        size: 36
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Your Focus Wallpapers")
                                            .font(HorizonTypography.headline)
                                            .foregroundColor(HorizonColors.textPrimary)
                                        Text("Choose your focus wallpapers from your collection")
                                            .font(HorizonTypography.callout)
                                            .foregroundColor(HorizonColors.textSecondary)
                                    }

                                    Spacer()

                                    Button(action: { showingFocusFilePicker = true }) {
                                        HStack(spacing: HorizonSpacing.sm) {
                                            Image(systemName: "folder.fill.badge.plus")
                                                .font(.system(size: 14, weight: .semibold))
                                            Text("Browse")
                                                .font(HorizonTypography.bodyMedium)
                                        }
                                        .foregroundColor(.white)
                                        .padding(.horizontal, HorizonSpacing.md)
                                        .padding(.vertical, HorizonSpacing.sm)
                                        .background(
                                            RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                                                .fill(Color.blue.gradient)
                                        )
                                        .shadow(color: Color.blue.opacity(0.3), radius: 8, y: 4)
                                    }
                                    .buttonStyle(.plain)
                                }

                                FocusWallpaperPicker(
                                    onWallpaperSelected: { url in
                                        // Set the selected wallpaper as the current focus wallpaper
                                        WallpaperManager.shared.setWallpaperManually(url: url)
                                    },
                                    showingFilePicker: $showingFocusFilePicker
                                )
                            }
                            .horizonGlassCard(style: .standard, padding: HorizonSpacing.lg)
                        }

                        // Live status
                        FocusStatusCard(calendarService: calendarService, focusEnabled: $focusEnabled)
                    }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            focusEnabled = WallpaperManager.shared.focusModePreference
            focusSlot = WallpaperManager.shared.focusSlot
            validateFocusSlot()
            WallpaperManager.shared.setFocusModeEnabled(focusEnabled, reason: "focusSettingsAppear")
        }
        .onChange(of: timeSlotMode) { _, _ in
            validateFocusSlot()
        }
        .onChange(of: focusEnabled) { _, newValue in
            validateFocusSlot()
            applyFocusModePreference(newValue)
        }
    }

    private func validateFocusSlot() {
        let validated = HorizonScheduleDefaults.validatedFocusSlot(
            preferred: focusSlot,
            mode: timeSlotMode
        )
        guard validated != focusSlot else { return }
        focusSlot = validated
        WallpaperManager.shared.focusSlot = validated
        focusSlotWasAdjusted = true
    }

    private func applyFocusModePreference(_ enabled: Bool) {
        AnalyticsManager.shared.log(.focusModeToggled, metadata: ["enabled": String(enabled)])
        if enabled {
            WallpaperManager.shared.focusSlot = focusSlot
        }
        WallpaperManager.shared.setFocusModeEnabled(enabled, reason: "focusSettingsToggle")
    }
}

// MARK: - Focus Sub-views

private struct FocusCalendarAccessCard: View {
    @ObservedObject var calendarService: CalendarService

    var body: some View {
        HStack(spacing: HorizonSpacing.md) {
            Image(systemName: calendarService.authorizationStatus == .fullAccess ? "checkmark.circle.fill" : "calendar.badge.exclamationmark")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(calendarService.authorizationStatus == .fullAccess
                    ? Color.green.gradient
                    : HorizonColors.secondaryAccent.gradient)

            VStack(alignment: .leading, spacing: 4) {
                Text("Calendar Access")
                    .font(HorizonTypography.headline)
                    .foregroundColor(HorizonColors.textPrimary)
                Text(accessDetail)
                    .font(HorizonTypography.callout)
                    .foregroundColor(HorizonColors.textSecondary)
            }

            Spacer()

            if calendarService.authorizationStatus != .fullAccess {
                Button("Grant Access") {
                    Task {
                        await calendarService.requestAccess()
                        await MainActor.run {
                            WallpaperManager.shared.setFocusModeEnabled(
                                WallpaperManager.shared.focusModePreference,
                                reason: "calendarAccessRequested"
                            )
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(HorizonColors.secondaryAccent)
                .font(HorizonTypography.bodyMedium)
            }
        }
        .horizonGlassCard(style: .standard, padding: HorizonSpacing.lg)
    }

    private var accessDetail: String {
        switch calendarService.authorizationStatus {
        case .fullAccess:
            return "Granted. Moodpaper can read your calendar."
        case .writeOnly:
            return "Write-only access is not enough. Open System Settings > Privacy & Security > Calendars and give Moodpaper Full Access."
        default:
            return "Only used when Focus Mode is enabled to detect meetings"
        }
    }
}

private struct FocusSlotButton: View {
    let slotID: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var displayName: String {
        HorizonScheduleSettings.timeSlots.first(where: { $0.id == slotID })?.title ?? slotID
    }

    var slotColor: Color {
        HorizonColors.colorForSlot(slotID)
    }

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: HorizonSpacing.sm) {
                Circle()
                    .fill(slotColor.gradient)
                    .frame(width: 8, height: 8)
                Text(displayName)
                    .font(HorizonTypography.caption)
                    .foregroundColor(isSelected ? .white : HorizonColors.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HorizonSpacing.sm)
            .padding(.horizontal, HorizonSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                    .fill(isSelected
                        ? AnyShapeStyle(HorizonColors.secondaryAccent.gradient)
                        : (isHovered
                            ? AnyShapeStyle(LinearGradient(colors: [slotColor.opacity(0.15), slotColor.opacity(0.15)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(.ultraThinMaterial)))
                    .overlay {
                        if !isSelected {
                            RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                                .strokeBorder(isHovered
                                    ? LinearGradient(colors: [slotColor.opacity(0.5), slotColor.opacity(0.5)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                    : LinearGradient(colors: [HorizonColors.glassStroke, HorizonColors.glassStroke],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    lineWidth: isHovered ? 1.5 : 1)
                        }
                    }
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
    }
}

private struct FocusStatusCard: View {
    @ObservedObject var calendarService: CalendarService
    @Binding var focusEnabled: Bool

    var body: some View {
        HStack(spacing: HorizonSpacing.md) {
            HorizonIconContainer(
                icon: calendarService.isInMeeting ? "person.fill.viewfinder" : "pause.circle.fill",
                color: focusEnabled ? HorizonColors.primaryAccent : HorizonColors.textSecondary,
                size: 44
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: HorizonSpacing.xs) {
                    Text(focusEnabled ? "Focus Mode Active" : "Focus Mode Paused")
                        .font(HorizonTypography.bodyMedium)
                        .foregroundColor(HorizonColors.textPrimary)

                    if focusEnabled {
                        HorizonBadge(
                            text: calendarService.isInMeeting ? "In Meeting" : "Ready",
                            color: calendarService.isInMeeting ? HorizonColors.dawn : HorizonColors.afternoon,
                            size: .small
                        )
                    }
                }

                Text(calendarService.statusDescription)
                    .font(HorizonTypography.caption)
                    .foregroundColor(HorizonColors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: $focusEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Auto Focus Mode")
        }
        .horizonGlassCard(style: .standard, padding: HorizonSpacing.lg)
    }
}

// MARK: - Focus Wallpaper Picker

private struct FocusWallpaperPicker: View {
    let onWallpaperSelected: (URL) -> Void
    @Binding var showingFilePicker: Bool
    @StateObject private var userWallpaperManager = UserWallpaperManager.shared
    @State private var allWallpapers: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: HorizonSpacing.md) {
            if allWallpapers.isEmpty {
                Text("No wallpapers imported yet. Browse your computer to add wallpapers for Focus mode.")
                    .font(HorizonTypography.callout)
                    .foregroundColor(HorizonColors.textSecondary)
                    .padding(.vertical, HorizonSpacing.md)
            } else {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 120, maximum: 140), spacing: HorizonSpacing.md)
                ], spacing: HorizonSpacing.md) {
                    ForEach(allWallpapers, id: \.self) { url in
                        FocusWallpaperThumbnail(
                            url: url,
                            onSelect: {
                                onWallpaperSelected(url)
                            }
                        )
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                // Import to global pool for Focus mode
                do {
                    try userWallpaperManager.importToGlobalPool(urls)
                    loadWallpapers()
                } catch {
                    print("[FocusWallpaperPicker] Failed to import wallpapers: \(error)")
                }
            }
        }
        .onAppear {
            loadWallpapers()
        }
    }

    private func loadWallpapers() {
        var wallpapers: [URL] = []
        // Load from global pool
        wallpapers.append(contentsOf: userWallpaperManager.globalWallpapers())
        // Load from each slot
        for slot in TimeSlot.allCases {
            wallpapers.append(contentsOf: userWallpaperManager.wallpapers(for: slot))
        }
        // Remove duplicates
        allWallpapers = Array(Set(wallpapers))
    }
}

private struct FocusWallpaperThumbnail: View {
    let url: URL
    let onSelect: () -> Void
    @State private var image: NSImage?
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                if let image = image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 140, height: 100)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(HorizonColors.backgroundSecondary)
                        .frame(width: 140, height: 100)
                        .overlay {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                }

                // Hover overlay
                if isHovered {
                    Rectangle()
                        .fill(Color.black.opacity(0.3))
                        .overlay {
                            VStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.white)
                                Text("Select")
                                    .font(HorizonTypography.caption)
                                    .foregroundColor(.white)
                            }
                        }
                }
            }
        }
        .buttonStyle(.plain)
        .clipShape(RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                .strokeBorder(
                    isHovered ? HorizonColors.primaryAccent : HorizonColors.glassStroke,
                    lineWidth: isHovered ? 2 : 1
                )
        }
        .shadow(color: .black.opacity(isHovered ? 0.2 : 0.08), radius: isHovered ? 12 : 4, y: isHovered ? 6 : 2)
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
        .onHover { isHovered = $0 }
        .onAppear { loadImage() }
    }

    private func loadImage() {
        DispatchQueue.global(qos: .userInitiated).async {
            if let data = try? Data(contentsOf: url),
               let nsImage = NSImage(data: data) {
                DispatchQueue.main.async {
                    self.image = nsImage
                }
            }
        }
    }
}

struct HorizonSettingsRootView_Previews: PreviewProvider {
    static var previews: some View {
        HorizonSettingsRootView()
            .environmentObject(WallpaperManager.shared)
    }
}
