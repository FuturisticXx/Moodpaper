import SwiftUI
import CoreLocation
internal import Combine

/// Single source of truth for onboarding strings.
/// Tested in `MoodpaperTests/OnboardingViewTests.swift`.
enum OnboardingCopy {
    static let step1Eyebrow = "WELCOME · 1 OF 4"
    static let step1Title = "You decide the vibe."
    static let step1Body = "Moodpaper doesn't pick for you. Assign your own photos to each part of the day, then switch your whole desktop personality in one click."
    static let step1Cta = "Continue"

    static let step2Eyebrow = "RHYTHM · 2 OF 4"
    static let step2Title = "Choose how often Moodpaper changes."
    static let step2Body = "Fewer changes for a calmer desktop. More changes for variety. You can adjust this anytime."
    static let step2Cta = "Continue"

    static let step3Eyebrow = "OPTIONAL · 3 OF 4"
    static let step3Title = "Match your local daylight."
    static let step3Body = "Moodpaper uses your location to time sunrise, sunset, and each part of the day accurately."
    static let step3PrimaryCta = "Use My Location"
    static let step3SecondaryCta = "Skip for now"
    static let step3ContinueCta = "Continue"

    static let step4Eyebrow = "LAST STEP · 4 OF 4"
    static let step4Title = "Add your first mood."
    static let step4Body = "Everyday is your starter mood, empty and ready. Import a few photos for each part of the day, or add more moods anytime from Settings."
    static let step4PrimaryCta = "Add Your First Mood"
    static let step4SecondaryCta = "I'll do this later"

    static let skipLink = "Skip"
    static let backLink = "Back"
}

private enum OnboardingStep: Int, CaseIterable {
    case value = 0
    case rhythm = 1
    case location = 2
    case moods = 3
}

// MARK: - Root view

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var currentStep: OnboardingStep = .value
    @StateObject private var locationManager = LocationPermissionManager()

    var body: some View {
        ZStack {
            // Layer 1: full-bleed cycling wallpaper hero
            HeroWallpaperLayer(slotID: heroSlot)

            // Layer 2: legibility gradient. Clear at top, black at bottom.
            LinearGradient(
                colors: [
                    .black.opacity(0.0),
                    .black.opacity(0.0),
                    .black.opacity(0.35),
                    .black.opacity(0.78)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            // Layer 3: top chrome (page dots + skip)
            VStack {
                HStack {
                    PageDots(current: currentStep.rawValue, total: OnboardingStep.allCases.count)
                    Spacer()
                    if currentStep == .value {
                        TextLinkButton(title: OnboardingCopy.skipLink) {
                            completeOnboarding()
                        }
                    } else {
                        TextLinkButton(title: OnboardingCopy.backLink) {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                currentStep = OnboardingStep(rawValue: currentStep.rawValue - 1) ?? .value
                            }
                        }
                    }
                }
                .padding(.top, 22)
                .padding(.horizontal, 32)

                Spacer()
            }

            // Layer 4: bottom-anchored floating glass content card
            VStack {
                Spacer()
                HStack {
                    contentCard
                        .frame(maxWidth: 560, alignment: .leading)
                    Spacer()
                }
                .padding(.horizontal, 44)
                .padding(.bottom, 44)
            }
        }
        .frame(width: 1060, height: 720)
        .background(Color.black)
    }

    @ViewBuilder
    private var contentCard: some View {
        switch currentStep {
        case .value:
            ValueCard(onContinue: { advance() })
        case .rhythm:
            RhythmCard(onContinue: { advance() })
        case .location:
            LocationCard(
                locationManager: locationManager,
                onPrimary: {
                    locationManager.requestPermission()
                    advance()
                },
                onSkip: { advance() }
            )
        case .moods:
            FirstMoodCard(
                onAddMood: { completeOnboardingAndOpenLibrary() },
                onLater: { completeOnboarding() }
            )
        }
    }

    /// One curated wallpaper per step. No cycling.
    private var heroSlot: String {
        switch currentStep {
        case .value:    return "sunrise"
        case .rhythm:   return "golden-hour"
        case .location: return "dusk"
        case .moods:    return "afternoon"
        }
    }

    private func advance() {
        if let next = OnboardingStep(rawValue: currentStep.rawValue + 1) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                currentStep = next
            }
        } else {
            completeOnboarding()
        }
    }

    /// Closes the onboarding window. Persistence (the `hasCompletedOnboarding`
    /// flag and the `onboardingCompleted` analytics event) is handled by the
    /// `NSWindow.willCloseNotification` observer in `AppDelegate.showOnboarding`,
    /// so closing via the red traffic light produces the same effect.
    private func completeOnboarding() {
        withAnimation { isPresented = false }
    }

    /// Finishes onboarding and lands the user directly in the Library, where
    /// the starter mood's slots are waiting to be filled. The primary path
    /// out of onboarding should end in an action, not a blank menu bar.
    private func completeOnboardingAndOpenLibrary() {
        NotificationCenter.default.post(name: .navigateToUserWallpapers, object: nil)
        completeOnboarding()
        openWindow(id: "settings")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            NSApplication.shared.windows
                .first { $0.identifier?.rawValue == "settings" || $0.identifier?.rawValue.hasPrefix("settings-") == true }
                .map { $0.makeKeyAndOrderFront(nil) }
        }
    }
}

