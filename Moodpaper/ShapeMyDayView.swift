import SwiftUI

/// Optional time-of-day editor. Casual Vibes never need this surface.
struct ShapeMyDayView: View {
    let moodID: String

    @ObservedObject private var store = MoodStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedURL: URL?
    @State private var showingAllPeriods = false
    @State private var actionError: String?
    @State private var skipRevision = 0

    private var mood: Mood? { store.mood(id: moodID) }

    var body: some View {
        Group {
            if let mood {
                editor(for: mood)
            } else {
                Text("This Vibe is no longer available.")
                    .padding(HorizonSpacing.xl)
            }
        }
        .frame(minWidth: 780, minHeight: 620)
    }

    private func editor(for mood: Mood) -> some View {
        VStack(alignment: .leading, spacing: HorizonSpacing.md) {
            header(mood: mood)
            if let actionError {
                Text(actionError)
                    .font(HorizonTypography.caption)
                    .foregroundColor(.orange)
                    .accessibilityLabel(actionError)
            }
            vibePhotos(in: mood)
            fourGroups(in: mood)
                .id(skipRevision)
            DisclosureGroup(isExpanded: $showingAllPeriods) {
                allPeriods(in: mood)
                    .id(skipRevision)
            } label: {
                Text("All Periods")
                    .font(HorizonTypography.headline)
                    .foregroundColor(HorizonColors.textPrimary)
            }
            .accessibilityHint("Shows every detailed time of day in this Vibe")
            Spacer(minLength: 0)
        }
        .padding(HorizonSpacing.lg)
    }

