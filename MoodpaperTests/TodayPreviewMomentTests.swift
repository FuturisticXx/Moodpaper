import XCTest
@testable import Moodpaper

final class TodayPreviewMomentTests: XCTestCase {

    // Baseline time-mode inputs: no pause, no focus.
    private func timeModeInputs() -> TodayPreviewMoment.Inputs {
        TodayPreviewMoment.Inputs(
            currentSlotID: "morning",
            enabledSlotIDs: ["morning", "midday", "afternoon", "evening", "deep-night"],
            slotTitleByID: [
                "morning": "Morning",
                "midday": "Midday",
                "afternoon": "Afternoon",
                "evening": "Evening",
                "deep-night": "Deep Night"
            ],
            slotIconByID: [
                "morning": "sun.max.fill",
                "midday": "sun.max",
                "afternoon": "sun.haze.fill",
                "evening": "moon.fill",
                "deep-night": "moon.stars.fill"
            ],
            nextChangeCountdown: "1h 12m",
            pauseRotation: false,
            focusModeEnabled: false,
            focusSlotID: "morning",
            isInMeeting: false,
            currentMeetingTitle: nil
        )
    }

    func test_timeMode_buildsNowPlusNextThreeSlots() {
        let moments = TodayPreviewMoment.build(inputs: timeModeInputs())
        XCTAssertEqual(moments.count, 4, "Time mode: Now + 3 upcoming slots")
        XCTAssertEqual(moments[0].label, "Now")
        XCTAssertEqual(moments[0].title, "Morning")
        XCTAssertEqual(moments[0].detail, "Time-based rotation")
        XCTAssertEqual(moments[1].label, "Next")
        XCTAssertEqual(moments[1].title, "Midday")
        XCTAssertEqual(moments[1].detail, "In 1h 12m")
        XCTAssertEqual(moments[2].label, "Later")
        XCTAssertEqual(moments[2].title, "Afternoon")
        XCTAssertEqual(moments[3].label, "Later")
        XCTAssertEqual(moments[3].title, "Evening")
    }

    func test_timeMode_applyModeIsStandard() {
        let moments = TodayPreviewMoment.build(inputs: timeModeInputs())
        for moment in moments {
            if case .standard = moment.applyMode { continue }
            XCTFail("Time mode moments should all use .standard apply mode, got \(moment.applyMode) for \(moment.label)")
        }
    }

    // MARK: Pause Rotation branch

    private func pausedInputs() -> TodayPreviewMoment.Inputs {
        var inputs = timeModeInputs()
        inputs.pauseRotation = true
        return inputs
    }

    func test_paused_nowKeepsCurrentSlotWithPausedDetail() {
        let moments = TodayPreviewMoment.build(inputs: pausedInputs())
        XCTAssertEqual(moments[0].label, "Now")
        XCTAssertEqual(moments[0].title, "Morning")
        XCTAssertEqual(moments[0].detail, "Rotation paused")
    }

    func test_paused_secondCardIsInformationalNotCountdown() {
        let moments = TodayPreviewMoment.build(inputs: pausedInputs())
        XCTAssertEqual(moments.count, 2)
        XCTAssertEqual(moments[1].label, "Paused")
        XCTAssertEqual(moments[1].title, "No upcoming change")
        XCTAssertEqual(moments[1].detail, "Resumes when you unpause")
        if case .disabled = moments[1].applyMode {} else { XCTFail("paused info card must have .disabled apply mode") }
    }

    // MARK: Focus Mode branches

    private func focusMeetingInputs() -> TodayPreviewMoment.Inputs {
        var inputs = timeModeInputs()
        inputs.focusModeEnabled = true
        inputs.isInMeeting = true
        inputs.currentMeetingTitle = "Design review"
        inputs.focusSlotID = "midday"
        return inputs
    }

    func test_focusMeeting_nowCardOverridesEverything() {
        let moments = TodayPreviewMoment.build(inputs: focusMeetingInputs())
        XCTAssertEqual(moments[0].label, "Now")
        XCTAssertEqual(moments[0].title, "Focus Mode")
        XCTAssertEqual(moments[0].detail, "Meeting: Design review")
        XCTAssertTrue(moments[0].isCalendarConditional)
        if case .focusSlot(let slotID) = moments[0].applyMode {
            XCTAssertEqual(slotID, "midday")
        } else {
            XCTFail("Focus Now card must use .focusSlot apply mode")
        }
    }

    func test_focusReady_appearsAtEndWhenEnabledButNotInMeeting() {
        var inputs = timeModeInputs()
        inputs.focusModeEnabled = true
        inputs.isInMeeting = false
        inputs.focusSlotID = "evening"
        let moments = TodayPreviewMoment.build(inputs: inputs)
        guard let ready = moments.last else { return XCTFail("expected trailing focus-ready card") }
        XCTAssertEqual(ready.label, "Ready")
        XCTAssertEqual(ready.title, "Meeting Focus")
        XCTAssertEqual(ready.detail, "Will use Evening during meetings")
        XCTAssertTrue(ready.isCalendarConditional)
    }
}
