import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The friendly front door to a Mood's shared All Day wallpaper pool.
/// It accepts individual images, whole folders, or a mixture via drag and drop.
struct MoodWallpaperImportView: View {
    enum Mode: Equatable {
        case creation
        case adding
    }

    enum Picker {
        case folder
        case photos
    }

    let mood: Mood
    let mode: Mode
    var initialPicker: Picker? = nil

    @ObservedObject private var store = MoodStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingFolderPicker = false
    @State private var showingPhotoPicker = false
    @State private var isDropTarget = false
    @State private var isImporting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var wallpapers: [URL] {
        store.allDayWallpapers(in: mood)
    }

    private var motion: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HorizonSpacing.lg) {
            VStack(alignment: .leading, spacing: HorizonSpacing.xs) {
                Text(mode == .creation ? "Bring \(mood.name) to Life" : "Add Wallpapers to \(mood.name)")
                    .font(HorizonTypography.title2)
                    .foregroundColor(HorizonColors.textPrimary)
                Text("Build one All Day pool now. You can add time-specific favorites later.")
                    .font(HorizonTypography.callout)
                    .foregroundColor(HorizonColors.textSecondary)
            }

            dropZone

            HStack(spacing: HorizonSpacing.sm) {
                Button {
                    showingFolderPicker = true
                } label: {
                    Label("Choose Folder", systemImage: "folder.fill")
                }
                .buttonStyle(.bordered)

                Button {
                    showingPhotoPicker = true
                } label: {
                    Label("Choose Photos", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)

                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Importing wallpapers...")
                        .font(HorizonTypography.caption)
                        .foregroundColor(HorizonColors.textSecondary)
                }
            }
            .disabled(isImporting)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(HorizonTypography.caption)
                    .foregroundColor(.orange)
                    .transition(.opacity)
            } else if let statusMessage {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(HorizonTypography.caption)
                    .foregroundColor(.green)
                    .transition(.opacity)
            }

            Spacer(minLength: 0)

            HStack {
                if mode == .creation && wallpapers.isEmpty {
                    Button("Skip for Now") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }

                Spacer()

                if mode == .creation && !wallpapers.isEmpty {
                    Button("Use This Vibe") {
                        store.activate(mood)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(HorizonColors.secondaryAccent)
                } else if mode == .adding {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(HorizonColors.secondaryAccent)
                }
            }
            .disabled(isImporting)
        }
        .padding(HorizonSpacing.xl)
        .frame(width: 600, height: 500)
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handlePickerResult(result)
        }
        .fileImporter(
            isPresented: $showingPhotoPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            handlePickerResult(result)
        }
        .onAppear {
            guard let initialPicker else { return }
            DispatchQueue.main.async {
                switch initialPicker {
                case .folder: showingFolderPicker = true
                case .photos: showingPhotoPicker = true
                }
            }
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HorizonRadius.lg, style: .continuous)
                .fill(isDropTarget
                      ? HorizonColors.secondaryAccent.opacity(0.14)
                      : HorizonColors.glassFill)

            RoundedRectangle(cornerRadius: HorizonRadius.lg, style: .continuous)
                .strokeBorder(
                    isDropTarget ? HorizonColors.secondaryAccent : HorizonColors.glassStroke,
                    style: StrokeStyle(lineWidth: isDropTarget ? 2 : 1, dash: wallpapers.isEmpty ? [8, 6] : [])
                )

            if wallpapers.isEmpty {
                VStack(spacing: HorizonSpacing.sm) {
                    Image(systemName: "photo.stack.fill")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(HorizonColors.secondaryAccent.gradient)
                        .scaleEffect(isDropTarget && !reduceMotion ? 1.05 : 1)
                    Text("Drop a folder or photos here")
                        .font(HorizonTypography.headline)
                        .foregroundColor(HorizonColors.textPrimary)
                    Text("Every image becomes available throughout the day.")
                        .font(HorizonTypography.callout)
                        .foregroundColor(HorizonColors.textSecondary)
                }
            } else {
                VStack(spacing: HorizonSpacing.md) {
                    thumbnailCollage
                    Text("\(wallpapers.count) wallpaper\(wallpapers.count == 1 ? "" : "s") ready for All Day")
                        .font(HorizonTypography.headline)
                        .foregroundColor(HorizonColors.textPrimary)
                    Text("Drop more whenever inspiration strikes.")
                        .font(HorizonTypography.caption)
                        .foregroundColor(HorizonColors.textSecondary)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .frame(height: 270)
        .contentShape(RoundedRectangle(cornerRadius: HorizonRadius.lg, style: .continuous))
        .animation(motion, value: isDropTarget)
        .animation(motion, value: wallpapers.count)
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            loadDroppedURLs(from: providers)
            return true
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("All Day wallpaper drop area")
        .accessibilityHint("Drop a folder or image files, or use the Choose buttons below")
    }

    private var thumbnailCollage: some View {
        ZStack {
            ForEach(Array(wallpapers.prefix(3).enumerated()), id: \.element) { index, url in
                ImportWallpaperThumbnail(url: url)
                    .frame(width: 190, height: 120)
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(index - 1) * 4))
                    .offset(x: CGFloat(index - 1) * 105)
                    .zIndex(Double(index))
            }
        }
        // Rotation, offsets, and shadows draw beyond each thumbnail's layout
        // bounds. Give the collage a real canvas and clip only that overflow so
        // it can never cover the wallpaper count below it.
        .frame(maxWidth: .infinity)
        .frame(height: 154)
        .clipped()
        .accessibilityHidden(true)
    }

    private func handlePickerResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            importWallpapers(from: urls)
        case .failure(let error):
            withAnimation(motion) {
                errorMessage = error.localizedDescription
                statusMessage = nil
            }
        }
    }

    private func importWallpapers(from urls: [URL]) {
        guard !urls.isEmpty else { return }
        isImporting = true
        errorMessage = nil
        statusMessage = nil

        Task {
            do {
                let summary = try await store.importAllDayWallpapers(from: urls, in: mood)
                withAnimation(motion) {
                    if summary.discoveredCount == 0 {
                        errorMessage = "No supported images were found."
                    } else if summary.failedCount > 0 {
                        errorMessage = "Added \(summary.importedCount) of \(summary.discoveredCount) images. \(summary.failedCount) could not be imported."
                    } else {
                        statusMessage = "Added \(summary.importedCount) wallpaper\(summary.importedCount == 1 ? "" : "s")."
                    }
                    isImporting = false
                }
            } catch {
                withAnimation(motion) {
                    errorMessage = "Import failed: \(error.localizedDescription)"
                    isImporting = false
                }
            }
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
            importWallpapers(from: urls)
        }
    }
}

private struct ImportWallpaperThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                .fill(HorizonColors.glassFill)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                .stroke(HorizonColors.glassStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        .onAppear {
            WallpaperPreviewLoader.shared.loadImage(from: url, maxPixelSize: 420) { loadedImage in
                image = loadedImage
            }
        }
    }
}
