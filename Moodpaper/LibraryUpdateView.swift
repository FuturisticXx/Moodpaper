import SwiftUI

/// One-time prompt to move the wallpaper library to Catalog v2. Appearing is
/// not consent: nothing happens until the user chooses Update Library, and
/// Not Now leaves the library exactly as it is.
struct LibraryUpdateView: View {
    @ObservedObject private var store = MoodStore.shared
    let onDismiss: () -> Void
    @State private var failureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: HorizonSpacing.md) {
            HStack(spacing: HorizonSpacing.sm) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Update Your Wallpaper Library")
                    .font(HorizonTypography.title3)
                    .foregroundColor(HorizonColors.textPrimary)
            }

            Text("Moodpaper needs to update how it stores your wallpapers so one photo can belong to several Vibes. All of your wallpapers and Vibes are kept, and a backup is made first. You can do this now or later.")
                .font(HorizonTypography.body)
                .foregroundColor(HorizonColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let failureMessage {
                Text(failureMessage)
                    .font(HorizonTypography.callout)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Update failed. \(failureMessage)")
            }

            HStack {
                Spacer()
                if store.isUpdatingLibrary {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating…")
                        .font(HorizonTypography.callout)
                        .foregroundColor(HorizonColors.textSecondary)
                } else {
                    Button("Not Now") {
                        onDismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button(failureMessage == nil ? "Update Library" : "Try Again") {
                        update()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(HorizonSpacing.lg)
        .frame(width: 440)
    }

    private func update() {
        failureMessage = nil
        Task { @MainActor in
            do {
                try await store.updateLibrary()
                onDismiss()
            } catch {
                failureMessage = error.localizedDescription
            }
        }
    }
}
