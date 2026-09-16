import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

// The Wallpapers page edits the active Vibe as one grid. Imports land in the
// shared fallback pool (internally AllDay). Time-slot folders remain the
// engine's override model via Play Throughout the Day and Use During….
struct UserLibraryView: View {
    var searchText: String = ""
    @ObservedObject private var store = MoodStore.shared
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    @State private var showingPhotoPicker = false
    @State private var showingFolderPicker = false
    @State private var isImporting = false
    @State private var importStatus: ImportStatus?
    @State private var selectedURLs: Set<URL> = []
    @State private var previewItem: WallpaperLibraryItem?
    @State private var useDuringItems: [WallpaperLibraryItem] = []
    @State private var isDropTarget = false
    @State private var pendingMoodpaperDelete: [WallpaperLibraryItem] = []
    @AppStorage(HorizonScheduleDefaults.timeSlotModeKey) private var timeSlotMode = "Detailed"

    private var filteredItems: [WallpaperLibraryItem] {
        guard let mood = store.activeMood else { return [] }
        let items = store.libraryItems(in: mood)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { item in
            item.url.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains(query)
                || item.placement.badgeTitle.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedItems: [WallpaperLibraryItem] {
        filteredItems.filter { selectedURLs.contains($0.url) }
    }

    private var isActiveMoodEmpty: Bool {
        guard let mood = store.activeMood else { return true }
        return store.totalWallpaperCount(in: mood) == 0
    }

    private var visibleSlotIDs: [String] {
        HorizonScheduleDefaults.slotIDs(for: timeSlotMode)
    }

    private var visibleSlots: [TimeSlot] {
        TimeSlot.allCases.filter { visibleSlotIDs.contains($0.slotID) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let importStatus {
                ImportStatusBanner(status: importStatus, isImporting: isImporting)
                    .padding(.horizontal, HorizonSpacing.xxxl)
                    .padding(.bottom, HorizonSpacing.md)
            }
            if !selectedURLs.isEmpty {
                selectionBar
            }
            content
        }
        .background(.clear)
        .onAppear {
            _ = store.ensurePlayableVibe()
        }
        .onChange(of: store.usesCatalog) { _, usesCatalog in
            // A completed library update retires the "update your library"
            // delete notice that asked for it.
            if usesCatalog { importStatus = nil }
        }
        .onChange(of: store.activeMoodID) { _, _ in
            selectedURLs.removeAll()
            previewItem = nil
        }
        .sheet(item: $previewItem) { item in
            WallpaperPreviewSheet(
                item: item,
                slots: visibleSlots,
                onUseNow: { useNow([item]) },
                onPlayThroughoutTheDay: { playThroughoutTheDay([item]) },
                onUseDuring: { slot in assign([item], to: .during(slot)) },
                onRemoveFromVibe: {
                    removeFromVibe([item])
                    previewItem = nil
                },
                onDeleteFromMoodpaper: {
                    pendingMoodpaperDelete = [item]
                    previewItem = nil
                }
            )
        }
        .alert("Delete from Moodpaper?", isPresented: Binding(
            get: { !pendingMoodpaperDelete.isEmpty },
            set: { if !$0 { pendingMoodpaperDelete = [] } }
        )) {
            Button("Delete from Moodpaper", role: .destructive) {
                deleteFromMoodpaper(pendingMoodpaperDelete)
                pendingMoodpaperDelete = []
            }
            Button("Cancel", role: .cancel) { pendingMoodpaperDelete = [] }
        } message: {
            Text("This removes the photo from every Vibe and deletes the stored file. Remove from Vibe keeps the photo in Moodpaper.")
        }
        .sheet(isPresented: Binding(
            get: { !useDuringItems.isEmpty },
            set: { if !$0 { useDuringItems = [] } }
        )) {
            UseDuringSheet(slots: visibleSlots) { slot in
                assign(useDuringItems, to: .during(slot))
                useDuringItems = []
            }
        }
        .fileImporter(
            isPresented: $showingPhotoPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { handlePickerResult($0) }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { handlePickerResult($0) }
    }

    private var header: some View {
        HStack(spacing: HorizonSpacing.lg) {
            HStack(spacing: 10) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(HorizonColors.secondaryAccent.gradient)
                Text("Editing \"\(store.activeMood?.displayName ?? "My Wallpapers")\"")
                    .font(HorizonTypography.title2)
                    .foregroundColor(HorizonColors.textPrimary)
            }

            Spacer()

            if store.activeMood != nil {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label("Add Folder", systemImage: "folder.fill")
                }
                .buttonStyle(.bordered)
                .disabled(isImporting)

                Button {
                    showingPhotoPicker = true
                } label: {
                    Label("Add Photos", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.borderedProminent)
                .tint(HorizonColors.secondaryAccent)
                .disabled(isImporting)
            }
        }
        .padding(.horizontal, HorizonSpacing.xxxl)
        .padding(.top, HorizonSpacing.xl)
        .padding(.bottom, HorizonSpacing.lg)
    }

    private var selectionBar: some View {
        HStack(spacing: HorizonSpacing.sm) {
            Text("\(selectedURLs.count) selected")
                .font(HorizonTypography.callout)
                .foregroundColor(HorizonColors.textSecondary)
            Spacer()
            if selectedItems.count == 1, let item = selectedItems.first {
                Button("Preview") { previewItem = item }
                    .buttonStyle(.bordered)
            }
            Button("Use Now") { useNow(selectedItems) }
                .buttonStyle(.bordered)
                .disabled(selectedItems.count != 1 || wallpaperManager.isChangingWallpaper)
            Button("Play Throughout the Day") { playThroughoutTheDay(selectedItems) }
                .buttonStyle(.bordered)
            Button("Use During…") { useDuringItems = selectedItems }
                .buttonStyle(.bordered)
            Button("Remove from Vibe") { removeFromVibe(selectedItems) }
                .buttonStyle(.bordered)
            Button("Delete from Moodpaper", role: .destructive) { pendingMoodpaperDelete = selectedItems }
                .buttonStyle(.bordered)
            Button("Clear") { selectedURLs.removeAll() }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, HorizonSpacing.xxxl)
        .padding(.bottom, HorizonSpacing.md)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wallpaper actions")
    }

    @ViewBuilder
    private var content: some View {
        if let mood = store.activeMood, isActiveMoodEmpty {
            emptyDropCanvas(moodName: mood.displayName)
        } else if store.activeMood != nil {
            grid
        }
    }

    private func emptyDropCanvas(moodName: String) -> some View {
        VStack(spacing: HorizonSpacing.md) {
            Image(systemName: "photo.stack.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(HorizonColors.secondaryAccent.gradient)
                .accessibilityHidden(true)
            Text("\"\(moodName)\" is empty")
                .font(HorizonTypography.headline)
                .foregroundColor(HorizonColors.textPrimary)
            Text("Drop photos here, or add a folder. They play throughout the day until you assign any of them to a time of day.")
                .font(HorizonTypography.callout)
                .foregroundColor(HorizonColors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .horizonGlassCard(style: .standard, padding: HorizonSpacing.xl)
        .padding(.horizontal, HorizonSpacing.xxxl)
        .padding(.bottom, HorizonSpacing.xxxl)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: HorizonRadius.lg, style: .continuous)
                    .strokeBorder(HorizonColors.secondaryAccent, lineWidth: 2)
                    .padding(.horizontal, HorizonSpacing.xxxl)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            loadDroppedURLs(from: providers)
            return true
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168, maximum: 220), spacing: HorizonSpacing.md)],
                spacing: HorizonSpacing.md
            ) {
                ForEach(filteredItems) { item in
                    WallpaperGridCell(
                        item: item,
                        isSelected: selectedURLs.contains(item.url)
                    )
                    .gesture(
                        TapGesture(count: 2).onEnded {
                            previewItem = item
                        }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 1).onEnded {
                            toggleSelection(of: item)
                        }
                    )
                    .contextMenu {
                        Button("Preview") { previewItem = item }
                        Button("Use Now") { useNow([item]) }
                        Button("Play Throughout the Day") { playThroughoutTheDay([item]) }
                        Menu("Use During…") {
                            ForEach(visibleSlots, id: \.self) { slot in
                                Button(slot.displayName) {
                                    assign([item], to: .during(slot))
                                }
                            }
                        }
                        Divider()
                        Button("Remove from Vibe") { removeFromVibe([item]) }
                        Button("Delete from Moodpaper", role: .destructive) {
                            pendingMoodpaperDelete = [item]
                        }
                    }
                    .accessibilityAction(named: "Preview") { previewItem = item }
                    .accessibilityAction(named: "Use Now") { useNow([item]) }
                    .accessibilityAction(named: "Play Throughout the Day") { playThroughoutTheDay([item]) }
                    .accessibilityAction(named: "Remove from Vibe") { removeFromVibe([item]) }
                    .accessibilityAction(named: "Delete from Moodpaper") { pendingMoodpaperDelete = [item] }
                }
            }
            .padding(.horizontal, HorizonSpacing.xxxl)
            .padding(.bottom, HorizonSpacing.xxxl)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            loadDroppedURLs(from: providers)
            return true
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: HorizonRadius.lg, style: .continuous)
                    .strokeBorder(HorizonColors.secondaryAccent, lineWidth: 2)
                    .padding(.horizontal, HorizonSpacing.xxxl)
                    .padding(.bottom, HorizonSpacing.xxxl)
                    .allowsHitTesting(false)
            }
        }
    }

    private func toggleSelection(of item: WallpaperLibraryItem) {
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
            if selectedURLs.contains(item.url) {
                selectedURLs.remove(item.url)
            } else {
                selectedURLs.insert(item.url)
            }
        } else {
            selectedURLs = [item.url]
        }
    }

    private func handlePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            importWallpapers(urls)
        case .failure(let error):
            importStatus = ImportStatus(importFailure: error)
        }
    }

    private func loadDroppedURLs(from providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }
                guard let url else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { importWallpapers(urls) }
        }
    }

    /// Grid imports always land in the shared fallback pool so a drop or
    /// picker adds photos that play throughout the day until assigned.
    private func importWallpapers(_ urls: [URL]) {
        guard let mood = store.activeMood, !urls.isEmpty else { return }
        isImporting = true
        importStatus = nil
        Task {
            do {
                let summary = try await store.importAllDayWallpapers(from: urls, in: mood)
                importStatus = ImportStatus(summary: summary)
            } catch {
                importStatus = ImportStatus(importFailure: error)
            }
            isImporting = false
        }
    }

    private func useNow(_ items: [WallpaperLibraryItem]) {
        guard let item = items.first else { return }
        wallpaperManager.setWallpaperManually(url: item.url)
    }

    private func playThroughoutTheDay(_ items: [WallpaperLibraryItem]) {
        // Time-of-day assignment copies a photo into slot folders and keeps the Vibe
        // pool entry, so returning to general playback must reuse that entry
        // instead of moving the slot copy in beside it.
        guard let mood = store.activeMood else { return }
        do {
            for item in items {
                try store.playThroughoutTheDay(item.url, in: mood)
            }
            selectedURLs.removeAll()
            importStatus = nil
        } catch {
            importStatus = ImportStatus(updateFailure: error)
        }
    }

    private func assign(_ items: [WallpaperLibraryItem], to placement: WallpaperPlacement) {
        guard let mood = store.activeMood else { return }
        do {
            for item in items {
                try store.setWallpaperPlacement(placement, for: item.url, in: mood)
            }
            selectedURLs.removeAll()
            importStatus = nil
        } catch {
            importStatus = ImportStatus(updateFailure: error)
        }
    }

    private func removeFromVibe(_ items: [WallpaperLibraryItem]) {
        guard let mood = store.activeMood else { return }
        do {
            for item in items {
                try store.removeWallpaper(item.url, from: mood)
                selectedURLs.remove(item.url)
            }
            importStatus = nil
        } catch {
            importStatus = ImportStatus(deleteFailure: error)
        }
    }

    private func deleteFromMoodpaper(_ items: [WallpaperLibraryItem]) {
        do {
            for item in items {
                try store.deleteWallpaperFromMoodpaper(item.url)
                selectedURLs.remove(item.url)
            }
            importStatus = nil
        } catch {
            importStatus = ImportStatus(deleteFailure: error)
        }
    }
}