// MARK: - Hero wallpaper

private struct HeroWallpaperLayer: View {
    let slotID: String

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Slot-tinted gradient hero. Placeholder art until the
                // Moodpaper onboarding redesign (B4) lands.
                LinearGradient(
                    colors: [
                        HorizonColors.colorForSlot(slotID),
                        HorizonColors.accentForSlot(slotID).opacity(0.7),
                        .black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Top chrome

private struct PageDots: View {
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { idx in
                Capsule()
                    .fill(idx == current ? .white : .white.opacity(0.3))
                    .frame(width: idx == current ? 22 : 8, height: 4)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: current)
            }
        }
    }
}

private struct TextLinkButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(.white.opacity(0.10))
                )
                .overlay(
                    Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Floating content cards

private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(36)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.08), .white.opacity(0.02)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 30, y: 18)
    }
}

private struct CardEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.65))
    }
}

private struct CardTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 38, weight: .semibold))
            .tracking(-0.4)
            .foregroundStyle(.white)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CardBody: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .regular))
            .lineSpacing(4)
            .foregroundStyle(.white.opacity(0.78))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PrimaryCTAButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(
                LinearGradient(
                    colors: [.white, .white.opacity(0.86)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .shadow(color: .white.opacity(0.18), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
    }
}

private struct SecondaryGhostButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.20), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Step cards

private struct ValueCard: View {
    let onContinue: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 22) {
                CardEyebrow(text: OnboardingCopy.step1Eyebrow)
                CardTitle(text: OnboardingCopy.step1Title)
                CardBody(text: OnboardingCopy.step1Body)

                HStack(spacing: 12) {
                    PrimaryCTAButton(title: OnboardingCopy.step1Cta, action: onContinue)
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct RhythmCard: View {
    let onContinue: () -> Void
    @AppStorage(HorizonScheduleDefaults.wallpapersPerDayKey) private var wallpapersPerDay: Double = 8

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 22) {
                CardEyebrow(text: OnboardingCopy.step2Eyebrow)
                CardTitle(text: OnboardingCopy.step2Title)
                CardBody(text: OnboardingCopy.step2Body)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(Int(wallpapersPerDay))")
                            .font(.system(size: 44, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("per day")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.white.opacity(0.6))
                        Spacer()
                        Text("about every \(hoursPerChangeText)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    Slider(value: $wallpapersPerDay, in: 3...24, step: 1)
                        .tint(.white)

                    HStack {
                        Text("CALM")
                        Spacer()
                        Text("VARIED")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(.white.opacity(0.45))
                }

                HStack(spacing: 12) {
                    PrimaryCTAButton(title: OnboardingCopy.step2Cta, action: onContinue)
                }
                .padding(.top, 4)
            }
        }
    }

    private var hoursPerChangeText: String {
        let hours = 24.0 / max(1, wallpapersPerDay)
        if hours >= 1 {
            let rounded = Int(hours.rounded())
            return rounded == 1 ? "1 hour" : "\(rounded) hours"
        } else {
            let mins = Int((hours * 60).rounded())
            return "\(mins) minutes"
        }
    }
}

private struct LocationCard: View {
    @ObservedObject var locationManager: LocationPermissionManager
    let onPrimary: () -> Void
    let onSkip: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 22) {
                CardEyebrow(text: OnboardingCopy.step3Eyebrow)
                CardTitle(text: OnboardingCopy.step3Title)
                CardBody(text: OnboardingCopy.step3Body)

                if let status = subtleStatus {
                    HStack(spacing: 8) {
                        Image(systemName: status.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(status.tint)
                        Text(status.text)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                HStack(spacing: 12) {
                    PrimaryCTAButton(
                        title: primaryTitle,
                        icon: "location.fill",
                        action: handlePrimary
                    )
                    SecondaryGhostButton(title: OnboardingCopy.step3SecondaryCta, action: onSkip)
                }
                .padding(.top, 4)
            }
        }
    }

    private var primaryTitle: String {
        switch locationManager.authorizationStatus {
        case .denied, .restricted: return "Open System Settings"
        case .authorizedAlways, .authorizedWhenInUse: return OnboardingCopy.step3ContinueCta
        default: return OnboardingCopy.step3PrimaryCta
        }
    }

    private struct StatusLine {
        let symbol: String
        let tint: Color
        let text: String
    }

    private var subtleStatus: StatusLine? {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return StatusLine(
                symbol: "checkmark.circle.fill",
                tint: .green,
                text: "Already on for Moodpaper"
            )
        case .denied, .restricted:
            return StatusLine(
                symbol: "exclamationmark.circle.fill",
                tint: .orange,
                text: "Currently off in System Settings"
            )
        default:
            return nil
        }
    }

    private func handlePrimary() {
        switch locationManager.authorizationStatus {
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                NSWorkspace.shared.open(url)
            }
            onSkip()
        default:
            onPrimary()
        }
    }
}

