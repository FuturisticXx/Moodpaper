import Foundation

/// The nine bundled photographs that power onboarding and become the user's
/// first Vibe.
///
/// Moodpaper ships no wallpaper *library* — the user's own photos are the
/// product. These nine are a starter set, not a library: one frame per engine
/// slot, chosen so that scrubbing the onboarding dial reads as a single day
/// passing. They exist because a first-run user owns zero images, and
/// onboarding's whole payoff is watching the real desktop change once.
///
/// The set replaces the generated slot-palette gradients used during the B4
/// concept work. Real photography is the point: Moodpaper is a visual product
/// and a gradient cannot demonstrate what a wallpaper does to a room.
///
/// Files live in `Moodpaper/StarterWallpapers/` and reach the app bundle
/// through the project's filesystem-synchronized group, so adding or replacing
/// a frame needs no Xcode project edit.
enum StarterWallpaperLibrary {

    /// Provenance for a bundled frame. Kept in code rather than a text file so
    /// a frame can never ship without a record of where it came from.
    ///
    /// `origin` is the Horizon staging path the frame was selected from. The
    /// three Horizon staging folders reuse the same filenames for different
    /// photographs, so per-photographer attribution could not be resolved from
    /// Horizon's CREDITS.md with confidence. The Pexels License does not
    /// require attribution, so the honest record is the path, not a guess.
    struct Credit: Equatable {
        let slotID: String
        let origin: String
        let license: String
    }

    static let filePrefix = "starter-"
    static let fileExtension = "jpg"

    /// Every engine slot, in day order. Mirrors the schedule's slot list so a
    /// slot can never be added to the engine and silently lack starter art.
    static var slotIDs: [String] { HorizonScheduleDefaults.orderedSlotIDs }

    /// Frames the cover moment drifts through before the user clicks anything.
    ///
    /// Deliberately not all nine: the cover is a mood, not an inventory. These
    /// five carry the widest emotional swing (near-black water, blue-hour
    /// silhouette, warm light, high noon, deep amber) so the loop reads as
    /// "this changes a lot" within the few seconds a first-run user waits.
    static let coverSequence = ["deep-night", "dawn", "morning", "midday", "golden-hour"]

    /// Two frames are deliberately cross-slotted: the file Horizon named
    /// `golden-hour-6` is the cooler of the pair and the file it named
    /// `afternoon-11` is the warmer, so they are used the other way round.
    /// Selection is by light temperature, not by the source filename.
    static let credits: [Credit] = [
        Credit(slotID: "deep-night", origin: "WallpapersStaging3/mood-calm-6.jpg", license: "Pexels"),
        Credit(slotID: "dawn", origin: "WallpapersStaging/dawn-5.jpg", license: "Pexels"),
        Credit(slotID: "sunrise", origin: "WallpapersStaging2/sunrise-4.jpg", license: "Pexels"),
        Credit(slotID: "morning", origin: "WallpapersStaging2/morning-5.jpg", license: "Pexels"),
        Credit(slotID: "midday", origin: "WallpapersStaging2/midday-1.jpg", license: "Pexels"),
        Credit(slotID: "afternoon", origin: "WallpapersStaging2/golden-hour-6.jpg", license: "Pexels"),
        Credit(slotID: "golden-hour", origin: "WallpapersStaging/afternoon-11.jpg", license: "Pexels"),
        Credit(slotID: "dusk", origin: "WallpapersStaging3/dusk-17.jpg", license: "Pexels"),
        Credit(slotID: "evening", origin: "WallpapersStaging2/dawn-2.jpg", license: "Pexels")
    ]

    static func fileName(forSlotID slotID: String) -> String {
        "\(filePrefix)\(slotID).\(fileExtension)"
    }

    /// Resolves a slot's bundled frame.
    ///
    /// Tries the flat Resources lookup first and the `StarterWallpapers`
    /// subdirectory second, because a synchronized group can land resources
    /// either way depending on how Xcode flattens the folder.
    static func url(forSlotID slotID: String, in bundle: Bundle = .main) -> URL? {
        let name = "\(filePrefix)\(slotID)"
        return bundle.url(forResource: name, withExtension: fileExtension)
            ?? bundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "StarterWallpapers"
            )
    }

    /// slotID → bundled file URL for every slot that resolved.
    ///
    /// Returns a partial map rather than failing outright: a missing frame
    /// should cost that one slot its photograph, not break onboarding.
    static func allURLs(in bundle: Bundle = .main) -> [String: URL] {
        var urls: [String: URL] = [:]
        for slotID in slotIDs {
            if let url = url(forSlotID: slotID, in: bundle) {
                urls[slotID] = url
            }
        }
        return urls
    }
}
