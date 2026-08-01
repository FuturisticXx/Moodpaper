import SwiftUI

// MARK: - Moods section

// The Moodpaper switcher: every Mood is a named set of wallpaper
// assignments, and this grid is where the user creates, renames, duplicates,
// deletes, and activates them. All Day provides the simple shared pool, while
// the Library offers optional per-slot overrides.
struct MoodsView: View {
    @ObservedObject private var store = MoodStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingCreateSheet = false
    @State private var editingMood: Mood? = nil
    @State private var importRequest: MoodImportRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HorizonSpacing.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: HorizonSpacing.xs) {
                        Text("Moods")
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
                        Label("New Mood", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HorizonColors.secondaryAccent)
                }

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

                Text("All Day wallpapers make setup simple. Add time-slot favorites from the Library whenever you want.")
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

    private var wallpaperCount: Int { store.totalWallpaperCount(in: mood) }

    var body: some View {
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
                        .accessibilityLabel("Add wallpapers to \(mood.name)")
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
                    .help("Edit mood")
                    .accessibilityLabel("Edit \(mood.name)")
                }

                Text(mood.name)
                    .font(HorizonTypography.headline)
                    .foregroundColor(HorizonColors.textPrimary)
                    .lineLimit(1)

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
            .frame(maxWidth: .infinity, alignment: .leading)
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
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(mood.name), \(isActive ? "active" : "inactive"), \(wallpaperCount == 0 ? "add wallpapers" : "\(wallpaperCount) wallpapers")")
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
        .alert("Delete this Mood?", isPresented: $showingDeleteConfirm) {
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
            Text(isCreate ? "Name Your Mood" : "Edit Mood")
                .font(HorizonTypography.title3)
                .foregroundColor(HorizonColors.textPrimary)

            VStack(alignment: .leading, spacing: HorizonSpacing.xs) {
                Text("Name")
                    .font(HorizonTypography.caption)
                    .foregroundColor(HorizonColors.textSecondary)
                TextField("Work Week, Cozy Weekend...", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            if let mood = editingMood {
                HStack(spacing: HorizonSpacing.sm) {
                    Button("Duplicate") {
                        store.duplicate(mood)
                        dismiss()
                    }
                    Button("Delete Mood", role: .destructive) {
                        showingDeleteConfirm = true
                    }
                }
            }

            Spacer()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isCreate ? "Create" : "Save") {
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
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(HorizonSpacing.xl)
        .frame(width: 380, height: 260)
    }
}