private struct FirstMoodCard: View {
    let onAddMood: () -> Void
    let onLater: () -> Void

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 22) {
                CardEyebrow(text: OnboardingCopy.step4Eyebrow)
                CardTitle(text: OnboardingCopy.step4Title)
                CardBody(text: OnboardingCopy.step4Body)

                HStack(spacing: 12) {
                    PrimaryCTAButton(title: OnboardingCopy.step4PrimaryCta, icon: "plus", action: onAddMood)
                    SecondaryGhostButton(title: OnboardingCopy.step4SecondaryCta, action: onLater)
                }
                .padding(.top, 4)
            }
        }
    }
}

// MARK: - Permission manager (unchanged)

@MainActor
class LocationPermissionManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private let locationManager = CLLocationManager()
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        locationManager.delegate = self
        authorizationStatus = LocationService.shared.authorizationStatus

        LocationService.shared.$authorizationStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.authorizationStatus = status
                self?.startSharedLocationIfAuthorized()
            }
            .store(in: &cancellables)

        if isAuthorized(authorizationStatus) {
            LocationService.shared.startUpdatingLocation()
        }
    }

    func requestPermission() {
        UserDefaults.standard.set(true, forKey: "useDeviceLocation")
        LocationService.shared.startUpdatingLocation(requestPermissionIfNeeded: true)
        authorizationStatus = locationManager.authorizationStatus
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        startSharedLocationIfAuthorized()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        authorizationStatus = status
        startSharedLocationIfAuthorized()
    }

    private func startSharedLocationIfAuthorized() {
        if isAuthorized(authorizationStatus) {
            LocationService.shared.startUpdatingLocation()
        }
    }

    private func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
        status == .authorizedAlways || status == .authorized
    }
}
