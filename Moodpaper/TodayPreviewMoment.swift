import SwiftUI

/// Pure value type for the Dashboard's Today Preview cards. The builder
/// (TodayPreviewMoment.build) produces these from a single Inputs struct
/// so the section's render path is dumb — it just maps moments to cards.
///
/// `applyMode` tells the Apply button how to call into WallpaperManager so
/// the card and the resulting wallpaper agree.
struct TodayPreviewMoment: Identifiable, Equatable {
    enum ApplyMode: Equatable {
        /// Standard apply from the active Mood's slot pool.
        case standard(slotID: String)
        /// One-shot slot preview that bypasses contextual overrides.
        case oneShotSlot(slotID: String)
        /// Force the focus slot ignoring contextual overrides. Used
        /// only by the Focus Mode meeting cards.
        case focusSlot(slotID: String)
        /// Scroll the Dashboard to a named anchor (e.g. the weather card at
        /// the top). Used for Info-style cards that contextually point the
        /// user at the related surface elsewhere on the page.
        case scrollTo(anchorID: String)
        /// Apply is disabled (e.g., informational "Resumes when unpaused" card).
        case disabled
    }

    let id: String
    let label: String           // "Now", "Next", "Later", "Ready", "Paused"
    let title: String           // user-facing line 1
    let detail: String          // user-facing line 2
    let icon: String            // SF Symbol
    let accentHex: String?      // optional override; nil = use slot color
    let slotID: String?         // for thumbnail/color resolution if accentHex is nil
    let applyMode: ApplyMode
    let isCalendarConditional: Bool
    let footnote: String?       // optional small status line shown under Apply
    let customApplyLabel: String?  // overrides default "Apply" string (e.g. "Shuffle")
    let customApplyIcon: String?   // overrides default SF Symbol on the Apply button

    init(
        id: String,
        label: String,
        title: String,
        detail: String,
        icon: String,
        accentHex: String? = nil,
        slotID: String? = nil,
        applyMode: ApplyMode,
        isCalendarConditional: Bool = false,
        footnote: String? = nil,
        customApplyLabel: String? = nil,
        customApplyIcon: String? = nil
    ) {
        self.id = id
        self.label = label
        self.title = title
        self.detail = detail
        self.icon = icon
        self.accentHex = accentHex
        self.slotID = slotID
        self.applyMode = applyMode
        self.isCalendarConditional = isCalendarConditional
        self.footnote = footnote
        self.customApplyLabel = customApplyLabel
        self.customApplyIcon = customApplyIcon
    }
}

extension TodayPreviewMoment {
    struct Inputs: Equatable {
        var currentSlotID: String
        var enabledSlotIDs: [String]      // ordered, current mode's enabled slots; never empty
        var slotTitleByID: [String: String]
        var slotIconByID: [String: String]
        var nextChangeCountdown: String   // already formatted, e.g. "26m", "1h 12m"

        var pauseRotation: Bool

        var focusModeEnabled: Bool
        var focusSlotID: String
        var isInMeeting: Bool
        var currentMeetingTitle: String?
    }