// MARK: - Import feedback

/// One place that turns an import or delete outcome into user-facing words,
/// so every wallpaper surface says what happened instead of failing silently.
struct ImportStatus: Equatable {
    let text: String
    let isError: Bool

    private init(text: String, isError: Bool) {
        self.text = text
        self.isError = isError
    }

    init(importFailure error: Error) {
        self.init(text: "Import failed: \(error.localizedDescription)", isError: true)
    }

    init(deleteFailure error: Error) {
        self.init(
            text: "Couldn't delete that wallpaper: \(error.localizedDescription)",
            isError: true
        )
    }

    init(updateFailure error: Error) {
        self.init(
            text: "Couldn't update that wallpaper: \(error.localizedDescription)",
            isError: true
        )
    }

    init(summary: WallpaperImportSummary) {
        if summary.discoveredCount == 0 {
            self.init(text: "No supported images were found.", isError: true)
        } else if summary.failedCount > 0 {
            self.init(
                text: "Added \(summary.importedCount) of \(summary.discoveredCount) images. "
                    + "\(summary.failedCount) could not be imported.",
                isError: true
            )
        } else {
            self.init(
                text: "Added \(summary.importedCount) wallpaper\(summary.importedCount == 1 ? "" : "s").",
                isError: false
            )
        }
    }
}

