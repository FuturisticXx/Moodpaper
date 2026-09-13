import SwiftUI
import AppKit

// Wallpapers is one grid of the active Vibe's photos. Import, preview,
// Use Now, Play Throughout the Day, and Use During… live in UserLibraryView.
struct LibraryView: View {
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: HorizonSpacing.lg) {
                // Title
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(HorizonColors.primaryAccent.gradient)
                        .accessibilityHidden(true)
                    Text("Wallpapers")
                        .font(HorizonTypography.title2)
                        .foregroundColor(HorizonColors.textPrimary)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)

                Spacer(minLength: HorizonSpacing.lg)

                // Search
                HStack(spacing: HorizonSpacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(HorizonColors.textSecondary)
                        .font(HorizonTypography.body)
                        .accessibilityHidden(true)
                    TextField("Search wallpapers...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(HorizonTypography.body)
                }
                .padding(.horizontal, HorizonSpacing.md)
                .padding(.vertical, HorizonSpacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                        .strokeBorder(HorizonColors.glassStroke, lineWidth: 1)
                }
                .frame(minWidth: 160, idealWidth: 260, maxWidth: 260)
                .layoutPriority(1)
            }
            .padding(.horizontal, HorizonSpacing.xxxl)
            .padding(.top, HorizonSpacing.xl)
            .padding(.bottom, HorizonSpacing.md)

            UserLibraryView(searchText: searchText)
                .environmentObject(wallpaperManager)
        }
        .background(.clear)
        .onAppear {
            AnalyticsManager.shared.log(.libraryOpened)
        }
    }
}
