import SwiftUI

// MARK: - Vibes section

// The Moodpaper switcher: every Vibe is a named set of wallpaper
// assignments, and this grid is where the user creates, renames, duplicates,
// deletes, and activates them. Shared wallpapers play throughout the day;
// Wallpapers can assign any photo to a time of day.
struct MoodsView: View {
    @ObservedObject private var store = MoodStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingCreateSheet = false
    @State private var editingMood: Mood? = nil
    @State private var importRequest: MoodImportRequest?
    @State private var legacyImportResult: LegacyImportResult?
    @AppStorage(LegacyLibraryMigration.didImportKey) private var didImportLegacyLibrary = false

    /// Offered while the library is still empty, because that is exactly the
    /// state an upgrade to a sandboxed build lands in: the previous install's
    /// Vibes live in a folder this build cannot reach on its own.
    private var showLegacyImport: Bool {
        !didImportLegacyLibrary && store.isLibraryEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HorizonSpacing.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: HorizonSpacing.xs) {
                        Text("Vibes")
                            .font(HorizonTypography.title2)
                            .foregroundColor(HorizonColors.textPrimary)
                        Text("Switch your whole desktop personality in one click.")
                            .font(HorizonTypography.callout)
                            .foregroundColor(HorizonColors.textSecondary)
                    }
                    Spacer()
                    Button {
                        showingCreateSheet = true
                    } label: {
                        Label("New Vibe", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HorizonColors.secondaryAccent)
                }

                if showLegacyImport {
                    LegacyLibraryImportCard(onImport: importLegacyLibrary)
                }

                if store.moods.isEmpty {
                    EmptyVibesCard(
                        onCreate: { showingCreateSheet = true },
                        onStartWithoutName: {
                            _ = store.ensurePlayableVibe()
                            NotificationCenter.default.post(name: .navigateToUserWallpapers, object: nil)
                        }
                    )
                } else {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: HorizonSpacing.md),
                            GridItem(.flexible(), spacing: HorizonSpacing.md)
                        ],
                        spacing: HorizonSpacing.md
                    ) {
                        ForEach(store.moods) { mood in
                            MoodCard(
                                mood: mood,
                                isActive: store.activeMoodID == mood.id,
                                onActivate: {
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                        store.activate(mood)
                                    }
                                },
                                onAddWallpapers: {
                                    importRequest = MoodImportRequest(mood: mood, initialPicker: nil)
                                },
                                onChooseFolder: {
                                    importRequest = MoodImportRequest(mood: mood, initialPicker: .folder)
                                },
                                onChoosePhotos: {
                                    importRequest = MoodImportRequest(mood: mood, initialPicker: .photos)
                                },
                                onEdit: { editingMood = mood }
                            )
                        }
                    }
                }

                Text("Add wallpapers that play throughout the day. Assign any photo to a time of day from Wallpapers.")
                    .font(HorizonTypography.caption)
                    .foregroundColor(HorizonColors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showingCreateSheet) {
            MoodEditorSheet(mode: .create)
        }
        .sheet(item: $editingMood) { mood in
            MoodEditorSheet(mode: .edit(mood))
        }
        .sheet(item: $importRequest) { request in
            MoodWallpaperImportView(
                mood: request.mood,
                mode: .adding,
                initialPicker: request.initialPicker
            )
        }
        .alert(item: $legacyImportResult) { result in
            Alert(title: Text(result.title), message: Text(result.message), dismissButton: .default(Text("OK")))
        }
    }

    private func importLegacyLibrary() {
        let legacyRoot: URL
        switch LegacyLibraryMigration.promptForLegacyRoot() {
        case .cancelled:
            return
        case .notALibrary(let picked):
            legacyImportResult = LegacyImportResult(
                title: "Not a Moodpaper Library",
                message: "“\(picked.lastPathComponent)” has no Moods folder inside it. Choose the Moodpaper folder itself rather than one of the folders within it."
            )
            return
        case .selected(let picked):
            legacyRoot = picked
        }

        do {
            let summary = try store.importLegacyLibrary(from: legacyRoot)
            didImportLegacyLibrary = true
            legacyImportResult = LegacyImportResult(
                title: summary.moodCount > 0 ? "Library Imported" : "Nothing to Import",
                message: summary.moodCount > 0
                    ? "Brought in \(summary.moodCount) Vibe\(summary.moodCount == 1 ? "" : "s") and \(summary.imageCount) wallpaper\(summary.imageCount == 1 ? "" : "s")."
                    : "That folder's Vibes are already in your library."
            )
        } catch {
            legacyImportResult = LegacyImportResult(
                title: "Import Failed",
                message: error.localizedDescription
            )
        }
    }
}

