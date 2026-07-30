import XCTest
@testable import Moodpaper

final class OnboardingViewTests: XCTestCase {

    func test_step1Copy_matchesSpec() {
        XCTAssertEqual(OnboardingCopy.step1Eyebrow, "WELCOME · 1 OF 4")
        XCTAssertEqual(OnboardingCopy.step1Title, "You decide the vibe.")
        XCTAssertEqual(
            OnboardingCopy.step1Body,
            "Moodpaper doesn't pick for you. Assign your own photos to each part of the day, then switch your whole desktop personality in one click."
        )
    }

    func test_step2Copy_matchesSpec() {
        XCTAssertEqual(OnboardingCopy.step2Eyebrow, "RHYTHM · 2 OF 4")
        XCTAssertEqual(OnboardingCopy.step2Title, "Choose how often Moodpaper changes.")
        XCTAssertEqual(
            OnboardingCopy.step2Body,
            "Fewer changes for a calmer desktop. More changes for variety. You can adjust this anytime."
        )
    }

    func test_step3Copy_matchesSpec() {
        XCTAssertEqual(OnboardingCopy.step3Eyebrow, "OPTIONAL · 3 OF 4")
        XCTAssertEqual(OnboardingCopy.step3Title, "Match your local daylight.")
        XCTAssertEqual(
            OnboardingCopy.step3Body,
            "Moodpaper uses your location to time sunrise, sunset, and each part of the day accurately."
        )
    }

    func test_step4Copy_matchesSpec() {
        XCTAssertEqual(OnboardingCopy.step4Eyebrow, "LAST STEP · 4 OF 4")
        XCTAssertEqual(OnboardingCopy.step4Title, "Add your first mood.")
        XCTAssertEqual(
            OnboardingCopy.step4Body,
            "Everyday is your starter mood, empty and ready. Import a few photos for each part of the day, or add more moods anytime from Settings."
        )
        XCTAssertEqual(OnboardingCopy.step4PrimaryCta, "Add Your First Mood")
        XCTAssertEqual(OnboardingCopy.step4SecondaryCta, "I'll do this later")
    }

    func test_allOnboardingCopy_containsNoEmDashes() {
        let allStrings: [String] = [
            OnboardingCopy.step1Eyebrow, OnboardingCopy.step1Title, OnboardingCopy.step1Body,
            OnboardingCopy.step2Eyebrow, OnboardingCopy.step2Title, OnboardingCopy.step2Body,
            OnboardingCopy.step3Eyebrow, OnboardingCopy.step3Title, OnboardingCopy.step3Body,
            OnboardingCopy.step4Eyebrow, OnboardingCopy.step4Title, OnboardingCopy.step4Body,
            OnboardingCopy.step1Cta, OnboardingCopy.step2Cta,
            OnboardingCopy.step3PrimaryCta, OnboardingCopy.step3SecondaryCta, OnboardingCopy.step3ContinueCta,
            OnboardingCopy.step4PrimaryCta, OnboardingCopy.step4SecondaryCta,
            OnboardingCopy.skipLink, OnboardingCopy.backLink
        ]
        for s in allStrings {
            XCTAssertFalse(s.contains("\u{2014}"), "String must not contain em dash: \(s)")
        }
    }
}