    /// Pure builder. Branches by mode precedence: Focus meeting →
    /// Pause → Time. Returns up to 5 moments.
    static func build(inputs: Inputs) -> [TodayPreviewMoment] {
        var result: [TodayPreviewMoment] = []

        // Mode precedence: Focus meeting → Pause → Time.

        // Focus meeting wins over every other mode. Calendar-driven so it
        // shows the calendar-conditional badge.
        if inputs.focusModeEnabled && inputs.isInMeeting {
            let slot = inputs.focusSlotID
            let detail = inputs.currentMeetingTitle.map { "Meeting: \($0)" } ?? "Calendar meeting active"
            result.append(
                TodayPreviewMoment(
                    id: "now-focus-meeting",
                    label: "Now",
                    title: "Focus Mode",
                    detail: detail,
                    icon: "person.fill.viewfinder",
                    accentHex: nil,
                    slotID: slot,
                    applyMode: .focusSlot(slotID: slot),
                    isCalendarConditional: true,
                    footnote: nil
                )
            )
            return result
        }

        // Pause branch. Only the explicit Time / Focus default fall through it.
        if inputs.pauseRotation {
            let slot = inputs.currentSlotID
            result.append(
                TodayPreviewMoment(
                    id: "now-paused-\(slot)",
                    label: "Now",
                    title: inputs.slotTitleByID[slot] ?? slot,
                    detail: "Rotation paused",
                    icon: "pause.circle.fill",
                    accentHex: nil,
                    slotID: slot,
                    applyMode: .standard(slotID: slot),
                    isCalendarConditional: false,
                    footnote: nil
                )
            )
            result.append(
                TodayPreviewMoment(
                    id: "paused-info",
                    label: "Paused",
                    title: "No upcoming change",
                    detail: "Resumes when you unpause",
                    icon: "pause.fill",
                    accentHex: nil,
                    slotID: nil,
                    applyMode: .disabled,
                    isCalendarConditional: false,
                    footnote: nil
                )
            )
            return result
        }

        // "Now" — time mode default.
        let nowSlot = inputs.currentSlotID
        result.append(
            TodayPreviewMoment(
                id: "now-\(nowSlot)",
                label: "Now",
                title: inputs.slotTitleByID[nowSlot] ?? nowSlot,
                detail: "Time-based rotation",
                icon: "sun.horizon.fill",
                accentHex: nil,
                slotID: nowSlot,
                applyMode: .standard(slotID: nowSlot),
                isCalendarConditional: false,
                footnote: nil
            )
        )

        // Next + Later — upcoming enabled slots.
        let slots = inputs.enabledSlotIDs
        guard let currentIndex = slots.firstIndex(of: nowSlot), !slots.isEmpty else {
            return Array(result.prefix(5))
        }
        for offset in 1...3 {
            let slot = slots[(currentIndex + offset) % slots.count]
            let isNext = offset == 1
            result.append(
                TodayPreviewMoment(
                    id: "slot-\(offset)-\(slot)",
                    label: isNext ? "Next" : "Later",
                    title: inputs.slotTitleByID[slot] ?? slot,
                    detail: isNext ? "In \(inputs.nextChangeCountdown)" : slotReason(slot),
                    icon: inputs.slotIconByID[slot] ?? "photo",
                    accentHex: nil,
                    slotID: slot,
                    applyMode: .standard(slotID: slot),
                    isCalendarConditional: false,
                    footnote: nil
                )
            )
        }

        // Trailing Focus-ready card. Only added when focus is armed but no
        // meeting is active. Sits after the upcoming slot cards.
        if inputs.focusModeEnabled && !inputs.isInMeeting {
            let slot = inputs.focusSlotID
            let slotTitle = inputs.slotTitleByID[slot] ?? slot
            result.append(
                TodayPreviewMoment(
                    id: "focus-ready",
                    label: "Ready",
                    title: "Meeting Focus",
                    detail: "Will use \(slotTitle) during meetings",
                    icon: "calendar.badge.clock",
                    accentHex: nil,
                    slotID: slot,
                    applyMode: .focusSlot(slotID: slot),
                    isCalendarConditional: true,
                    footnote: nil
                )
            )
        }

        return Array(result.prefix(5))
    }

    /// Long-form descriptor for "Later" slot cards in time mode.
    private static func slotReason(_ slotID: String) -> String {
        switch slotID {
        case "morning": return "Daylight phase"
        case "afternoon", "midday": return "Midday energy"
        case "evening": return "Night rhythm"
        case "deep-night": return "Quiet overnight"
        case "dawn", "sunrise": return "Sunrise rhythm"
        case "golden-hour", "dusk": return "Sunset rhythm"
        default: return "Scheduled slot"
        }
    }
}
