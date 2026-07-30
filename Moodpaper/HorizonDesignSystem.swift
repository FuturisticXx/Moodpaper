import SwiftUI

// MARK: - Horizon Design System
// Scoped to Dashboard and detail views that need richer card styles (horizonGlassCard).
// For popover, settings panels, and inline UI use LiquidGlassStyle (liquidGlassCard) instead.

struct HorizonColors {
    // MARK: - Time Slot Colors (Vibrant & Distinctive)
    static let deepNight = Color(red: 0.1, green: 0.1, blue: 0.2)
    static let deepNightAccent = Color(red: 0.2, green: 0.2, blue: 0.4)

    static let dawn = Color(red: 0.8, green: 0.4, blue: 0.7)
    static let dawnAccent = Color(red: 0.9, green: 0.5, blue: 0.8)

    static let sunrise = Color(red: 1.0, green: 0.6, blue: 0.3)
    static let sunriseAccent = Color(red: 1.0, green: 0.7, blue: 0.4)

    static let morning = Color(red: 1.0, green: 0.8, blue: 0.4)
    static let morningAccent = Color(red: 1.0, green: 0.85, blue: 0.5)

    static let midday = Color(red: 0.3, green: 0.7, blue: 1.0)
    static let middayAccent = Color(red: 0.4, green: 0.75, blue: 1.0)

    static let afternoon = Color(red: 0.4, green: 0.6, blue: 0.95)
    static let afternoonAccent = Color(red: 0.5, green: 0.65, blue: 1.0)

    static let goldenHour = Color(red: 1.0, green: 0.7, blue: 0.2)
    static let goldenHourAccent = Color(red: 1.0, green: 0.75, blue: 0.3)

    static let dusk = Color(red: 0.9, green: 0.4, blue: 0.5)
    static let duskAccent = Color(red: 0.95, green: 0.5, blue: 0.6)

    static let evening = Color(red: 0.4, green: 0.3, blue: 0.7)
    static let eveningAccent = Color(red: 0.5, green: 0.4, blue: 0.8)

    // MARK: - Semantic Colors (Adaptive)
    static let primaryAccent = Color.orange
    static let secondaryAccent = Color.blue
    static let tertiaryAccent = Color.purple

    // MARK: - Background Colors (Adaptive)
    static let backgroundPrimary = Color(nsColor: .windowBackgroundColor)
    static let backgroundSecondary = Color(nsColor: .controlBackgroundColor)
    static let backgroundTertiary = Color(nsColor: .textBackgroundColor)

    // MARK: - Text Colors (Adaptive)
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    // MARK: - Glass Effects
    static let glassStroke = Color.primary.opacity(0.1)
    static let glassStrokeHover = Color.primary.opacity(0.2)
    static let glassStrokeFocus = Color.primary.opacity(0.3)
    static let glassFill = Color.primary.opacity(0.03)
    static let glassFillHover = Color.primary.opacity(0.06)

    // Accepts kebab-case slot IDs ("deep-night", "golden-hour") matching the engine convention.
    static func colorForSlot(_ slotId: String) -> Color {
        switch slotId {
        case "deep-night": return deepNight
        case "dawn": return dawn
        case "sunrise": return sunrise
        case "morning": return morning
        case "midday": return midday
        case "afternoon": return afternoon
        case "golden-hour": return goldenHour
        case "dusk": return dusk
        case "evening": return evening
        default: return .gray
        }
    }

    static func accentForSlot(_ slotId: String) -> Color {
        switch slotId {
        case "deep-night": return deepNightAccent
        case "dawn": return dawnAccent
        case "sunrise": return sunriseAccent
        case "morning": return morningAccent
        case "midday": return middayAccent
        case "afternoon": return afternoonAccent
        case "golden-hour": return goldenHourAccent
        case "dusk": return duskAccent
        case "evening": return eveningAccent
        default: return .gray
        }
    }
}

// MARK: - Spacing System (8pt Grid - Apple Design Standard)
// All spacing uses multiples of 8 for consistency and scalability
struct HorizonSpacing {
    static let xs: CGFloat = 4      // Tight spacing, icon padding
    static let sm: CGFloat = 8      // Compact spacing, button padding
    static let md: CGFloat = 16     // Standard spacing, card padding
    static let lg: CGFloat = 24     // Comfortable spacing, section padding
    static let xl: CGFloat = 32     // Generous spacing, large gaps
    static let xxl: CGFloat = 40    // Very generous spacing
    static let xxxl: CGFloat = 48  // Maximum spacing, major breaks
}

// MARK: - Corner Radius
struct HorizonRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 10
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
}

