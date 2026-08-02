import SwiftUI

// MARK: - Vibes section

// The Moodpaper switcher: every Vibe is a named set of wallpaper
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

                if store.moods.isEmpty {
                    EmptyVibesCard {
                        showingCreateSheet = true
                    }
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

private struct EmptyVibesCard: View {
    let onCreate: () -> Void

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
                Text("Create a feeling for your desktop, then fill it with wallpapers you love.")
                    .font(HorizonTypography.callout)
                    .foregroundColor(HorizonColors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: onCreate) {
                Label("Create Your First Vibe", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(HorizonColors.secondaryAccent)
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
                    .help("Edit Vibe")
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
            Text(isCreate ? "Name Your Vibe" : "Edit Vibe")
                .font(HorizonTypography.title3)
                .foregroundColor(HorizonColors.textPrimary)

            VStack(alignment: .leading, spacing: HorizonSpacing.xs) {
                Text("Vibe name")
                    .font(HorizonTypography.caption)
                    .foregroundColor(HorizonColors.textSecondary)
                TextField(OnboardingCopy.step4NamePlaceholder, text: $name)
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
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(HorizonSpacing.xl)
        .frame(width: 420, height: isCreate ? 320 : 260)
    }
}