private struct LegacyImportResult: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct LegacyLibraryImportCard: View {
    let onImport: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: HorizonSpacing.md) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 22))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(HorizonColors.secondaryAccent)

            VStack(alignment: .leading, spacing: HorizonSpacing.xs) {
                Text("Coming from an earlier version?")
                    .font(HorizonTypography.bodyMedium)
                    .foregroundColor(HorizonColors.textPrimary)
                Text("Your previous Vibes and wallpapers live in a folder this version cannot open on its own. Point Moodpaper at it and everything copies across — the originals stay where they are.")
                    .font(HorizonTypography.caption)
                    .foregroundColor(HorizonColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: HorizonSpacing.sm)

            Button("Import…", action: onImport)
                .buttonStyle(.bordered)
        }
        .horizonGlassCard(style: .standard, padding: HorizonSpacing.lg)
    }
}

private struct EmptyVibesCard: View {
    let onCreate: () -> Void
    let onStartWithoutName: () -> Void

    var body: some View {
        VStack(spacing: HorizonSpacing.md) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(HorizonColors.secondaryAccent.gradient)
                .accessibilityHidden(true)

            VStack(spacing: HorizonSpacing.xs) {
                Text("What's your Vibe?")
                    .font(HorizonTypography.title2)
                    .foregroundColor(HorizonColors.textPrimary)
                Text("Add wallpapers and start playing. Naming a Vibe is optional — it's a playback style, not a prerequisite.")
                    .font(HorizonTypography.callout)
                    .foregroundColor(HorizonColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: onCreate) {
                Label("Create Your First Vibe", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(HorizonColors.secondaryAccent)

            Button("Start with wallpapers", action: onStartWithoutName)
                .buttonStyle(.plain)
                .foregroundStyle(HorizonColors.textSecondary)
                .accessibilityLabel("Start with wallpapers without naming a Vibe")
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .horizonGlassCard(style: .standard, padding: HorizonSpacing.xl)
    }
}

private struct MoodImportRequest: Identifiable {
    let id = UUID()
    let mood: Mood
    let initialPicker: MoodWallpaperImportView.Picker?
}

// MARK: - Mood card

struct MoodCard: View {
    let mood: Mood
    let isActive: Bool
    let onActivate: () -> Void
    let onAddWallpapers: () -> Void
    let onChooseFolder: () -> Void
    let onChoosePhotos: () -> Void
    let onEdit: () -> Void

    @ObservedObject private var store = MoodStore.shared
    @State private var isHovered = false
    @State private var showingShapeMyDay = false

    private var wallpaperCount: Int { store.totalWallpaperCount(in: mood) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: wallpaperCount == 0 ? onAddWallpapers : onActivate) {
                VStack(alignment: .leading, spacing: HorizonSpacing.sm) {
                    HStack(alignment: .top) {
                        ZStack {
                            RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                                .fill(HorizonColors.secondaryAccent.opacity(0.2))
                                .frame(width: 44, height: 44)
                            Image(systemName: "paintpalette.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(HorizonColors.secondaryAccent)
                        }
                        Spacer()
                        if wallpaperCount > 0 {
                            Menu {
                                Button("Choose Folder", systemImage: "folder.fill", action: onChooseFolder)
                                Button("Choose Photos", systemImage: "photo.on.rectangle.angled", action: onChoosePhotos)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(HorizonColors.textSecondary)
                                    .padding(6)
                                    .background(Circle().fill(HorizonColors.glassFill))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .help("Add wallpapers")
                            .accessibilityLabel("Add wallpapers to \(mood.displayName)")
                        }
                        Button(action: onEdit) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(HorizonColors.textSecondary)
                                .padding(6)
                                .background(
                                    Circle().fill(HorizonColors.glassFill)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Edit Vibe")
                        .accessibilityLabel("Edit \(mood.displayName)")
                    }

                    Text(mood.displayName)
                        .font(HorizonTypography.headline)
                        .foregroundColor(HorizonColors.textPrimary)
                        .lineLimit(1)
                        .italic(mood.isUnnamed)

                    if wallpaperCount == 0 {
                        Label("Add Wallpapers", systemImage: "plus.circle.fill")
                            .font(HorizonTypography.callout)
                            .foregroundColor(HorizonColors.secondaryAccent)
                    } else {
                        Text("\(wallpaperCount) wallpaper\(wallpaperCount == 1 ? "" : "s")")
                            .font(HorizonTypography.caption)
                            .foregroundColor(HorizonColors.textSecondary)
                    }

                    HStack(spacing: 4) {
                        Circle()
                            .fill(isActive ? Color.green : HorizonColors.textTertiary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text(isActive ? "Active" : (wallpaperCount == 0 ? "Ready for your favorites" : "Tap to activate"))
                            .font(HorizonTypography.caption)
                            .foregroundColor(isActive ? .green : HorizonColors.textTertiary)
                    }
                }
                .padding(HorizonSpacing.lg)
                .padding(.bottom, 0)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            VibeHowOftenControl(mood: mood)
                .padding(.horizontal, HorizonSpacing.lg)
            Button("Shape My Day") {
                showingShapeMyDay = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, HorizonSpacing.lg)
            .padding(.bottom, HorizonSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("shape-my-day")
            .accessibilityHint("Optional. Opens time-of-day wallpaper control. Not required to use this Vibe.")
        }
        .background(
            RoundedRectangle(cornerRadius: HorizonRadius.lg, style: .continuous)
                .fill(isActive
                      ? AnyShapeStyle(HorizonColors.secondaryAccent.opacity(0.15))
                      : AnyShapeStyle(HorizonColors.glassFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HorizonRadius.lg, style: .continuous)
                .stroke(isActive
                        ? HorizonColors.secondaryAccent.opacity(0.5)
                        : (isHovered ? HorizonColors.glassStrokeHover : HorizonColors.glassStroke),
                        lineWidth: isActive ? 1.5 : 1)
        )
        .onHover { isHovered = $0 }
        .sheet(isPresented: $showingShapeMyDay) {
            ShapeMyDayView(moodID: mood.id)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(mood.displayName), \(isActive ? "active" : "inactive"), \(wallpaperCount == 0 ? "add wallpapers" : "\(wallpaperCount) wallpapers")")
    }
}

private struct VibeHowOftenControl: View {
    let mood: Mood
    @ObservedObject private var store = MoodStore.shared

    private var perDay: Double {
        store.effectiveWallpapersPerDay(for: mood)
    }

    var body: some View {
        HStack(spacing: HorizonSpacing.sm) {
            Text("How often")
                .font(HorizonTypography.caption)
                .foregroundColor(HorizonColors.textTertiary)
            Spacer()
            Stepper(value: Binding(
                get: { perDay },
                set: { store.setWallpapersPerDay($0, for: mood) }
            ), in: 1...48, step: 1) {
                Text("\(Int(perDay)) a day")
                    .font(HorizonTypography.caption)
                    .monospacedDigit()
                    .foregroundColor(HorizonColors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("How often, \(Int(perDay)) wallpapers a day")
        .accessibilityHint("How often this Vibe changes wallpapers")
    }
}

// MARK: - Mood editor sheet

struct MoodEditorSheet: View {
    enum Mode {
        case create
        case edit(Mood)
    }

    let mode: Mode

    @ObservedObject private var store = MoodStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var showingDeleteConfirm = false
    @State private var showingShapeMyDay = false
    @State private var createdMood: Mood?

    private var editingMood: Mood? {
        if case .edit(let mood) = mode { return mood }
        return nil
    }

    private var isCreate: Bool { editingMood == nil }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if let createdMood {
                MoodWallpaperImportView(mood: createdMood, mode: .creation)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                editorContent
            }
        }
        .onAppear {
            if let mood = editingMood {
                name = mood.name
            }
        }
        .sheet(isPresented: $showingShapeMyDay) {
            if let mood = editingMood {
                ShapeMyDayView(moodID: mood.id)
            }
        }
        .alert("Delete this Vibe?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let mood = editingMood {
                    store.delete(mood)
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its imported wallpapers are removed with it. This cannot be undone.")
        }
    }

    private var editorContent: some View {
        VStack(alignment: .leading, spacing: HorizonSpacing.lg) {
            Text(isCreate ? "New Vibe" : "Edit Vibe")
                .font(HorizonTypography.title3)
                .foregroundColor(HorizonColors.textPrimary)

            VStack(alignment: .leading, spacing: HorizonSpacing.xs) {
                Text("Name (optional)")
                    .font(HorizonTypography.caption)
                    .foregroundColor(HorizonColors.textSecondary)
                TextField(OnboardingCopy.namePlaceholder, text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            if isCreate {
                HStack(spacing: HorizonSpacing.xs) {
                    ForEach(VibeNaming.suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            name = suggestion
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Vibe name suggestions")
            }

            if let mood = editingMood {
                VibeHowOftenControl(mood: mood)
                VStack(alignment: .leading, spacing: HorizonSpacing.xs) {
                    Button("Shape My Day") {
                        showingShapeMyDay = true
                    }
                    .buttonStyle(.bordered)
                    Text("Optional. Keep playing throughout the day, or assign photos to specific times.")
                        .font(HorizonTypography.caption)
                        .foregroundColor(HorizonColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens time-of-day wallpaper control. Not required to use this Vibe.")
                HStack(spacing: HorizonSpacing.sm) {
                    Button("Duplicate") {
                        store.duplicate(mood)
                        dismiss()
                    }
                    Button("Delete Vibe", role: .destructive) {
                        showingDeleteConfirm = true
                    }
                }
            }

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isCreate ? "Create Vibe" : "Save") {
                    if let mood = editingMood {
                        store.rename(mood, to: trimmedName)
                        dismiss()
                    } else {
                        createdMood = store.create(name: trimmedName)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(HorizonColors.secondaryAccent)
            }
        }
        .padding(HorizonSpacing.xl)
        .frame(width: 420, height: isCreate ? 320 : 360)
    }
}