// MARK: - Typography (SF Pro Hierarchy - Apple Design Standard)
// Uses system font which automatically resolves to SF Pro on macOS
struct HorizonTypography {
    static let largeTitle = Font.system(size: 28, weight: .bold)
    static let title1 = Font.system(size: 22, weight: .semibold)
    static let title2 = Font.system(size: 18, weight: .semibold)
    static let title3 = Font.system(size: 16, weight: .semibold)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13, weight: .regular)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    static let callout = Font.system(size: 12, weight: .regular)
    static let caption = Font.system(size: 11, weight: .regular)
    static let caption2 = Font.system(size: 10, weight: .regular)

    // Line heights for text rendering (multiples of 8 for vertical rhythm)
    static let lineHeightLargeTitle: CGFloat = 36
    static let lineHeightTitle1: CGFloat = 28
    static let lineHeightTitle2: CGFloat = 24
    static let lineHeightTitle3: CGFloat = 22
    static let lineHeightHeadline: CGFloat = 20
    static let lineHeightBody: CGFloat = 18
    static let lineHeightCallout: CGFloat = 16
    static let lineHeightCaption: CGFloat = 14
    static let lineHeightCaption2: CGFloat = 12
}

// MARK: - Glass Card Modifier
struct HorizonGlassCard: ViewModifier {
    let style: GlassStyle
    let cornerRadius: CGFloat
    let padding: CGFloat
    var glowColor: Color? = nil
    @State private var isHovered = false

    enum GlassStyle {
        case subtle      // Ultra-thin material, minimal stroke
        case standard    // Thin material, standard stroke
        case elevated    // Ultra-thin material, prominent stroke, shadow
        case vibrant     // Vibrant material with color tint
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundMaterial)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            }
            .shadow(
                color: shadowColor,
                radius: shadowRadius,
                y: shadowY
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .shadow(color: isHovered ? (glowColor ?? .clear).opacity(0.5) : .clear, radius: 36, y: 8)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private var backgroundMaterial: AnyShapeStyle {
        switch style {
        case .subtle:
            return AnyShapeStyle(.ultraThinMaterial)
        case .standard:
            return AnyShapeStyle(.thinMaterial)
        case .elevated:
            return AnyShapeStyle(.ultraThinMaterial)
        case .vibrant:
            return AnyShapeStyle(.regularMaterial)
        }
    }

    private var strokeColor: Color {
        if isHovered {
            return HorizonColors.glassStrokeHover
        }
        switch style {
        case .subtle:
            return HorizonColors.glassStroke.opacity(0.5)
        case .standard:
            return HorizonColors.glassStroke
        case .elevated:
            return HorizonColors.glassStrokeHover
        case .vibrant:
            return HorizonColors.glassStrokeFocus
        }
    }

    private var shadowColor: Color {
        switch style {
        case .subtle, .standard:
            return Color.black.opacity(0.08)
        case .elevated:
            return Color.black.opacity(0.15)
        case .vibrant:
            return Color.black.opacity(0.12)
        }
    }

    private var shadowRadius: CGFloat {
        switch style {
        case .subtle:
            return 4
        case .standard:
            return 8
        case .elevated:
            return 16
        case .vibrant:
            return 12
        }
    }

    private var shadowY: CGFloat {
        switch style {
        case .subtle:
            return 2
        case .standard:
            return 4
        case .elevated:
            return 8
        case .vibrant:
            return 6
        }
    }
}

// MARK: - Colored Badge
struct HorizonBadge: View {
    let text: String
    let color: Color
    let size: BadgeSize

    enum BadgeSize {
        case small, medium, large

        var font: Font {
            switch self {
            case .small: return HorizonTypography.caption2
            case .medium: return HorizonTypography.caption
            case .large: return HorizonTypography.callout
            }
        }

        var padding: EdgeInsets {
            switch self {
            case .small: return EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6)
            case .medium: return EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            case .large: return EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            }
        }
    }

    var body: some View {
        Text(text)
            .font(size.font)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(size.padding)
            .background(
                Capsule()
                    .fill(color.gradient)
            )
            .shadow(color: color.opacity(0.3), radius: 4, y: 2)
    }
}

// MARK: - Icon Container
struct HorizonIconContainer: View {
    let icon: String
    let color: Color
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(color.opacity(0.15).gradient)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                        .strokeBorder(color.opacity(0.3), lineWidth: 1)
                }

            Image(systemName: icon)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(color.gradient)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - View Extensions
extension View {
    func horizonGlassCard(
        style: HorizonGlassCard.GlassStyle = .standard,
        cornerRadius: CGFloat = HorizonRadius.lg,
        padding: CGFloat = HorizonSpacing.lg,
        glowColor: Color? = nil
    ) -> some View {
        modifier(HorizonGlassCard(style: style, cornerRadius: cornerRadius, padding: padding, glowColor: glowColor))
    }