private struct ImportStatusBanner: View {
    let status: ImportStatus
    var isImporting: Bool = false

    var body: some View {
        HStack(spacing: HorizonSpacing.sm) {
            if isImporting {
                ProgressView().controlSize(.small)
            }
            Label(
                status.text,
                systemImage: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
            )
            .font(HorizonTypography.caption)
            .foregroundColor(status.isError ? .orange : .green)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.text)
    }
}

// MARK: - Grid cell

private struct WallpaperGridCell: View {
    let item: WallpaperLibraryItem
    let isSelected: Bool

    @State private var image: NSImage?
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 132)
                .overlay {
                    if let image {
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

            Text(item.placement.badgeTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark)
                .padding(8)

            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(HorizonColors.secondaryAccent, lineWidth: 3)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white, HorizonColors.secondaryAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovered = $0 }
        .onAppear { loadImage() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: item))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Selects this wallpaper. Preview and Use Now are in the context menu.")
    }

    private func accessibilityLabel(for item: WallpaperLibraryItem) -> String {
        let name = item.url.deletingPathExtension().lastPathComponent
        if item.vibeIDs.count > 1 {
            return "\(name), \(item.placement.badgeTitle), in \(item.vibeIDs.count) Vibes"
        }
        return "\(name), \(item.placement.badgeTitle)"
    }

    private func loadImage() {
        let url = item.url
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

// MARK: - Preview

private struct WallpaperPreviewSheet: View {
    let item: WallpaperLibraryItem
    let slots: [TimeSlot]
    let onUseNow: () -> Void
    let onPlayThroughoutTheDay: () -> Void
    let onUseDuring: (TimeSlot) -> Void
    let onRemoveFromVibe: () -> Void
    let onDeleteFromMoodpaper: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 16, weight: .semibold))
                    Text(item.placement.badgeTitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)

            HStack(spacing: HorizonSpacing.sm) {
                Button("Use Now", action: onUseNow)
                    .buttonStyle(.borderedProminent)
                    .tint(HorizonColors.secondaryAccent)
                Button("Play Throughout the Day", action: onPlayThroughoutTheDay)
                    .buttonStyle(.bordered)
                Menu("Use During…") {
                    ForEach(slots, id: \.self) { slot in
                        Button(slot.displayName) { onUseDuring(slot) }
                    }
                }
                Spacer()
                Button("Remove from Vibe", action: onRemoveFromVibe)
                Button("Delete from Moodpaper", role: .destructive, action: onDeleteFromMoodpaper)
            }
            .padding(20)
        }
        .frame(width: 720, height: 560)
        .onAppear { loadImage() }
    }

    private func loadImage() {
        let url = item.url
        DispatchQueue.global(qos: .userInitiated).async {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1600,
                        kCGImageSourceCreateThumbnailWithTransform: true
                    ] as CFDictionary
                  ) else { return }
            let preview = NSImage(cgImage: cgImage, size: .zero)
            DispatchQueue.main.async { image = preview }
        }
    }
}

private struct UseDuringSheet: View {
    let slots: [TimeSlot]
    let onSelect: (TimeSlot) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: HorizonSpacing.md) {
            Text("Use During…")
                .font(HorizonTypography.title2)
            Text("Keep this photo for a specific time of day. Other times still use wallpapers that play throughout the day.")
                .font(HorizonTypography.callout)
                .foregroundColor(HorizonColors.textSecondary)
            List(slots, id: \.self) { slot in
                Button {
                    onSelect(slot)
                    dismiss()
                } label: {
                    HStack {
                        Text(slot.displayName)
                        Spacer()
                        Text(slot.timeRange)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(20)
        .frame(width: 420, height: 480)
    }
}
