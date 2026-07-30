import SwiftUI

// Canonical glass system for the menu bar popover, settings panels, and inline UI.
// Use liquidGlassCard() / LiquidGlassActionButtonStyle for all new UI.
// HorizonDesignSystem is scoped to Dashboard and detail views that need richer card styles.

enum LiquidGlassTokens {
    static let radiusSM: CGFloat = 8
    static let radiusMD: CGFloat = 10
    static let radiusLG: CGFloat = 12

    static let strokeSubtle = Color.white.opacity(0.08)
    static let strokeDefault = Color.white.opacity(0.12)
    static let strokeFocus = Color.white.opacity(0.20)

    static let shadow1 = Color.black.opacity(0.14)
    static let shadow2 = Color.black.opacity(0.20)

    static let liftY: CGFloat = -1
}

struct LiquidGlassCard: ViewModifier {
    let elevated: Bool
    let cornerRadius: CGFloat
    let hovered: Bool

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(elevated ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.thinMaterial))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        hovered ? LiquidGlassTokens.strokeFocus :
                            (elevated ? LiquidGlassTokens.strokeDefault : LiquidGlassTokens.strokeSubtle),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: elevated ? LiquidGlassTokens.shadow2 : LiquidGlassTokens.shadow1,
                radius: elevated ? 10 : 6,
                y: elevated ? 4 : 2
            )
    }
}

extension View {
    func liquidGlassCard(
        elevated: Bool = false,
        cornerRadius: CGFloat = LiquidGlassTokens.radiusLG,
        hovered: Bool = false
    ) -> some View {
        modifier(LiquidGlassCard(elevated: elevated, cornerRadius: cornerRadius, hovered: hovered))
    }
}

struct LiquidGlassActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusMD, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LiquidGlassTokens.radiusMD, style: .continuous)
                    .strokeBorder(
                        LiquidGlassTokens.strokeDefault,
                        lineWidth: 1
                    )
            )
            .shadow(color: LiquidGlassTokens.shadow1, radius: 6, y: 2)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct LiquidGlassHoverRow: ViewModifier {
    let isHovered: Bool
    let cornerRadius: CGFloat
    let glowColor: Color?

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.04 : 0.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isHovered ? LiquidGlassTokens.strokeDefault : .clear,
                        lineWidth: 1
                    )
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
    }
}

extension View {
    func liquidGlassHoverRow(
        isHovered: Bool,
        cornerRadius: CGFloat = LiquidGlassTokens.radiusMD,
        glowColor: Color? = nil
    ) -> some View {
        modifier(LiquidGlassHoverRow(isHovered: isHovered, cornerRadius: cornerRadius, glowColor: glowColor))
    }
}
