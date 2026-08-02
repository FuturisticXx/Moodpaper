import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

// The Library edits the active Vibe: All Day is its shared fallback pool, and
// each time-slot card can add an override. Switching Vibes swaps the complete
// assignment set these cards show.
struct UserLibraryView: View {
    var searchText: String = ""
    @ObservedObject private var store = MoodStore.shared
    @State private var selectedSlot: TimeSlot?
    @State private var showingFilePicker = false
    @State private var showingAllDayImporter = false
    @State private var importingToSlot: TimeSlot?
    @State private var isDroppingOnSlot: TimeSlot? = nil
    @AppStorage(HorizonScheduleDefaults.timeSlotModeKey) private var timeSlotMode = "Detailed"

    private var filteredSlots: [TimeSlot] {
        let isSimple = timeSlotMode == "Simple"
        let slots = isSimple ? HorizonScheduleDefaults.simpleSlotIDs : HorizonScheduleDefaults.orderedSlotIDs
        let timeSlots = TimeSlot.allCases.filter { slots.contains($0.slotID) }

        if searchText.isEmpty { return timeSlots }
        return timeSlots.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
    }

    private var isActiveMoodEmpty: Bool {
        guard let mood = store.activeMood else { return true }
        return store.totalWallpaperCount(in: mood) == 0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
            // Header
            HStack(spacing: HorizonSpacing.lg) {
                HStack(spacing: 10) {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(HorizonColors.secondaryAccent.gradient)
                    Text(store.activeMood.map { "Editing \"\($0.name)\"" } ?? "Your Wallpapers")
                        .font(HorizonTypography.title2)
                        .foregroundColor(HorizonColors.textPrimary)
                }

                Spacer()

                Text(store.activeMood == nil
                     ? "Create a Vibe to start adding wallpapers"
                     : "Start with All Day, then customize any time slot")
                    .font(HorizonTypography.callout)
                    .foregroundColor(HorizonColors.textSecondary)
            }
            .padding(.horizontal, HorizonSpacing.xxxl)
            .padding(.top, HorizonSpacing.xl)
            .padding(.bottom, HorizonSpacing.lg)

            if store.activeMood == nil {
                VStack(spacing: HorizonSpacing.md) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(HorizonColors.secondaryAccent.gradient)
                        .accessibilityHidden(true)
                    Text("Your wallpapers need a Vibe")
                        .font(HorizonTypography.title2)
                        .foregroundColor(HorizonColors.textPrimary)
                    Text("Give your desktop a feeling first. Then add a folder or choose photos one by one.")
                        .font(HorizonTypography.callout)
                        .foregroundColor(HorizonColors.textSecondary)
                        .multilineTextAlignment(.center)
                    Button {
                        NotificationCenter.default.post(name: .navigateToMoods, object: nil)
                    } label: {
                        Label("Create Your First Vibe", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HorizonColors.secondaryAccent)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
                .horizonGlassCard(style: .standard, padding: HorizonSpacing.xl)
                .padding(.horizontal, HorizonSpacing.xxxl)
                .padding(.bottom, HorizonSpacing.xxxl)
            } else if let mood = store.activeMood, isActiveMoodEmpty {
                HStack(spacing: HorizonSpacing.md) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(HorizonColors.secondaryAccent.gradient)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\"\(mood.name)\" is empty")
                            .font(HorizonTypography.headline)
                            .foregroundColor(HorizonColors.textPrimary)
                        Text("Start with one folder or a few photos in All Day. You can fine-tune time slots later.")
                            .font(HorizonTypography.callout)
                            .foregroundColor(HorizonColors.textSecondary)
                    }
                    Spacer()
                }
                .horizonGlassCard(style: .standard, padding: HorizonSpacing.lg)
                .padding(.horizontal, HorizonSpacing.xxxl)
                .padding(.bottom, HorizonSpacing.lg)
            }

            // Slot Cards — each edits the active mood's assignment for that slot
            if let mood = store.activeMood {
                VStack(spacing: HorizonSpacing.lg) {
                    AllDayWallpaperCard(
                        wallpaperCount: store.allDayWallpapers(in: mood).count,
                        onOpen: { showingAllDayImporter = true }
                    )

                    HStack {
                        Text("Time-Slot Favorites")
                            .font(HorizonTypography.headline)
                            .foregroundColor(HorizonColors.textPrimary)
                        Spacer()
                        Text("These override All Day")
                            .font(HorizonTypography.caption)
                            .foregroundColor(HorizonColors.textTertiary)
                    }

                    ForEach(filteredSlots, id: \.self) { slot in
                        TimeSlotCard(
                            slot: slot,
                            wallpaperCount: store.wallpaperCount(for: slot, in: mood),
                            usesAllDayFallback: store.wallpaperCount(for: slot, in: mood) == 0
                                && !store.allDayWallpapers(in: mood).isEmpty,
                            isDropTarget: isDroppingOnSlot == slot,
                            onImport: {
                                importingToSlot = slot
                                showingFilePicker = true
                            },
                            onManage: { selectedSlot = slot },
                            onDrop: { urls in
                                do {
                                    try store.importWallpapers(urls, to: slot, in: mood)
                                } catch {
                                    print("[UserLibraryView] Failed to import wallpapers to slot \(slot): \(error)")
                                }
                            },
                            onDropEntered: { isDroppingOnSlot = slot },
                            onDropExited: { isDroppingOnSlot = nil }
                        )
                    }
                }
                .padding(.horizontal, HorizonSpacing.xxxl)
                .padding(.bottom, HorizonSpacing.xxxl)
            }
            }
        }
        .background(.clear)
        .sheet(item: $selectedSlot) { slot in
            ManageWallpapersSheet(slot: slot)
        }
        .sheet(isPresented: $showingAllDayImporter) {
            if let mood = store.activeMood {
                MoodWallpaperImportView(mood: mood, mode: .adding)
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                if let slot = importingToSlot, let mood = store.activeMood {
                    do {
                        try store.importWallpapers(urls, to: slot, in: mood)
                    } catch {
                        print("[UserLibraryView] Failed to import wallpapers to slot \(slot): \(error)")
                    }
                }
            }
            importingToSlot = nil
        }
    }
}

