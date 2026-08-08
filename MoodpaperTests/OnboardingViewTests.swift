import XCTest
@testable import Moodpaper

final class OnboardingViewTests: XCTestCase {

    func test_coverCopy_matchesSpec() {
        XCTAssertEqual(OnboardingCopy.coverEyebrow, "MOODPAPER")
        XCTAssertEqual(OnboardingCopy.coverTitle, "Your desktop has moods.")
        XCTAssertEqual(
            OnboardingCopy.coverBody,
            "Wallpapers that drift through your day, from first light to deep night. You choose the feeling."
        )
        XCTAssertEqual(OnboardingCopy.coverCta, "Begin")
    }

    func test_dialCopy_matchesSpec() {
        XCTAssertEqual(OnboardingCopy.dialEyebrow, "TURN THE DAY · 1 OF 2")
        XCTAssertEqual(OnboardingCopy.dialTitle, "Drag the sun across your day.")
        XCTAssertEqual(
            OnboardingCopy.dialBody,
            "Every part of the day gets its own wallpaper. Drag to watch the light change."
        )
        XCTAssertEqual(OnboardingCopy.dialLocationPrompt, "Time these to your actual sunrise?")
        XCTAssertEqual(OnboardingCopy.dialLocationCta, "Use My Location")
        XCTAssertEqual(OnboardingCopy.dialLocationSkip, "Not now")
        XCTAssertEqual(
            OnboardingCopy.dialLocationFallback,
            "Using standard times. You can refine with location anytime in Settings."
        )
    }

    func test_nameCopy_matchesSpec() {
        XCTAssertEqual(OnboardingCopy.nameEyebrow, "MAKE IT REAL · 2 OF 2")
        XCTAssertEqual(OnboardingCopy.nameTitle, "Name this feeling.")
        XCTAssertEqual(
            OnboardingCopy.nameBody,
            "Your first Vibe starts with the day you just shaped. Swap in your own photos anytime."
        )
        XCTAssertEqual(OnboardingCopy.namePlaceholder, "Daybreak, Deep Focus, Cozy Weekend…")
        XCTAssertEqual(OnboardingCopy.namePrefill, "Daybreak")
        XCTAssertEqual(OnboardingCopy.namePrimaryCta, "Set My Desktop")
        XCTAssertEqual(OnboardingCopy.nameSecondaryCta, "I'll do this later")
    }

    func test_commitWaitCopy_matchesSpec() {
        XCTAssertEqual(OnboardingCopy.nameCommittingLabel, "Setting your desktop…")
        XCTAssertEqual(
            OnboardingCopy.nameCommitTimeout,
            "This is taking longer than usual. Your Vibe is saved, so you can close this and it will apply when macOS catches up."
        )
    }

    func test_allOnboardingCopy_containsNoEmDashes() {
        let allStrings: [String] = [
            OnboardingCopy.coverEyebrow, OnboardingCopy.coverTitle, OnboardingCopy.coverBody,
            OnboardingCopy.coverCta,
            OnboardingCopy.dialEyebrow, OnboardingCopy.dialTitle, OnboardingCopy.dialBody,
            OnboardingCopy.dialLocationPrompt,
            OnboardingCopy.dialLocationCta, OnboardingCopy.dialLocationSkip,
            OnboardingCopy.dialLocationGranted, OnboardingCopy.dialLocationFallback,
            OnboardingCopy.dialCta,
            OnboardingCopy.nameEyebrow, OnboardingCopy.nameTitle, OnboardingCopy.nameBody,
            OnboardingCopy.namePlaceholder, OnboardingCopy.namePrefill,
            OnboardingCopy.namePrimaryCta, OnboardingCopy.nameSecondaryCta,
            OnboardingCopy.nameCommittingLabel, OnboardingCopy.nameCommitTimeout,
            OnboardingCopy.skipLink, OnboardingCopy.backLink
        ]
        for s in allStrings {
            XCTAssertFalse(s.contains("\u{2014}"), "String must not contain em dash: \(s)")
        }
    }

    func test_currentTimeSlotIndex_mapsHoursOntoEngineSlots() {
        let calendar = Calendar.current
        for hour in 0..<24 {
            var components = calendar.dateComponents([.year, .month, .day], from: Date())
            components.hour = hour
            guard let date = calendar.date(from: components) else {
                XCTFail("Could not build date for hour \(hour)")
                continue
            }
            let index = OnboardingView.currentTimeSlotIndex(date: date)
            XCTAssertTrue(
                HorizonScheduleDefaults.orderedSlotIDs.indices.contains(index),
                "Hour \(hour) produced out-of-range slot index \(index)"
            )
            XCTAssertEqual(
                HorizonScheduleDefaults.orderedSlotIDs[index],
                TimeSlot.from(hour: hour).slotID,
                "Hour \(hour) should seed the dial at its own slot"
            )
        }
    }

    func test_uniqueName_leavesAFreeNameAlone() {
        XCTAssertEqual(VibeNaming.uniqueName("Daybreak", existing: ["Calm"]), "Daybreak")
        XCTAssertEqual(VibeNaming.uniqueName("Daybreak", existing: []), "Daybreak")
    }

    func test_uniqueName_stepsPastNamesTheUserAlreadyHas() {
        XCTAssertEqual(VibeNaming.uniqueName("Daybreak", existing: ["Daybreak"]), "Daybreak 2")
        XCTAssertEqual(
            VibeNaming.uniqueName("Daybreak", existing: ["Daybreak", "Daybreak 2", "Daybreak 3"]),
            "Daybreak 4"
        )
    }
}
