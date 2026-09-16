import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Moodpaper

/// End-to-end Phase 6A rehearsal on a disposable library root. The root is
/// registered as protected through `testLiveLibraryRoot`, so the run also
/// proves the authorization guard does not break an intentional migration.
///
/// The disposable root lives under the host's temporary directory in a
/// `CatalogV2Rehearsal-<uuid>` folder next to `rehearsal-evidence.json`, and
/// is left in place so the run can be inspected from outside the test.
@MainActor
final class CatalogV2MigrationRehearsalTests: XCTestCase {
    private var root: URL!
    private var evidenceURL: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var evidence: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CatalogV2Rehearsal-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("disposable-library", isDirectory: true)
        evidenceURL = base.appendingPathComponent("rehearsal-evidence.json")
        suiteName = "HorizonTests.Rehearsal.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        LibraryMigration.testInterruptAfterPhase = nil
        LibraryMigration.testCorruptStagingBeforeValidation = false
        LibraryMigration.testLiveLibraryRoot = nil
        LibraryMigration.environmentProvider = { [:] }
    }

    override func tearDown() {
        LibraryMigration.testInterruptAfterPhase = nil
        LibraryMigration.testCorruptStagingBeforeValidation = false
        LibraryMigration.testLiveLibraryRoot = nil
        LibraryMigration.environmentProvider = { ProcessInfo.processInfo.environment }
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore() -> MoodStore {
        MoodStore(baseURL: root, defaults: defaults)
    }

    private func writePNG(to url: URL, color: CGColor) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 16, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 10))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func hashes(under folder: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        var out: [String: String] = [:]
        let prefix = folder.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            out[relative] = try WallpaperIdentity.sha256Hex(of: url)
        }
        return out
    }

    private func authorize() {
        let path = root.standardizedFileURL.path
        LibraryMigration.environmentProvider = {
            [LibraryMigration.authorizationEnvironmentKey: path]
        }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func names(_ urls: [URL]) -> [String] {
        urls.map(\.lastPathComponent).sorted()
    }

    // MARK: - Rehearsal

    func testFullDisposableMigrationRehearsal() throws {
        let fm = FileManager.default
        evidence["disposableRoot"] = root.path

        // The disposable root must not resolve to any real or incident state.
        let real = LibraryMigration.realUserLibraryRoot().standardizedFileURL.path
        let processDefault = LibraryMigration.defaultApplicationSupportLibraryRoot().standardizedFileURL.path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertNotEqual(rootPath, real)
        XCTAssertNotEqual(rootPath, processDefault)
        XCTAssertFalse(rootPath.hasPrefix(real + "/"))
        XCTAssertFalse(rootPath.hasPrefix(processDefault + "/"))
        XCTAssertFalse(rootPath.contains("Moodpaper-catalog-v2-quarantine"))
        XCTAssertFalse(rootPath.contains("Moodpaper.backup"))
        XCTAssertFalse(LibraryMigration.isProtectedLibraryRoot(root), "plain disposable root needs no authorization")

        // Register the disposable root as protected so the guard is exercised.
        LibraryMigration.testLiveLibraryRoot = root
        XCTAssertTrue(LibraryMigration.isProtectedLibraryRoot(root))
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: root))

        // ---- Legacy fixture -------------------------------------------------
        let blue = CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1)
        let green = CGColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1)
        let orange = CGColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1)
        let purple = CGColor(red: 0.5, green: 0.1, blue: 0.7, alpha: 1)

        let legacy = makeStore()
        XCTAssertFalse(legacy.usesCatalog)
        let calm = try XCTUnwrap(legacy.create(name: "Calm"))
        let bold = try XCTUnwrap(legacy.create(name: "Bold"))
        let quiet = try XCTUnwrap(legacy.create(name: "Quiet"))
        legacy.setWallpapersPerDay(7, for: calm)
        legacy.setWallpapersPerDay(3, for: bold)
        legacy.setWallpapersPerDay(1, for: quiet)

        // Calm: two general wallpapers plus a byte-identical duplicate copy.
        let calmLake = legacy.allDayFolderURL(in: calm).appendingPathComponent("lake.png")
        let calmLakeCopy = legacy.allDayFolderURL(in: calm).appendingPathComponent("lake-copy.png")
        let calmForest = legacy.allDayFolderURL(in: calm).appendingPathComponent("forest.png")
        try writePNG(to: calmLake, color: blue)
        try fm.copyItem(at: calmLake, to: calmLakeCopy)
        try writePNG(to: calmForest, color: green)
        // Mixed Shape My Day: lake on the Morning group, then one period removed.
        try legacy.assignWallpaper(calmLake, to: .morning, in: calm)
        let dawnCopy = try XCTUnwrap(legacy.wallpapers(for: .dawn, in: calm).first)
        try legacy.removeWallpaperAssignment(dawnCopy, from: .dawn, in: calm)
        // One wallpaper on multiple periods: forest on Evening + Night groups.
        try legacy.assignWallpaper(calmForest, to: .evening, in: calm)
        try legacy.assignWallpaper(calmForest, to: .night, in: calm)

        // Bold: shares lake with Calm (same bytes) and has sky on all nine periods.
        let boldLake = legacy.allDayFolderURL(in: bold).appendingPathComponent("lake.png")
        let boldSky = legacy.allDayFolderURL(in: bold).appendingPathComponent("sky.png")
        try fm.createDirectory(at: boldLake.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: calmLake, to: boldLake)
        try writePNG(to: boldSky, color: orange)
        for group in DayPartGroup.allCases {
            try legacy.assignWallpaper(boldSky, to: group, in: bold)
        }

        // Quiet: general only.
        try writePNG(to: legacy.allDayFolderURL(in: quiet).appendingPathComponent("dusk.png"), color: purple)

        // Skipped period and active Vibe.
        HorizonScheduleDefaults.setSlotEnabled(false, slotID: TimeSlot.evening.slotID, defaults: defaults)
        legacy.activate(calm)

        XCTAssertEqual(legacy.dayPartRepresentation(for: .morning, in: calm), .mixed)
        XCTAssertEqual(legacy.dayPartRepresentation(for: .night, in: calm), .assigned(filenames: ["forest.png"]))
        XCTAssertEqual(legacy.wallpapers(for: .dawn, in: calm), [])
        for slot in TimeSlot.allCases {
            XCTAssertEqual(names(legacy.wallpapers(for: slot, in: bold)), ["sky.png"], slot.rawValue)
        }

        let legacyBefore = try hashes(under: root.appendingPathComponent("Moods"))
        let legacyFiles = LibraryMigration.legacyImageFiles(in: root)
        let legacyIdentities = try Set(legacyFiles.map { try WallpaperIdentity.sha256Hex(of: $0.url) })
        evidence["fixture"] = [
            "vibes": ["Calm": calm.id, "Bold": bold.id, "Quiet": quiet.id],
            "activeVibe": "Calm",
            "cadence": ["Calm": 7, "Bold": 3, "Quiet": 1],
            "skippedPeriod": TimeSlot.evening.rawValue,
            "legacyImageFileCount": legacyFiles.count,
            "distinctContentHashes": legacyIdentities.count,
            "legacyFiles": legacyFiles.map { "\($0.moodID)/\($0.folderName)/\($0.url.lastPathComponent)" }.sorted(),
            "calmMorningGroup": "mixed (lake on DeepNight/Sunrise/Morning, Dawn removed)",
            "calmForest": "Evening + Night groups (GoldenHour, Dusk, Evening)",
            "boldSky": "all nine periods",
            "duplicates": "Calm lake.png == Calm lake-copy.png == Bold lake.png",
        ]
        XCTAssertEqual(legacyIdentities.count, 4)

        // ---- Guard: wrong-path authorization fails closed -------------------
        let wrongPath = root.appendingPathComponent("elsewhere").path
        LibraryMigration.environmentProvider = {
            [LibraryMigration.authorizationEnvironmentKey: wrongPath]
        }
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: root))
        XCTAssertThrowsError(try LibraryMigration.migrateIfNeeded(libraryRoot: root)) {
            XCTAssertTrue($0 is LibraryMigration.MigrationBlockedError)
        }
        XCTAssertFalse(exists(WallpaperCatalogFile.migrationRoot(in: root)))
        XCTAssertFalse(exists(WallpaperCatalogFile.catalogURL(in: root)))
        XCTAssertEqual(try hashes(under: root.appendingPathComponent("Moods")), legacyBefore)
        evidence["guard.wrongPathAuthorization"] = "blocked, zero writes"

        // ---- Authorized: validation failure leaves legacy intact ------------
        authorize()
        XCTAssertFalse(LibraryMigration.isMigrationBlocked(for: root))
        var phases: [String] = []
        LibraryMigration.testCorruptStagingBeforeValidation = true
        XCTAssertThrowsError(try LibraryMigration.migrateIfNeeded(libraryRoot: root)) {
            XCTAssertTrue($0 is LibraryMigration.ValidationError, "\($0)")
        }
        let abortedJournal = try LibraryMigration.loadJournal(from: root)
        phases.append(abortedJournal.phase.rawValue)
        XCTAssertEqual(abortedJournal.phase, .aborted)
        XCTAssertNotNil(abortedJournal.lastError)
        XCTAssertFalse(exists(WallpaperCatalogFile.catalogURL(in: root)), "validation failure must not publish")
        XCTAssertFalse(exists(WallpaperCatalogFile.assetsRoot(in: root)))
        XCTAssertEqual(try hashes(under: root.appendingPathComponent("Moods")), legacyBefore)
        let runID = abortedJournal.runID
        let backupName = try XCTUnwrap(abortedJournal.backupFolderName)
        evidence["validationFailure"] = ["phase": "aborted", "lastError": abortedJournal.lastError ?? "", "catalogPublished": false]

        // ---- Authorized: simulated interruption ------------------------------
        LibraryMigration.testInterruptAfterPhase = .catalogStaged
        XCTAssertThrowsError(try LibraryMigration.migrateIfNeeded(libraryRoot: root)) {
            XCTAssertTrue($0 is LibraryMigration.InterruptedError, "\($0)")
        }
        let interruptedJournal = try LibraryMigration.loadJournal(from: root)
        phases.append(interruptedJournal.phase.rawValue)
        XCTAssertEqual(interruptedJournal.phase, .catalogStaged)
        XCTAssertEqual(interruptedJournal.runID, runID)
        XCTAssertFalse(exists(WallpaperCatalogFile.catalogURL(in: root)))
        let stagedIDs = interruptedJournal.sourcePathToAssetID
        XCTAssertEqual(stagedIDs.count, legacyFiles.count)
        XCTAssertEqual(Set(stagedIDs.values).count, 4)

        // ---- Authorized: resume to completion --------------------------------
        let summary = try LibraryMigration.migrateIfNeeded(libraryRoot: root)
        let completeJournal = try LibraryMigration.loadJournal(from: root)
        phases.append(completeJournal.phase.rawValue)
        XCTAssertEqual(completeJournal.phase, .complete)
        XCTAssertEqual(completeJournal.runID, runID)
        XCTAssertNil(completeJournal.lastError)
        XCTAssertTrue(summary.resumed)
        XCTAssertFalse(summary.alreadyComplete)
        XCTAssertEqual(summary.assetCount, 4)
        XCTAssertEqual(summary.membershipCount, 5)
        XCTAssertEqual(completeJournal.sourcePathToAssetID, stagedIDs, "resume must keep the staged asset IDs")
        evidence["migrationRunID"] = runID
        evidence["journalPhaseTransitions"] = ["started/backupComplete/assetsCopying/catalogStaged (journaled inside run)"] + phases
        evidence["interruption"] = [
            "interruptedAfter": "catalogStaged",
            "resumedSummary": ["resumed": summary.resumed, "assets": summary.assetCount, "memberships": summary.membershipCount],
            "assetIDsStableAcrossResume": completeJournal.sourcePathToAssetID == stagedIDs,
        ]

        // ---- Backup / journal / staging / publish --------------------------
        let backup = WallpaperCatalogFile.backupsRoot(in: root).appendingPathComponent(backupName)
        XCTAssertTrue(exists(backup))
        let backupHashes = try hashes(under: backup.appendingPathComponent("Moods"))
        XCTAssertEqual(backupHashes, legacyBefore, "backup must mirror pre-migration Moods")
        XCTAssertTrue(exists(WallpaperCatalogFile.journalURL(in: root)))
        XCTAssertTrue(exists(WallpaperCatalogFile.stagingRoot(in: root)))
        XCTAssertTrue(exists(WallpaperCatalogFile.catalogURL(in: root)))
        let catalog = try LibraryMigration.loadCatalog(from: root)
        XCTAssertTrue(catalog.isReady)
        XCTAssertEqual(catalog.assets.count, 4)
        XCTAssertEqual(catalog.memberships.count, 5)
        let assetFiles = try fm.contentsOfDirectory(at: WallpaperCatalogFile.assetsRoot(in: root), includingPropertiesForKeys: nil)
        XCTAssertEqual(assetFiles.count, 4)
        XCTAssertEqual(Set(catalog.assets.map(\.contentHash)), legacyIdentities)
        evidence["backupPath"] = backup.path
        evidence["backupMatchesPreMigrationMoods"] = true

        // ---- Dedup + mapping --------------------------------------------------
        let assetsByHash = Dictionary(uniqueKeysWithValues: catalog.assets.map { ($0.contentHash, $0) })
        let lakeHash = try WallpaperIdentity.sha256Hex(of: calmLake)
        let forestHash = try WallpaperIdentity.sha256Hex(of: calmForest)
        let skyHash = try WallpaperIdentity.sha256Hex(of: boldSky)
        let lakeAsset = try XCTUnwrap(assetsByHash[lakeHash])
        let forestAsset = try XCTUnwrap(assetsByHash[forestHash])
        let skyAsset = try XCTUnwrap(assetsByHash[skyHash])
        let lakeSources = Set(lakeAsset.legacySourcePaths.map { URL(fileURLWithPath: $0).lastPathComponent })
        XCTAssertEqual(lakeSources, ["lake.png", "lake-copy.png"])
        XCTAssertEqual(lakeAsset.originalFilename, "lake.png", "general shortest name wins over lake-copy.png and period copies")
        XCTAssertEqual(forestAsset.originalFilename, "forest.png")
        XCTAssertEqual(skyAsset.originalFilename, "sky.png")
        XCTAssertEqual(lakeAsset.legacySourcePaths.count, 1 + 1 + 3 + 1, "Calm lake, lake-copy, 3 period copies, Bold lake")
        XCTAssertEqual(forestAsset.legacySourcePaths.count, 1 + 3)
        XCTAssertEqual(skyAsset.legacySourcePaths.count, 1 + 9)

        func membership(_ asset: WallpaperAsset, _ mood: Mood) -> WallpaperMembership? {
            catalog.memberships.first { $0.assetID == asset.id && $0.moodID == mood.id }
        }
        let calmLakeM = try XCTUnwrap(membership(lakeAsset, calm))
        XCTAssertTrue(calmLakeM.throughoutTheDay)
        XCTAssertEqual(Set(calmLakeM.slotIDs), ["DeepNight", "Sunrise", "Morning"])
        let calmForestM = try XCTUnwrap(membership(forestAsset, calm))
        XCTAssertTrue(calmForestM.throughoutTheDay)
        XCTAssertEqual(Set(calmForestM.slotIDs), ["GoldenHour", "Dusk", "Evening"])
        let boldLakeM = try XCTUnwrap(membership(lakeAsset, bold))
        XCTAssertTrue(boldLakeM.throughoutTheDay)
        XCTAssertEqual(boldLakeM.slotIDs, [])
        let boldSkyM = try XCTUnwrap(membership(skyAsset, bold))
        XCTAssertEqual(Set(boldSkyM.slotIDs), Set(TimeSlot.allCases.map(\.rawValue)))
        XCTAssertNil(membership(lakeAsset, quiet))
        evidence["dedup"] = [
            "legacyFiles": legacyFiles.count,
            "canonicalAssets": catalog.assets.count,
            "lakeLegacySources": lakeAsset.legacySourcePaths.count,
            "forestLegacySources": forestAsset.legacySourcePaths.count,
            "skyLegacySources": skyAsset.legacySourcePaths.count,
        ]
        evidence["memberships"] = catalog.memberships.map { m -> [String: Any] in
            let moodName = [calm, bold, quiet].first { $0.id == m.moodID }?.name ?? m.moodID
            let file = catalog.asset(id: m.assetID)?.originalFilename ?? m.assetID
            return ["vibe": moodName, "asset": file, "throughoutTheDay": m.throughoutTheDay, "slots": m.slotIDs.sorted()]
        }

        // ---- Relaunch: blocked without authorization, adopted with ----------
        LibraryMigration.environmentProvider = { [:] }
        // The journal records that this migration was explicitly authorized,
        // so an ordinary launch adopts the completed catalog without asking.
        XCTAssertEqual(completeJournal.authorization, .environment)
        let ordinaryLaunch = makeStore()
        XCTAssertTrue(ordinaryLaunch.usesCatalog, "an authorized, completed migration is adopted on later launches")
        XCTAssertFalse(ordinaryLaunch.needsLibraryUpdate)
        // Strip the record (a catalog nobody authorized) and adoption is refused.
        var unstamped = completeJournal
        unstamped.authorization = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(unstamped).write(to: WallpaperCatalogFile.journalURL(in: root))
        let unauthorized = makeStore()
        XCTAssertFalse(unauthorized.usesCatalog, "an unauthorized catalog is not adopted on a protected root")
        XCTAssertTrue(unauthorized.needsLibraryUpdate)
        XCTAssertEqual(unauthorized.moods.count, 3, "legacy model still serves the Vibes")
        XCTAssertNil(defaults.object(forKey: LibraryMigration.authorizationEnvironmentKey))
        try encoder.encode(completeJournal).write(to: WallpaperCatalogFile.journalURL(in: root))
        authorize()
        let store = makeStore()
        XCTAssertTrue(store.usesCatalog)
        XCTAssertNil(defaults.object(forKey: LibraryMigration.authorizationEnvironmentKey), "authorization is never persisted")

        // ---- Semantics after migration --------------------------------------
        let calm2 = try XCTUnwrap(store.mood(id: calm.id))
        let bold2 = try XCTUnwrap(store.mood(id: bold.id))
        let quiet2 = try XCTUnwrap(store.mood(id: quiet.id))
        XCTAssertEqual(store.activeMoodID, calm.id)
        XCTAssertEqual(store.effectiveWallpapersPerDay(for: calm2), 7)
        XCTAssertEqual(store.effectiveWallpapersPerDay(for: bold2), 3)
        XCTAssertEqual(store.effectiveWallpapersPerDay(for: quiet2), 1)
        XCTAssertFalse(HorizonScheduleDefaults.isSlotEnabled(TimeSlot.evening.slotID, defaults: defaults))
        XCTAssertEqual(store.dayPartRepresentation(for: .morning, in: calm2), .mixed)
        XCTAssertEqual(store.dayPartRepresentation(for: .night, in: calm2), .assigned(filenames: ["forest.png"]))
        XCTAssertEqual(store.dayPartRepresentation(for: .evening, in: calm2), .assigned(filenames: ["forest.png"]))
        XCTAssertEqual(store.dayPartRepresentation(for: .day, in: calm2), .usingVibePhotos)
        XCTAssertTrue(store.wallpapers(for: .dawn, in: calm2).isEmpty)
        XCTAssertEqual(store.effectiveWallpapers(for: .dawn, in: calm2).count, 2, "empty period inherits the two general wallpapers")
        XCTAssertEqual(store.wallpapers(for: .sunrise, in: calm2).count, 1)
        for slot in TimeSlot.allCases {
            XCTAssertEqual(store.wallpapers(for: slot, in: bold2).count, 1, slot.rawValue)
        }
        XCTAssertEqual(store.dayPartRepresentation(for: .day, in: bold2), .assigned(filenames: ["sky.png"]))
        XCTAssertEqual(store.totalWallpaperCount(in: calm2), 2)
        XCTAssertEqual(store.totalWallpaperCount(in: bold2), 2)
        XCTAssertEqual(store.totalWallpaperCount(in: quiet2), 1)
        XCTAssertEqual(store.libraryItems(in: calm2).count, 2, "Wallpapers grid shows unique assets")
        XCTAssertEqual(store.libraryItems(in: bold2).count, 2)
        for item in store.libraryItems(in: calm2) {
            XCTAssertTrue(item.url.path.contains("/Catalog/Assets/"))
        }
        // Playback identifiers written before migration resolve to the canonical file.
        let remapped = try XCTUnwrap(store.resolveCanonicalURL(forPlaybackIdentifier: calmLake.standardizedFileURL.path))
        XCTAssertEqual(remapped, LibraryMigration.canonicalURL(for: lakeAsset, libraryRoot: root))
        XCTAssertTrue(exists(remapped))
        evidence["postMigration"] = [
            "activeVibe": store.activeMood?.name ?? "",
            "cadence": ["Calm": 7, "Bold": 3, "Quiet": 1],
            "calmMorningGroup": "mixed",
            "calmNightGroup": "assigned forest.png",
            "boldNinePeriods": "sky.png",
            "eveningSkipped": true,
            "uniqueWallpapers": ["Calm": 2, "Bold": 2, "Quiet": 1],
            "legacyPlaybackIdentifierRemaps": true,
        ]

        // ---- Idempotent rerun -------------------------------------------------
        let assetHashesBefore = try hashes(under: WallpaperCatalogFile.assetsRoot(in: root))
        let catalogBytesBefore = try Data(contentsOf: WallpaperCatalogFile.catalogURL(in: root))
        let rerun = try LibraryMigration.migrateIfNeeded(libraryRoot: root)
        XCTAssertTrue(rerun.alreadyComplete)
        XCTAssertEqual(rerun.assetCount, 4)
        XCTAssertEqual(try hashes(under: WallpaperCatalogFile.assetsRoot(in: root)), assetHashesBefore)
        XCTAssertEqual(try Data(contentsOf: WallpaperCatalogFile.catalogURL(in: root)), catalogBytesBefore)
        XCTAssertEqual(try LibraryMigration.loadJournal(from: root).runID, runID)
        evidence["idempotence"] = ["alreadyComplete": true, "assetsUnchanged": true, "catalogBytesUnchanged": true]

        // ---- Remove from Vibe vs Delete from Moodpaper ----------------------
        let boldLakeURL = try XCTUnwrap(store.allDayWallpapers(in: bold2).first { $0.lastPathComponent.hasPrefix(lakeAsset.id) })
        try store.removeWallpaper(boldLakeURL, from: bold2)
        XCTAssertTrue(exists(boldLakeURL), "Remove from Vibe keeps the canonical asset")
        XCTAssertEqual(store.catalog?.assets.count, 4)
        XCTAssertEqual(store.catalog?.memberships.count, 4)
        XCTAssertEqual(store.totalWallpaperCount(in: bold2), 1)
        XCTAssertEqual(store.totalWallpaperCount(in: calm2), 2, "Calm still has lake")

        let skyURL = try XCTUnwrap(store.allDayWallpapers(in: bold2).first)
        try store.deleteWallpaperFromMoodpaper(skyURL)
        XCTAssertFalse(exists(skyURL), "Delete from Moodpaper removes the file")
        XCTAssertEqual(store.catalog?.assets.count, 3)
        XCTAssertEqual(store.catalog?.memberships.count, 3)
        XCTAssertEqual(store.totalWallpaperCount(in: bold2), 0)
        for slot in TimeSlot.allCases {
            XCTAssertTrue(store.wallpapers(for: slot, in: bold2).isEmpty, "all nine assignments gone: \(slot.rawValue)")
        }
        // Reload reflects the same state.
        let reloaded = makeStore()
        XCTAssertTrue(reloaded.usesCatalog)
        XCTAssertEqual(reloaded.catalog?.assets.count, 3)
        XCTAssertEqual(reloaded.totalWallpaperCount(in: try XCTUnwrap(reloaded.mood(id: calm.id))), 2)
        evidence["removeVsDelete"] = [
            "removeFromVibe": ["assetKept": true, "assets": 4, "memberships": 4],
            "deleteFromMoodpaper": ["fileRemoved": true, "assets": 3, "memberships": 3, "boldAssignmentsCleared": true],
        ]

        // ---- Legacy data and backup intact after everything ------------------
        XCTAssertEqual(try hashes(under: root.appendingPathComponent("Moods")).filter { $0.key != "moods.json" },
                       legacyBefore.filter { $0.key != "moods.json" },
                       "legacy image folders are never mutated by migration")
        XCTAssertEqual(try hashes(under: backup.appendingPathComponent("Moods")), backupHashes)
        evidence["legacyFoldersIntact"] = true
        evidence["backupIntactAfterSuccess"] = true
        evidence["counts"] = [
            "before": ["legacyImageFiles": legacyFiles.count, "vibes": 3, "catalogAssets": 0],
            "afterMigration": ["catalogAssets": 4, "memberships": 5, "vibes": 3],
            "afterRemoveAndDelete": ["catalogAssets": 3, "memberships": 3, "vibes": 3],
        ]

        // Real-library paths never appear in any guard decision made here.
        XCTAssertFalse(rootPath.hasPrefix(real))
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: LibraryMigration.realUserLibraryRoot()))
        evidence["realLibraryTouched"] = false

        try exportEvidence()
    }

    private func exportEvidence() throws {
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: evidenceURL)
    }
}