// MARK: - All Day Card

private struct AllDayWallpaperCard: View {
    let wallpaperCount: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: HorizonSpacing.md) {
                ZStack {
                    Circle()
                        .fill(HorizonColors.secondaryAccent.opacity(0.18))
                        .frame(width: 42, height: 42)
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(HorizonColors.secondaryAccent.gradient)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("All Day")
                        .font(HorizonTypography.headline)
                        .foregroundColor(HorizonColors.textPrimary)
                    Text("A shared pool for every part of the day")
                        .font(HorizonTypography.caption)
                        .foregroundColor(HorizonColors.textSecondary)
                }

                Spacer()

                HorizonBadge(
                    text: wallpaperCount == 0 ? "Start Here" : "\(wallpaperCount)",
                    color: HorizonColors.secondaryAccent,
                    size: .small
                )

                Label(wallpaperCount == 0 ? "Add Wallpapers" : "Add More", systemImage: "plus.circle.fill")
                    .font(HorizonTypography.bodyMedium)
                    .foregroundColor(HorizonColors.secondaryAccent)
            }
            .padding(HorizonSpacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .horizonGlassCard(style: .standard, padding: 0)
        .accessibilityLabel("All Day, \(wallpaperCount) wallpapers")
        .accessibilityHint("Opens folder, photo, and drag-and-drop import")
    }
}

// MARK: - Time Slot Card

private struct TimeSlotCard: View {
    let slot: TimeSlot
    let wallpaperCount: Int
    let usesAllDayFallback: Bool
    let isDropTarget: Bool
    let onImport: () -> Void
    let onManage: () -> Void
    let onDrop: ([URL]) -> Void
    let onDropEntered: () -> Void
    let onDropExited: () -> Void

    var slotColor: Color {
        HorizonColors.colorForSlot(slot.slotID)
    }

    var body: some View {
        HStack(spacing: HorizonSpacing.md) {
            // Color indicator
            Circle()
                .fill(slotColor.gradient)
                .frame(width: 12, height: 12)

            // Slot info
            VStack(alignment: .leading, spacing: 4) {
                Text(slot.displayName)
                    .font(HorizonTypography.headline)
                    .foregroundColor(HorizonColors.textPrimary)
                Text(slot.timeRange)
                    .font(HorizonTypography.caption)
                    .foregroundColor(HorizonColors.textSecondary)
            }

            Spacer()

            // Wallpaper count badge
            HorizonBadge(
                text: wallpaperCount == 0 ? (usesAllDayFallback ? "Using All Day" : "Empty") : "\(wallpaperCount)",
                color: wallpaperCount == 0 ? (usesAllDayFallback ? HorizonColors.secondaryAccent : .secondary) : slotColor,
                size: .small
            )

            Button(action: onImport) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(HorizonColors.secondaryAccent.gradient)
            }
            .buttonStyle(.plain)
            .help("Import images for \(slot.displayName)")

            if wallpaperCount > 0 {
                Button(action: onManage) {
                    Text("Manage")
                        .font(HorizonTypography.bodyMedium)
                        .foregroundColor(HorizonColors.secondaryAccent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(HorizonSpacing.lg)
        .background(
            RoundedRectangle(cornerRadius: HorizonRadius.lg, style: .continuous)
                .fill(isDropTarget ? slotColor.opacity(0.15) : Color.clear)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDropTarget)
        )
        .horizonGlassCard(style: .standard, padding: 0)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: HorizonRadius.lg, style: .continuous)
                    .strokeBorder(slotColor, lineWidth: 2)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDropTarget)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    let ext = url.pathExtension.lowercased()
                    if ["jpg", "jpeg", "png", "heic", "heif", "tiff", "bmp"].contains(ext) {
                        urls.append(url)
                    }
                }
            }
            group.notify(queue: .main) {
                if !urls.isEmpty { onDrop(urls) }
            }
            return true
        }
    }
}

