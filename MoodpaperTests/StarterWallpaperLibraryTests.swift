import XCTest
import ImageIO
@testable import Moodpaper

final class StarterWallpaperLibraryTests: XCTestCase {

    /// The bundle under test. The app target's resources are what ship, so
    /// these assertions are about the real product, not a fixture.
    private var bundle: Bundle {
        Bundle(for: OnboardingImageStore.self)
    }

    func test_everyEngineSlotHasBundledArt() {
        let urls = StarterWallpaperLibrary.allURLs(in: bundle)
        XCTAssertEqual(
            Set(urls.keys),
            Set(HorizonScheduleDefaults.orderedSlotIDs),
            "Every engine slot needs a bundled frame, or onboarding's day arc has a hole in it"
        )
    }

    func test_bundledArtIsDecodableAndLargeEnoughForARetinaDesktop() throws {
        let urls = StarterWallpaperLibrary.allURLs(in: bundle)
        for (slotID, url) in urls {
            let source = try XCTUnwrap(
                CGImageSourceCreateWithURL(url as CFURL, nil),
                "\(slotID) is not a decodable image"
            )
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            )
            let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
            let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)

            // These files are applied to a real desktop, not just shown in the
            // onboarding window, so they have to survive a 4K display.
            XCTAssertGreaterThanOrEqual(width, 3840, "\(slotID) is too narrow for a 4K desktop")
            XCTAssertGreaterThan(height, 0)

            // Landscape only. A portrait frame would letterbox on every Mac.
            XCTAssertGreaterThan(
                Double(width) / Double(height),
                1.3,
                "\(slotID) is too tall to fill a Mac display without a severe crop"
            )
        }
    }

    func test_coverSequenceIsASubsetOfTheEngineSlots() {
        for slotID in StarterWallpaperLibrary.coverSequence {
            XCTAssertTrue(
                HorizonScheduleDefaults.orderedSlotIDs.contains(slotID),
                "Cover frame \(slotID) is not an engine slot, so it has no bundled art"
            )
        }
    }

    func test_coverSequenceResolvesToRealFiles() {
        for slotID in StarterWallpaperLibrary.coverSequence {
            XCTAssertNotNil(
                StarterWallpaperLibrary.url(forSlotID: slotID, in: bundle),
                "Cover frame \(slotID) has no bundled file, so the opening loop would stall on a gradient"
            )
        }
    }

    func test_creditsCoverEverySlot() {
        XCTAssertEqual(
            Set(StarterWallpaperLibrary.credits.map(\.slotID)),
            Set(HorizonScheduleDefaults.orderedSlotIDs),
            "A frame must never ship without a provenance record"
        )
    }

    func test_missingSlotYieldsNilRatherThanCrashing() {
        XCTAssertNil(StarterWallpaperLibrary.url(forSlotID: "not-a-slot", in: bundle))
    }
}
