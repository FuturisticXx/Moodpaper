import SwiftUI

/// The onboarding "day dial": a horizontal arc of the day the user scrubs to
/// watch the backdrop change mood in real time. This is onboarding's core
/// interaction — pointer-precision scrubbing is the desktop-native answer to
/// "turn a dial and watch the desktop respond."
///
/// Pure position→slot math lives in static helpers so it stays testable
/// without rendering the view.
struct OnboardingDayDial: View {
    /// 0.0 = start of the day's slot sequence, 1.0 = end.
    @Binding var dayPosition: Double
    let slotIDs: [String]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    private var currentIndex: Int {
        Self.slotIndex(for: dayPosition, slotCount: slotIDs.count)
    }

    var currentSlotID: String {
        slotIDs.indices.contains(currentIndex) ? slotIDs[currentIndex] : "morning"
    }

    // MARK: - Position math (tested in OnboardingDayDialTests)

    /// Maps a continuous 0...1 day position onto a slot index. Equal-width
    /// bands; the final band absorbs position 1.0 exactly.
    nonisolated static func slotIndex(for position: Double, slotCount: Int) -> Int {
        guard slotCount > 0 else { return 0 }
        let clamped = min(max(position, 0), 1)
        return min(Int(clamped * Double(slotCount)), slotCount - 1)
    }

    /// Center position of a slot's band, for snapping and keyboard stepping.
    nonisolated static func position(forSlotIndex index: Int, slotCount: Int) -> Double {
        guard slotCount > 0 else { return 0 }
        let clamped = min(max(index, 0), slotCount - 1)
        return (Double(clamped) + 0.5) / Double(slotCount)
    }

    /// SF Symbol for the thumb, tracking the sun across the day.
    nonisolated static func thumbSymbol(forSlotID slotID: String) -> String {
        switch slotID {
        case "deep-night", "evening": return "moon.stars.fill"
        case "dawn", "sunrise":       return "sun.horizon.fill"
        case "morning":               return "sun.min.fill"
        case "midday", "afternoon":   return "sun.max.fill"
        case "golden-hour", "dusk":   return "sun.horizon.fill"
        default:                      return "sun.max.fill"
        }
    }

    nonisolated static func displayName(forSlotID slotID: String) -> String {
        TimeSlot.allCases.first { $0.slotID == slotID }?.displayName ?? slotID
    }

    // MARK: - Body

    /// Half the focus ring, so the thumb at either extreme still draws inside
    /// the card. Without the inset the thumb was sliced in half against the
    /// card's left edge at Deep Night (seen in live verification).
    private static let thumbInset: CGFloat = 21

    /// Screen x for a 0...1 day position, in the dial's own coordinate space.
    private static func x(for position: Double, width: CGFloat) -> CGFloat {
        let travel = max(width - thumbInset * 2, 1)
        return thumbInset + CGFloat(min(max(position, 0), 1)) * travel
    }

    /// Inverse of `x(for:width:)`, for turning a drag location into a position.
    private static func position(forX x: CGFloat, width: CGFloat) -> Double {
        let travel = max(width - thumbInset * 2, 1)
        return Double((x - thumbInset) / travel)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                track(width: width)
                ticks(width: width)
                thumb(width: width)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isFocused = true
                        setPosition(Self.position(forX: value.location.x, width: width))
                    }
            )
        }
        .frame(height: 44)
        .focusable(true)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            stepSlot(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            stepSlot(by: 1)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("Time of day")
        .accessibilityValue(Self.displayName(forSlotID: currentSlotID))
        .accessibilityAdjustableAction { direction in
            stepSlot(by: direction == .increment ? 1 : -1)
        }
    }

    /// The track sits on top of whatever photograph is behind the card, so it
    /// carries its own dark bed. A plain white-alpha capsule disappeared
    /// entirely over the bright morning frame during live verification.
    private func track(width: CGFloat) -> some View {
        Capsule()
            .fill(.black.opacity(0.28))
            .frame(height: 5)
            .overlay(
                Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1)
            )
    }

    private func ticks(width: CGFloat) -> some View {
        ForEach(Array(slotIDs.enumerated()), id: \.element) { index, slotID in
            Circle()
                .fill(index == currentIndex ? .white : .white.opacity(0.45))
                .frame(width: index == currentIndex ? 8 : 5, height: index == currentIndex ? 8 : 5)
                .position(
                    x: Self.x(
                        for: Self.position(forSlotIndex: index, slotCount: slotIDs.count),
                        width: width
                    ),
                    y: 22
                )
                .animation(
                    reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8),
                    value: currentIndex
                )
                .accessibilityHidden(true)
        }
    }

    private func thumb(width: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            Image(systemName: Self.thumbSymbol(forSlotID: currentSlotID))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.black)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .position(x: Self.x(for: dayPosition, width: width), y: 22)
        .overlay(alignment: .center) {
            if isFocused {
                Circle()
                    .strokeBorder(.white.opacity(0.6), lineWidth: 2)
                    .frame(width: 42, height: 42)
                    .position(x: Self.x(for: dayPosition, width: width), y: 22)
            }
        }
    }

    private func setPosition(_ raw: CGFloat) {
        dayPosition = min(max(Double(raw), 0), 1)
    }

    private func stepSlot(by delta: Int) {
        let next = currentIndex + delta
        guard slotIDs.indices.contains(next) else { return }
        let target = Self.position(forSlotIndex: next, slotCount: slotIDs.count)
        if reduceMotion {
            dayPosition = target
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                dayPosition = target
            }
        }
    }
}

// The live backdrop moved to OnboardingBackdrop.swift when the generated
// gradients were replaced with bundled photography, which needs a two-tier
// image store this file has no business owning.