// MARK: - Manage Wallpapers Sheet

private struct ManageWallpapersSheet: View {
    let slot: TimeSlot
    @ObservedObject private var store = MoodStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingFilePicker = false

    private var wallpapers: [URL] {
        guard let mood = store.activeMood else { return [] }
        return store.wallpapers(for: slot, in: mood)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(slot.displayName)
                        .font(.system(size: 18, weight: .bold))
                    Text("\(wallpapers.count) wallpaper\(wallpapers.count == 1 ? "" : "s")")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    showingFilePicker = true
                } label: {
                    Label("Add More", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)

                Button("Done") { dismiss() }
                    .buttonStyle(.plain)
                    .padding(.leading, HorizonSpacing.md)
            }
            .padding(20)

            Divider()

            if wallpapers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No wallpapers yet")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                    Text("Tap Add More or drag images onto the slot")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)
                    ], spacing: 12) {
                        ForEach(wallpapers, id: \.self) { url in
                            WallpaperThumbnail(url: url) {
                                guard let mood = store.activeMood else { return }
                                do {
                                    try store.removeWallpaper(url, from: mood)
                                } catch {
                                    print("[UserLibraryView] Failed to delete wallpaper: \(error)")
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 600, height: 500)
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result, let mood = store.activeMood {
                do {
                    try store.importWallpapers(urls, to: slot, in: mood)
                } catch {
                    print("[UserLibraryView] Failed to import wallpapers to slot \(slot): \(error)")
                }
            }
        }
    }
}

// MARK: - Wallpaper Thumbnail

private struct WallpaperThumbnail: View {
    let url: URL
    let onDelete: () -> Void
    var onApply: (() -> Void)? = nil

    @State private var image: NSImage?
    @State private var isHovered = false
    @FocusState private var isKeyboardFocused: Bool

    private var isInteractionActive: Bool {
        isHovered || isKeyboardFocused
    }

    private func activatePrimaryAction() {
        onApply?()
    }

    var body: some View {
        Button(action: activatePrimaryAction) {
            ZStack {
            // Fixed-size container separates sizing from rendering. Source images
            // from user uploads have varying aspect ratios; this guarantees every
            // cell is the same shape. See tasks/lessons.md 2026-05-02.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .overlay {
                    if let image = image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .overlay { ProgressView().scaleEffect(0.7) }
                    }
                }
                .clipped()

            if isInteractionActive {
                Rectangle()
                    .fill(Color.black.opacity(0.5))
                    .overlay {
                        HStack(spacing: 12) {
                            if let onApply = onApply {
                                Button(action: onApply) {
                                    Image(systemName: "desktopcomputer")
                                        .font(.system(size: 16))
                                        .foregroundColor(.white)
                                        .padding(10)
                                        .background(HorizonColors.secondaryAccent)
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Set as wallpaper")
                            }
                            Button(action: onDelete) {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.white)
                                    .padding(10)
                                    .background(Color.red)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("Delete")
                        }
                    }
            }
        }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: 120)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .onAppear { loadImage() }
        .focusable(true)
        .focused($isKeyboardFocused)
        .contextMenu {
            if let onApply {
                Button("Set as Wallpaper", action: onApply)
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(url.deletingPathExtension().lastPathComponent)
        .accessibilityHint("Wallpaper actions are available from the context menu")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Set as Wallpaper") {
            if let onApply = onApply {
                onApply()
            }
        }
        .accessibilityAction(named: "Delete") {
            onDelete()
        }
    }

    private func loadImage() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 320,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ] as CFDictionary
                  ) else { return }
            let thumb = NSImage(cgImage: cgImage, size: .zero)
            DispatchQueue.main.async { image = thumb }
        }
    }
}