    func horizonCardBackground(color: Color = HorizonColors.glassFill) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: HorizonRadius.lg, style: .continuous)
                .fill(color)
        )
    }
}

// MARK: - Button Styles
struct HorizonPrimaryButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HorizonTypography.bodyMedium)
            .foregroundColor(.white)
            .padding(.horizontal, HorizonSpacing.lg)
            .padding(.vertical, HorizonSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                    .fill(color.gradient)
            )
            .shadow(color: color.opacity(0.4), radius: 8, y: 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct HorizonSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(HorizonTypography.bodyMedium)
            .foregroundColor(HorizonColors.textPrimary)
            .padding(.horizontal, HorizonSpacing.sm)
            .padding(.vertical, HorizonSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay {
                RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                    .strokeBorder(HorizonColors.glassStroke, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Navigation Components

struct HorizonSidebarItem: View {
    let icon: String
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HorizonSpacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? HorizonColors.primaryAccent : HorizonColors.textSecondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(HorizonTypography.bodyMedium)
                        .foregroundStyle(isSelected ? HorizonColors.textPrimary : HorizonColors.textSecondary)

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(HorizonTypography.caption)
                            .foregroundStyle(HorizonColors.textTertiary)
                    }
                }

                Spacer()
            }
            .padding(.vertical, HorizonSpacing.xs)
            .padding(.horizontal, HorizonSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HorizonRadius.sm, style: .continuous)
                    .fill(isSelected ? HorizonColors.glassFill : Color.clear)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: HorizonRadius.sm, style: .continuous)
                        .strokeBorder(HorizonColors.primaryAccent, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct HorizonTabBarItem: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? HorizonColors.primaryAccent : HorizonColors.textSecondary)

                Text(title)
                    .font(isSelected ? HorizonTypography.body : HorizonTypography.bodyMedium)
                    .foregroundStyle(isSelected ? HorizonColors.textPrimary : HorizonColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HorizonSpacing.xs)
            .padding(.horizontal, HorizonSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HorizonRadius.sm, style: .continuous)
                    .fill(isSelected ? HorizonColors.glassFill : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Input Components

struct HorizonTextField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused: Binding<Bool>?

    var body: some View {
        TextField(placeholder, text: $text)
            .font(HorizonTypography.body)
            .foregroundColor(HorizonColors.textPrimary)
            .padding(.vertical, HorizonSpacing.xs)
            .padding(.horizontal, HorizonSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay {
                RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                    .strokeBorder(
                        isFocused?.wrappedValue == true ? HorizonColors.glassStrokeFocus : HorizonColors.glassStroke,
                        lineWidth: 1
                    )
            }
            .animation(.easeInOut(duration: 0.2), value: isFocused?.wrappedValue)
    }
}

struct HorizonSecureField: View {
    let placeholder: String
    @Binding var text: String
    var isFocused: Binding<Bool>?

    var body: some View {
        SecureField(placeholder, text: $text)
            .font(HorizonTypography.body)
            .foregroundColor(HorizonColors.textPrimary)
            .padding(.vertical, HorizonSpacing.xs)
            .padding(.horizontal, HorizonSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay {
                RoundedRectangle(cornerRadius: HorizonRadius.md, style: .continuous)
                    .strokeBorder(
                        isFocused?.wrappedValue == true ? HorizonColors.glassStrokeFocus : HorizonColors.glassStroke,
                        lineWidth: 1
                    )
            }
            .animation(.easeInOut(duration: 0.2), value: isFocused?.wrappedValue)
    }
}

// MARK: - Modal Components

struct HorizonModal<Content: View>: View {
    let isPresented: Binding<Bool>
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            if isPresented.wrappedValue {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isPresented.wrappedValue = false
                        }
                    }

                VStack(spacing: 0) {
                    if let title = title {
                        HStack {
                            Text(title)
                                .font(HorizonTypography.title3)
                                .foregroundStyle(HorizonColors.textPrimary)
                            Spacer()
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isPresented.wrappedValue = false
                                }
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(HorizonColors.textSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, HorizonSpacing.lg)
                        .padding(.vertical, HorizonSpacing.md)
                        .background(.ultraThinMaterial)
                    }

                    content
                        .padding(HorizonSpacing.lg)
                }
                .background(
                    RoundedRectangle(cornerRadius: HorizonRadius.xl, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: HorizonRadius.xl, style: .continuous)
                        .strokeBorder(HorizonColors.glassStrokeFocus, lineWidth: 1.5)
                }
                .shadow(color: .black.opacity(0.2), radius: 24, y: 12)
                .padding(HorizonSpacing.lg)
                .frame(maxWidth: 600)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isPresented.wrappedValue)
    }
}
