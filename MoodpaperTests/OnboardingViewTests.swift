import XCTest
@testable import Moodpaper

final class OnboardingViewTests: XCTestCase {

    func test_coverCopy_matchesSpec() {
        XCTAssertEqual(OnboardingCopy.coverEyebrow, "MOODPAPER")
        XCTAssertEqual(OnboardingCopy.coverTitle, "Make your desktop feel alive")
        XCTAssertEqual(
            OnboardingCopy.coverBody,
            "Moodpaper plays your photos throughout the day, changing with the rhythm you choose. Create a Vibe, add the wallpapers you love, and let Moodpaper take it from there."
        )
        XCTAssertEqual(OnboardingCopy.coverCta, "Begin")
    }

    func test_dialCopy_matchesSpec() {
        XCTAssertEqual(OnboardingCopy.dialEyebrow, "TURN THE DAY · 1 OF 2")
        XCTAssertEqual(OnboardingCopy.dialTitle, "Your day has a rhythm")
        XCTAssertEqual(
            OnboardingCopy.dialBody,
            "Moodpaper can change your wallpaper as the day moves from morning to night. Drag to watch the light change. Later, Shape My Day lets you choose what plays when."
        )
        XCTAssertEqual(OnboardingCopy.dialLocationPrompt, "Time this to your actual sunrise?")
        XCTAssertEqual(OnboardingCopy.dialLocationCta, "Use My Location")
        XCTAssertEqual(OnboardingCopy.dialLocationSkip, "Not now")
        XCTAssertEqual(
            OnboardingCopy.dialLocationFallback,
            "Using standard times. You can refine with location anytime in Settings."
        )
    }

    func test_nameCopy_matchesSpec() {
        XCTAssertEqual(OnboardingCopy.nameEyebrow, "START YOUR VIBE · 2 OF 2")
        XCTAssertEqual(OnboardingCopy.nameTitle, "Name your first Vibe")
        XCTAssertEqual(
            OnboardingCopy.nameBody,
            "A Vibe is a group of wallpapers with its own feeling and pace. We'll start you with a few so you can see Moodpaper in motion."
        )
        XCTAssertEqual(OnboardingCopy.namePlaceholder, "My Wallpapers")
        XCTAssertEqual(OnboardingCopy.namePrefill, "My Wallpapers")
        XCTAssertEqual(OnboardingCopy.namePrimaryCta, "Start My Vibe")
        XCTAssertEqual(OnboardingCopy.nameSecondaryCta, "I'll do this later")
    }

    func test_commitWaitCopy_matchesSpec() {
        XCTAssertEqual(OnboardingCopy.nameCommittingLabel, "Starting your Vibe…")
        XCTAssertEqual(
            OnboardingCopy.nameCommitTimeout,
            "This is taking longer than usual. Your Vibe is saved, so you can close this and playback will start when macOS catches up."
        )
    }

    func test_newVibePlaceholder_isNotOnboardingPrefill() {
        XCTAssertEqual(VibeNaming.namePlaceholder, "Daybreak, Deep Focus, Cozy Weekend…")
        XCTAssertNotEqual(VibeNaming.namePlaceholder, OnboardingCopy.namePlaceholder)
        XCTAssertNotEqual(VibeNaming.namePlaceholder, OnboardingCopy.namePrefill)
    }

    // MARK: - Start My Vibe wait

    func test_commitWait_nameChangeSucceedsImmediately() {
        XCTAssertEqual(
            OnboardingCommitWait.decision(
                nameChanged: true, applyStarted: true, applyInProgress: true, elapsed: 0.5
            ),
            .succeeded
        )
    }

    func test_commitWait_holdsWhileApplyIsInProgress() {
        XCTAssertEqual(
            OnboardingCommitWait.decision(
                nameChanged: false, applyStarted: true, applyInProgress: true, elapsed: 12.2
            ),
            .waiting
        )
    }

    func test_commitWait_failsOnceApplyFinishesWithoutNameChange() {
        XCTAssertEqual(
            OnboardingCommitWait.decision(
                nameChanged: false, applyStarted: true, applyInProgress: false, elapsed: 3
            ),
            .failed
        )
    }

    func test_commitWait_applyNeverStartsWaitsUntilSafetyValve() {
        XCTAssertEqual(
            OnboardingCommitWait.decision(
                nameChanged: false, applyStarted: false, applyInProgress: false, elapsed: 24.9
            ),
            .waiting
        )
        XCTAssertEqual(
            OnboardingCommitWait.decision(
                nameChanged: false, applyStarted: false, applyInProgress: false, elapsed: 25
            ),
            .failed
        )
    }

    func test_commitWait_lateSuccessStillSucceeds() {
        XCTAssertEqual(
            OnboardingCommitWait.decision(
                nameChanged: true, applyStarted: true, applyInProgress: false, elapsed: 19
            ),
            .succeeded
        )
    }

    func test_commitWait_safetyValveOutlastsEngineConfirmationBudget() {
        XCTAssertGreaterThan(OnboardingCommitWait.safetyValve, 20)
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
            XCTAssertFalse(s.contains("All Day"), "Stale All Day wording: \(s)")
            XCTAssertFalse(s.contains("Name this feeling"), "Stale naming copy: \(s)")
            XCTAssertFalse(s.contains("Set My Desktop"), "Stale one-shot CTA: \(s)")
        }
    }

    func test_moodsViewDoesNotReuseOnboardingPlaceholder() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Moodpaper/MoodsView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("OnboardingCopy.namePlaceholder"))
        XCTAssertTrue(source.contains("VibeNaming.namePlaceholder"))
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