    private func header(mood: Mood) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: HorizonSpacing.xs) {
                Text("Shape My Day")
                    .font(HorizonTypography.title2)
                    .foregroundColor(HorizonColors.textPrimary)
                Text("Photos in “\(mood.displayName)” play throughout the day unless a time has specific photos.")
                    .font(HorizonTypography.callout)
                    .foregroundColor(HorizonColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func vibePhotos(in mood: Mood) -> some View {
        VStack(alignment: .leading, spacing: HorizonSpacing.sm) {
            Text("This Vibe's photos")
                .font(HorizonTypography.headline)
                .foregroundColor(HorizonColors.textPrimary)
            Text("These photos play throughout the day. Assign any of them to a time to make that part of the day specific.")
                .font(HorizonTypography.callout)
                .foregroundColor(HorizonColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            let items = store.vibeSourceItems(in: mood)
            if items.isEmpty {
                Text("Add photos to this Vibe from Wallpapers first.")
                    .font(HorizonTypography.callout)
                    .foregroundColor(HorizonColors.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HorizonSpacing.sm) {
                        ForEach(items) { item in
                            ShapeMyDayThumbnail(
                                url: item.url,
                                isSelected: selectedURL == item.url
                            )
                            .onTapGesture { selectedURL = item.url }
                            .draggable(item.url)
                            .contextMenu { wallpaperMenu(item.url, in: mood) }
                            .accessibilityAction(named: "Play throughout the day") {
                                perform { try store.playThroughoutTheDay(item.url, in: mood) }
                            }
                            .accessibilityAction(named: "Assign to Morning") {
                                perform { try store.assignWallpaper(item.url, to: .morning, in: mood) }
                            }
                            .accessibilityAction(named: "Assign to Day") {
                                perform { try store.assignWallpaper(item.url, to: .day, in: mood) }
                            }
                            .accessibilityAction(named: "Assign to Evening") {
                                perform { try store.assignWallpaper(item.url, to: .evening, in: mood) }
                            }
                            .accessibilityAction(named: "Assign to Night") {
                                perform { try store.assignWallpaper(item.url, to: .night, in: mood) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func fourGroups(in mood: Mood) -> some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: HorizonSpacing.sm), GridItem(.flexible(), spacing: HorizonSpacing.sm)],
            spacing: HorizonSpacing.sm
        ) {
            ForEach(DayPartGroup.allCases) { group in
                groupCard(group, in: mood)
            }
        }
    }

    private func groupCard(_ group: DayPartGroup, in mood: Mood) -> some View {
        let representation = store.dayPartRepresentation(for: group, in: mood)
        let assignedCount = group.slots.reduce(0) { $0 + store.wallpaperCount(for: $1, in: mood) }
        let skippedCount = group.slots.filter { !HorizonScheduleDefaults.isSlotEnabled($0.slotID) }.count
        return VStack(alignment: .leading, spacing: HorizonSpacing.sm) {
            HStack {
                Text(group.displayName)
                    .font(HorizonTypography.headline)
                    .foregroundColor(HorizonColors.textPrimary)
                Spacer()
                Text(groupStatus(representation, skippedCount: skippedCount))
                    .font(HorizonTypography.caption)
                    .foregroundColor(HorizonColors.textSecondary)
            }
            groupPreview(representation, group: group, in: mood)
            HStack(spacing: HorizonSpacing.sm) {
                Button("Assign selected") {
                    guard let selectedURL else { return }
                    perform { try store.assignWallpaper(selectedURL, to: group, in: mood) }
                }
                .disabled(selectedURL == nil)
                .buttonStyle(.bordered)
                Button("Remove selected") {
                    guard let selectedURL else { return }
                    perform { try store.unassignWallpaper(selectedURL, from: group, in: mood) }
                }
                .buttonStyle(.bordered)
                .disabled(selectedURL == nil || representation == .usingVibePhotos)
            }
        }
        .padding(HorizonSpacing.md)
        .horizonGlassCard(style: .standard, padding: 0)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            perform { try store.assignWallpaper(url, to: group, in: mood) }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(groupAccessibilityLabel(
            group: group,
            representation: representation,
            assignedCount: assignedCount,
            skippedCount: skippedCount
        ))
        .accessibilityHint("Assigns the selected wallpaper to \(group.displayName), or drop a wallpaper here")
    }

    private func groupPreview(
        _ representation: DayPartGroupRepresentation,
        group: DayPartGroup,
        in mood: Mood
    ) -> some View {
        let urls: [URL]
        let ghosted: Bool
        switch representation {
        case .usingVibePhotos:
            urls = Array(store.allDayWallpapers(in: mood).prefix(4))
            ghosted = true
        case .assigned(let filenames):
            urls = filenames.compactMap { name in
                group.slots.compactMap { store.wallpapers(for: $0, in: mood).first { $0.lastPathComponent == name } }.first
            }
            ghosted = false
        case .mixed:
            urls = group.slots.flatMap { store.wallpapers(for: $0, in: mood) }
            ghosted = false
        }
        return HStack(spacing: HorizonSpacing.xs) {
            if urls.isEmpty {
                Text(representation == .mixed ? "Mixed times" : "Using photos from this Vibe.")
                    .font(HorizonTypography.callout)
                    .foregroundColor(HorizonColors.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            } else {
                ForEach(urls.prefix(4), id: \.path) { url in
                    ShapeMyDayThumbnail(url: url, isSelected: false, compact: true)
                        .opacity(ghosted ? 0.4 : 1)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: 56)
    }

    private func allPeriods(in mood: Mood) -> some View {
        VStack(spacing: HorizonSpacing.sm) {
            ForEach(TimeSlot.allCases) { slot in
                periodRow(slot, in: mood)
            }
        }
        .padding(.top, HorizonSpacing.sm)
    }

    private func periodRow(_ slot: TimeSlot, in mood: Mood) -> some View {
        let assigned = store.wallpapers(for: slot, in: mood)
        let skipped = !HorizonScheduleDefaults.isSlotEnabled(slot.slotID)
        let usingVibe = assigned.isEmpty
        return VStack(alignment: .leading, spacing: HorizonSpacing.sm) {
            HStack {
                Circle()
                    .fill(HorizonColors.colorForSlot(slot.slotID))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(slot.displayName)
                    .font(HorizonTypography.bodyMedium)
                    .foregroundColor(HorizonColors.textPrimary)
                Text(slot.timeRange)
                    .font(HorizonTypography.caption)
                    .foregroundColor(HorizonColors.textTertiary)
                Spacer()
                Text(usingVibe ? "Using photos from this Vibe." : "\(assigned.count) specific photo\(assigned.count == 1 ? "" : "s")")
                    .font(HorizonTypography.caption)
                    .foregroundColor(HorizonColors.textSecondary)
            }
            if !assigned.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HorizonSpacing.xs) {
                        ForEach(assigned, id: \.path) { url in
                            ShapeMyDayThumbnail(url: url, isSelected: selectedURL == url, compact: true)
                                .onTapGesture { selectedURL = url }
                                .contextMenu {
                                    Button("Remove from \(slot.displayName)") {
                                        perform { try store.removeWallpaperAssignment(url, from: slot, in: mood) }
                                    }
                                    Button("Play throughout the day") {
                                        perform { try store.playThroughoutTheDay(url, in: mood) }
                                    }
                                }
                                .accessibilityAction(named: "Remove from \(slot.displayName)") {
                                    perform { try store.removeWallpaperAssignment(url, from: slot, in: mood) }
                                }
                        }
                    }
                }
            }
            HStack(spacing: HorizonSpacing.sm) {
                Button("Assign selected") {
                    guard let selectedURL else { return }
                    perform { try store.addWallpaperAssignment(selectedURL, to: slot, in: mood) }
                }
                .disabled(selectedURL == nil)
                .buttonStyle(.bordered)
                .controlSize(.small)
                Toggle("Skip this time of day", isOn: skipBinding(for: slot.slotID))
                    .font(HorizonTypography.caption)
                    .toggleStyle(.checkbox)
                    .disabled(false)
            }
        }
        .padding(HorizonSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                .fill(HorizonColors.glassFill)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            perform { try store.addWallpaperAssignment(url, to: slot, in: mood) }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(periodAccessibilityLabel(
            slot: slot,
            usingVibe: usingVibe,
            assignedCount: assigned.count,
            skipped: skipped
        ))
    }

    @ViewBuilder
    private func wallpaperMenu(_ url: URL, in mood: Mood) -> some View {
        Button("Play throughout the day") {
            perform { try store.playThroughoutTheDay(url, in: mood) }
        }
        Menu("Assign to…") {
            ForEach(DayPartGroup.allCases) { group in
                Button(group.displayName) {
                    perform { try store.assignWallpaper(url, to: group, in: mood) }
                }
            }
        }
        Menu("Use During…") {
            ForEach(TimeSlot.allCases) { slot in
                Button(slot.displayName) {
                    perform { try store.addWallpaperAssignment(url, to: slot, in: mood) }
                }
            }
        }
    }

    private func skipBinding(for slotID: String) -> Binding<Bool> {
        Binding(
            get: { !HorizonScheduleDefaults.isSlotEnabled(slotID) },
            set: { skip in
                HorizonScheduleDefaults.setSlotEnabled(!skip, slotID: slotID)
                skipRevision += 1
            }
        )
    }

    private func groupStatus(_ representation: DayPartGroupRepresentation, skippedCount: Int) -> String {
        if skippedCount > 0 {
            return skippedCount == 1 ? "1 time skipped" : "\(skippedCount) times skipped"
        }
        switch representation {
        case .usingVibePhotos:
            return "Using Vibe photos"
        case .assigned(let filenames):
            return "\(filenames.count) specific"
        case .mixed:
            return "Mixed"
        }
    }

    private func groupAccessibilityLabel(
        group: DayPartGroup,
        representation: DayPartGroupRepresentation,
        assignedCount: Int,
        skippedCount: Int
    ) -> String {
        let usage: String
        switch representation {
        case .usingVibePhotos:
            usage = "using photos from this Vibe, 0 specific photos"
        case .assigned(let filenames):
            usage = "\(filenames.count) specific photos assigned"
        case .mixed:
            usage = "mixed assignments, \(assignedCount) specific photos"
        }
        let skip = skippedCount > 0 ? ", \(skippedCount) skipped" : ""
        return "\(group.displayName), \(usage)\(skip)"
    }

    private func periodAccessibilityLabel(
        slot: TimeSlot,
        usingVibe: Bool,
        assignedCount: Int,
        skipped: Bool
    ) -> String {
        let usage = usingVibe
            ? "using photos from this Vibe, 0 specific photos"
            : "\(assignedCount) specific photos assigned"
        let skip = skipped ? ", skipped" : ""
        return "\(slot.displayName), \(usage)\(skip). Assign selected wallpaper, or skip this time of day"
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }
}

private struct ShapeMyDayThumbnail: View {
    let url: URL
    var isSelected = false
    var compact = false

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HorizonRadius.sm, style: .continuous)
                .fill(Color.gray.opacity(0.2))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            if isSelected {
                RoundedRectangle(cornerRadius: HorizonRadius.sm, style: .continuous)
                    .strokeBorder(HorizonColors.secondaryAccent, lineWidth: 2)
            }
        }
        .frame(width: compact ? 56 : 88, height: compact ? 56 : 88)
        .clipShape(RoundedRectangle(cornerRadius: HorizonRadius.sm, style: .continuous))
        .onAppear {
            WallpaperPreviewLoader.shared.loadImage(from: url, maxPixelSize: 240) { image in
                self.image = image
            }
        }
        .accessibilityLabel(url.deletingPathExtension().lastPathComponent)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
