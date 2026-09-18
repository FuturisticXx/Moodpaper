import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Moodpaper

/// The production adoption path: a protected root with legacy data stays on
/// the legacy model until the user chooses Update Library, which grants a
/// one-shot, process-memory authorization for that exact root.
@MainActor
final class LibraryUpdateAuthorizationTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryUpdateTests-\(UUID().uuidString)")
        suiteName = "HorizonTests.LibraryUpdate.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        LibraryMigration.testInterruptAfterPhase = nil
        LibraryMigration.testCorruptStagingBeforeValidation = false
        LibraryMigration.clearOneShotAuthorization()
        // Finder-style launch: no environment authorization, protected root.
        LibraryMigration.environmentProvider = { [:] }
        LibraryMigration.testLiveLibraryRoot = root
    }

    override func tearDown() {
        LibraryMigration.testInterruptAfterPhase = nil
        LibraryMigration.testCorruptStagingBeforeValidation = false
        LibraryMigration.clearOneShotAuthorization()
        LibraryMigration.testLiveLibraryRoot = nil
        LibraryMigration.environmentProvider = { ProcessInfo.processInfo.environment }
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore() -> MoodStore {
        MoodStore(baseURL: root, defaults: defaults)
    }

    private func writePNG(
        to url: URL,
        color: CGColor = CGColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 1)
    ) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// A legacy library with one Vibe and one general wallpaper.
    @discardableResult
    private func seedLegacyLibrary() throws -> (vibe: Mood, file: URL) {
        let seed = makeStore()
        let vibe = try XCTUnwrap(seed.create(name: "Optimistic"))
        let file = seed.allDayFolderURL(in: vibe).appendingPathComponent("sky.png")
        try writePNG(to: file)
        return (vibe, file)
    }

    private func snapshot() throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        var out: [String: String] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            out[url.path] = try WallpaperIdentity.sha256Hex(of: url)
        }
        return out
    }

    private var catalogURL: URL { WallpaperCatalogFile.catalogURL(in: root) }
    private var journalURL: URL { WallpaperCatalogFile.journalURL(in: root) }
    private var migrationRoot: URL { WallpaperCatalogFile.migrationRoot(in: root) }

    // MARK: - Tests

    /// 1. A Finder-style launch with legacy data never migrates by itself.
    func testProductionLaunchWithLegacyDataDoesNotMigrateAutomatically() throws {
        try seedLegacyLibrary()
        let before = try snapshot()

        let store = makeStore()
        XCTAssertFalse(store.usesCatalog)
        XCTAssertTrue(store.needsLibraryUpdate, "the update prompt is offered")
        XCTAssertFalse(store.isLibraryUpdateRequested)
        XCTAssertEqual(store.moods.count, 1, "legacy model keeps serving")
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrationRoot.path))
        XCTAssertEqual(try snapshot(), before)
    }

    /// 2. Not Now is a pure dismissal: zero migration writes, nothing granted.
    func testNotNowLeavesLibraryUntouched() throws {
        try seedLegacyLibrary()
        let store = makeStore()
        XCTAssertTrue(store.needsLibraryUpdate)
        let before = try snapshot()

        // Not Now never reaches the store; the window just closes the sheet.
        store.isLibraryUpdateRequested = false
        _ = makeStore()

        XCTAssertFalse(LibraryMigration.hasOneShotAuthorization)
        XCTAssertFalse(LibraryMigration.isMigrationAuthorized(for: root))
        XCTAssertEqual(try snapshot(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrationRoot.path))
    }

    /// 3 + 5. Update Library authorizes exactly this root once, migrates
    /// through the Phase 6A engine, adopts, and clears the authorization.
    func testUpdateLibraryMigratesThisRootAndClearsAuthorization() async throws {
        let seeded = try seedLegacyLibrary()
        let store = makeStore()
        XCTAssertTrue(store.needsLibraryUpdate)

        let summary = try await store.updateLibrary()
        XCTAssertEqual(summary.assetCount, 1)
        XCTAssertFalse(summary.alreadyComplete)
        XCTAssertTrue(store.usesCatalog)
        XCTAssertFalse(store.needsLibraryUpdate)
        XCTAssertFalse(store.isLibraryUpdateRequested)
        XCTAssertFalse(store.isUpdatingLibrary)

        let journal = try LibraryMigration.loadJournal(from: root)
        XCTAssertEqual(journal.phase, .complete)
        XCTAssertEqual(journal.authorization, .user)
        XCTAssertNotNil(journal.backupFolderName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.file.path), "legacy file is preserved")

        // Consumed: nothing remains that could authorize another migration.
        XCTAssertFalse(LibraryMigration.hasOneShotAuthorization)
        XCTAssertFalse(LibraryMigration.isMigrationAuthorized(for: root))
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: root))
        XCTAssertNil(defaults.object(forKey: LibraryMigration.authorizationEnvironmentKey))
        let persisted = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertFalse(persisted.keys.contains { $0.localizedCaseInsensitiveContains("authoriz") })
    }

    /// 4. A one-shot authorization is bound to one exact root.
    func testOneShotAuthorizationCannotAuthorizeAnotherRoot() throws {
        try seedLegacyLibrary()
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryUpdateOther-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }

        LibraryMigration.grantOneShotAuthorization(for: other)
        XCTAssertTrue(LibraryMigration.hasOneShotAuthorization)
        XCTAssertFalse(LibraryMigration.isMigrationAuthorized(for: root))
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: root))
        XCTAssertThrowsError(try LibraryMigration.migrateIfNeeded(libraryRoot: root)) {
            XCTAssertTrue($0 is LibraryMigration.MigrationBlockedError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrationRoot.path))
        // Any attempt consumes the grant, so a stray one cannot linger either.
        XCTAssertFalse(LibraryMigration.hasOneShotAuthorization)
    }

    /// 6. A failed update clears the authorization, keeps the legacy model
    /// usable, preserves the evidence, and reports calmly.
    func testFailedUpdateClearsAuthorizationAndKeepsLegacyUsable() async throws {
        let seeded = try seedLegacyLibrary()
        let store = makeStore()
        let legacyBefore = try snapshot()
        LibraryMigration.testCorruptStagingBeforeValidation = true

        do {
            try await store.updateLibrary()
            XCTFail("validation failure must surface")
        } catch let error as MoodStore.LibraryUpdateFailedError {
            XCTAssertTrue(error.underlying is LibraryMigration.ValidationError)
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Your wallpapers and Vibes are unchanged"))
            XCTAssertFalse(message.contains("explicit authorization"))
            XCTAssertFalse(message.contains("hash"))
        }

        XCTAssertFalse(LibraryMigration.hasOneShotAuthorization)
        XCTAssertFalse(LibraryMigration.isMigrationAuthorized(for: root))
        XCTAssertFalse(store.isUpdatingLibrary)
        XCTAssertFalse(store.usesCatalog)
        XCTAssertTrue(store.needsLibraryUpdate)
        XCTAssertEqual(store.moods.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
        let journal = try LibraryMigration.loadJournal(from: root)
        XCTAssertEqual(journal.phase, .aborted)
        XCTAssertNotNil(journal.backupFolderName, "backup and journal are kept as evidence")
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.file.path))
        let legacyPrefix = root.appendingPathComponent("Moods").path + "/"
        let legacyAfter = try snapshot().filter { $0.key.hasPrefix(legacyPrefix) }
        XCTAssertEqual(legacyAfter, legacyBefore.filter { $0.key.hasPrefix(legacyPrefix) })
    }

    /// 7. A relaunch cannot reuse a previous authorization: after a failure
    /// the next launch is blocked again, and after a success nothing on disk
    /// can authorize a fresh migration.
    func testRelaunchCannotReusePreviousAuthorization() async throws {
        try seedLegacyLibrary()
        LibraryMigration.testCorruptStagingBeforeValidation = true
        try? await makeStore().updateLibrary()
        LibraryMigration.testCorruptStagingBeforeValidation = false

        let journalAfterFailure = try Data(contentsOf: journalURL)
        let relaunch = makeStore()
        XCTAssertFalse(relaunch.usesCatalog)
        XCTAssertTrue(relaunch.needsLibraryUpdate)
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: root))
        XCTAssertEqual(try Data(contentsOf: journalURL), journalAfterFailure, "relaunch did not resume on its own")

        // Explicit approval resumes and completes; later launches adopt.
        let summary = try await relaunch.updateLibrary()
        XCTAssertTrue(summary.resumed)
        XCTAssertTrue(relaunch.usesCatalog)
        XCTAssertTrue(makeStore().usesCatalog)

        // Remove the published catalog: a relaunch must not migrate again.
        try FileManager.default.removeItem(at: catalogURL)
        let journalAfterSuccess = try Data(contentsOf: journalURL)
        let again = makeStore()
        XCTAssertFalse(again.usesCatalog)
        XCTAssertTrue(again.needsLibraryUpdate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
        XCTAssertEqual(try Data(contentsOf: journalURL), journalAfterSuccess)
    }

    /// 8. Interruption and resume through the in-app path keep the run ID and
    /// asset identity, and a repeat is idempotent.
    func testInAppUpdateResumesAfterInterruptionAndIsIdempotent() async throws {
        try seedLegacyLibrary()
        LibraryMigration.testInterruptAfterPhase = .catalogStaged
        do {
            try await makeStore().updateLibrary()
            XCTFail("interruption must surface")
        } catch let error as MoodStore.LibraryUpdateFailedError {
            XCTAssertTrue(error.underlying is LibraryMigration.InterruptedError)
        }
        let interrupted = try LibraryMigration.loadJournal(from: root)
        XCTAssertEqual(interrupted.phase, .catalogStaged)
        XCTAssertFalse(LibraryMigration.hasOneShotAuthorization)

        let store = makeStore()
        XCTAssertFalse(store.usesCatalog)
        let resumed = try await store.updateLibrary()
        XCTAssertTrue(resumed.resumed)
        let complete = try LibraryMigration.loadJournal(from: root)
        XCTAssertEqual(complete.runID, interrupted.runID)
        XCTAssertEqual(complete.sourcePathToAssetID, interrupted.sourcePathToAssetID)
        XCTAssertEqual(complete.authorization, .user)

        let catalogBytes = try Data(contentsOf: catalogURL)
        let again = try await store.updateLibrary()
        XCTAssertTrue(again.alreadyComplete)
        XCTAssertEqual(try Data(contentsOf: catalogURL), catalogBytes)
    }

    /// 9. The environment variable remains the development/test path and
    /// journals its own source.
    func testEnvironmentAuthorizationStillWorks() throws {
        try seedLegacyLibrary()
        let path = root.standardizedFileURL.path
        LibraryMigration.environmentProvider = {
            [LibraryMigration.authorizationEnvironmentKey: path]
        }
        XCTAssertEqual(LibraryMigration.authorizationSource(for: root), .environment)
        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: root)
        XCTAssertEqual(try LibraryMigration.loadJournal(from: root).authorization, .environment)
        XCTAssertTrue(makeStore().usesCatalog)
        LibraryMigration.environmentProvider = { [:] }
        XCTAssertTrue(makeStore().usesCatalog, "adopted on an ordinary launch afterwards")
    }

    /// A catalog completed by an authorized run that predates the journal
    /// record is offered for approval once, then stamped and adopted.
    func testUpdateLibraryStampsAnAlreadyCompleteUnrecordedMigration() async throws {
        try seedLegacyLibrary()
        LibraryMigration.grantOneShotAuthorization(for: root)
        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: root)
        var journal = try LibraryMigration.loadJournal(from: root)
        journal.authorization = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: journalURL)

        let store = makeStore()
        XCTAssertFalse(store.usesCatalog)
        XCTAssertTrue(store.needsLibraryUpdate)
        let assetsBefore = try snapshot().filter { $0.key.contains("/Catalog/") }

        let summary = try await store.updateLibrary()
        XCTAssertTrue(summary.alreadyComplete)
        XCTAssertTrue(store.usesCatalog)
        XCTAssertEqual(try LibraryMigration.loadJournal(from: root).authorization, .user)
        XCTAssertEqual(try snapshot().filter { $0.key.contains("/Catalog/") }, assetsBefore, "no second migration")
        XCTAssertTrue(makeStore().usesCatalog)
    }

    /// 11. Delete from Moodpaper before the update asks for the update
    /// instead of surfacing the developer guard diagnostic; Remove from Vibe
    /// keeps working on the legacy model.
    func testDeleteFromMoodpaperAsksForLibraryUpdateBeforeMigration() throws {
        let seeded = try seedLegacyLibrary()
        let store = makeStore()
        XCTAssertFalse(store.usesCatalog)
        let before = try snapshot()

        XCTAssertThrowsError(try store.deleteWallpaperFromMoodpaper(seeded.file)) { error in
            XCTAssertTrue(error is MoodStore.LibraryUpdateRequiredError)
            XCTAssertFalse(error.localizedDescription.contains("explicit authorization"))
            XCTAssertTrue(error.localizedDescription.contains("Update your wallpaper library"))
        }
        XCTAssertTrue(store.isLibraryUpdateRequested, "the window presents the update prompt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.file.path), "nothing was deleted")
        XCTAssertEqual(try snapshot(), before)
        XCTAssertFalse(LibraryMigration.hasOneShotAuthorization)

        try store.removeWallpaper(seeded.file, from: seeded.vibe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.file.path), "Remove from Vibe stays available")
    }

    // MARK: - Stamping an already-complete migration is verified first

    /// Completes a migration under authorization, then strips the record so
    /// the next launch must ask, exactly like a pre-record production run.
    private func completeUnrecordedMigration() throws -> (catalog: WallpaperCatalog, journal: LibraryMigration.Journal) {
        try seedLegacyLibrary()
        LibraryMigration.grantOneShotAuthorization(for: root)
        _ = try LibraryMigration.migrateIfNeeded(libraryRoot: root)
        var journal = try LibraryMigration.loadJournal(from: root)
        journal.authorization = nil
        try writeJournal(journal)
        return (try LibraryMigration.loadCatalog(from: root), journal)
    }

    private func writeJournal(_ journal: LibraryMigration.Journal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: journalURL, options: .atomic)
    }

    /// Runs Update Library against damaged completed state and proves it is
    /// refused: no record written, no evidence removed, legacy model kept,
    /// calm failure surfaced.
    private func assertStampRefused(_ reason: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let journalBefore = try Data(contentsOf: journalURL)
        let catalogBefore = try Data(contentsOf: catalogURL)
        let store = makeStore()
        XCTAssertFalse(store.usesCatalog, reason, file: file, line: line)
        XCTAssertTrue(store.needsLibraryUpdate, reason, file: file, line: line)
        do {
            try await store.updateLibrary()
            XCTFail("\(reason): damaged completed state must be refused", file: file, line: line)
        } catch let error as MoodStore.LibraryUpdateFailedError {
            XCTAssertTrue(error.underlying is LibraryMigration.CompletedMigrationError, "\(reason): \(error.underlying)", file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains("Your wallpapers and Vibes are unchanged"), file: file, line: line)
        }
        XCTAssertNil(try LibraryMigration.loadJournal(from: root).authorization, "\(reason): not stamped", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBefore, "\(reason): journal untouched", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: catalogURL), catalogBefore, "\(reason): catalog untouched", file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: migrationRoot.path), "\(reason): evidence kept", file: file, line: line)
        XCTAssertFalse(store.usesCatalog, "\(reason): stays on the legacy model", file: file, line: line)
        XCTAssertTrue(store.needsLibraryUpdate, file: file, line: line)
        XCTAssertFalse(LibraryMigration.hasOneShotAuthorization, file: file, line: line)
        XCTAssertFalse(makeStore().usesCatalog, "\(reason): relaunch does not adopt", file: file, line: line)
    }

    func testStampingVerifiesEverythingBeforeRecordingAuthorization() throws {
        let state = try completeUnrecordedMigration()
        let verified = try LibraryMigration.verifyCompletedMigration(libraryRoot: root)
        XCTAssertEqual(verified.catalog, state.catalog)
        XCTAssertEqual(verified.journal.runID, state.journal.runID)
        XCTAssertEqual(state.journal.phase, .complete)
        XCTAssertNotNil(state.journal.backupFolderName)
    }

    func testStampRefusedWhenCanonicalAssetIsMissing() async throws {
        let state = try completeUnrecordedMigration()
        let asset = try XCTUnwrap(state.catalog.assets.first)
        try FileManager.default.removeItem(at: LibraryMigration.canonicalURL(for: asset, libraryRoot: root))
        try await assertStampRefused("missing canonical asset")
    }

    func testStampRefusedWhenCanonicalAssetHashMismatches() async throws {
        let state = try completeUnrecordedMigration()
        let asset = try XCTUnwrap(state.catalog.assets.first)
        try Data("damaged".utf8).write(to: LibraryMigration.canonicalURL(for: asset, libraryRoot: root))
        try await assertStampRefused("hash mismatch")
    }

    func testStampRefusedWhenBackupIsMissing() async throws {
        let state = try completeUnrecordedMigration()
        let backup = WallpaperCatalogFile.backupsRoot(in: root)
            .appendingPathComponent(try XCTUnwrap(state.journal.backupFolderName))
        try FileManager.default.removeItem(at: backup)
        try await assertStampRefused("missing backup")
    }

    func testStampRefusedWhenJournalAndCatalogDisagree() async throws {
        var journal = try completeUnrecordedMigration().journal
        for key in journal.sourcePathToAssetID.keys {
            journal.sourcePathToAssetID[key] = UUID().uuidString.lowercased()
        }
        try writeJournal(journal)
        try await assertStampRefused("journal mapping mismatch")
    }

    func testStampRefusedWhenJournalIsNotComplete() async throws {
        var journal = try completeUnrecordedMigration().journal
        journal.phase = .catalogStaged
        try writeJournal(journal)
        // A staged journal with a ready catalog is inconsistent state, not a
        // resumable migration: catalog.json only exists after `complete`.
        try await assertStampRefused("journal not complete")
    }

    /// A catalog at an unsupported version is never ready: ordinary launches
    /// ignore it and nothing is stamped or rewritten until the user asks.
    /// An explicit update then rebuilds from the legacy folders, which stay
    /// the source of truth until a catalog is adopted.
    func testUnsupportedCatalogIsNeverAdoptedOrStampedWithoutExplicitUpdate() async throws {
        var catalog = try completeUnrecordedMigration().catalog
        catalog.migrationVersion = LibraryMigration.migrationVersion + 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(catalog).write(to: catalogURL, options: .atomic)
        let catalogBefore = try Data(contentsOf: catalogURL)
        let journalBefore = try Data(contentsOf: journalURL)

        let launch = makeStore()
        XCTAssertFalse(launch.usesCatalog)
        XCTAssertTrue(launch.needsLibraryUpdate)
        XCTAssertEqual(try Data(contentsOf: catalogURL), catalogBefore)
        XCTAssertEqual(try Data(contentsOf: journalURL), journalBefore)
        XCTAssertNil(try LibraryMigration.loadJournal(from: root).authorization)
        XCTAssertFalse(makeStore().usesCatalog)

        let summary = try await launch.updateLibrary()
        XCTAssertFalse(summary.alreadyComplete, "rebuilt from legacy, not stamped as-is")
        XCTAssertTrue(launch.usesCatalog)
        XCTAssertEqual(try LibraryMigration.loadJournal(from: root).authorization, .user)
    }

    func testStampRefusedWhenLegacyFilesAreNotCatalogued() async throws {
        let state = try completeUnrecordedMigration()
        let vibeID = try XCTUnwrap(state.catalog.memberships.first?.moodID)
        try writePNG(to: root.appendingPathComponent("Moods/\(vibeID)/AllDay/added-later.png"))
        try await assertStampRefused("uncatalogued legacy file")
    }

    // MARK: - Ordinary Catalog persistence after trusted adoption

    /// Migration authorization is consumed after Update Library. Ordinary
    /// Browse/import must still persist: trust comes from the completed,
    /// authorized journal, not from a live one-shot grant.
    func testTrustedAdoptedCatalogPersistsOrdinaryImportWithoutMigrationAuthorization() async throws {
        try seedLegacyLibrary()
        let store = makeStore()
        _ = try await store.updateLibrary()
        XCTAssertTrue(store.usesCatalog)
        XCTAssertTrue(LibraryMigration.isMigrationBlocked(for: root), "migration itself stays gated")
        XCTAssertTrue(LibraryMigration.canAdoptPublishedCatalog(at: root))
        XCTAssertFalse(LibraryMigration.isMigrationAuthorized(for: root))

        let before = try LibraryMigration.loadCatalog(from: root)
        XCTAssertEqual(before.assets.count, 1)
        let extra = root.appendingPathComponent("browse-import.png")
        try writePNG(to: extra, color: CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        let vibe = try XCTUnwrap(store.moods.first)

        let summary = try await store.importAllDayWallpapers(from: [extra], in: vibe)
        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertEqual(summary.failedCount, 0)
        let importedID = try XCTUnwrap(summary.importedAssetIDs.first)

        let onDisk = try LibraryMigration.loadCatalog(from: root)
        XCTAssertEqual(onDisk.assets.count, 2)
        XCTAssertTrue(onDisk.assets.contains { $0.id == importedID })
        XCTAssertTrue(onDisk.memberships.contains {
            $0.assetID == importedID && $0.moodID == vibe.id && $0.throughoutTheDay
        })
        let canonical = LibraryMigration.canonicalURL(
            for: try XCTUnwrap(onDisk.asset(id: importedID)),
            libraryRoot: root
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))

        FocusAssetSelection.setAssetIDs([importedID], defaults: defaults)
        let relaunch = makeStore()
        XCTAssertTrue(relaunch.usesCatalog)
        XCTAssertNotNil(relaunch.catalog?.asset(id: importedID))
        XCTAssertEqual(relaunch.focusCandidateURLs(assetIDs: [importedID]), [canonical])
        XCTAssertEqual(FocusAssetSelection.assetIDs(defaults: defaults), [importedID])
    }

    /// catalog.json on a protected root is not enough. Without a trusted
    /// completed journal, Catalog writes stay blocked.
    func testUntrustedPublishedCatalogCannotPersistOrdinaryImport() async throws {
        _ = try completeUnrecordedMigration()
        let store = makeStore()
        XCTAssertFalse(store.usesCatalog)
        XCTAssertTrue(store.needsLibraryUpdate)
        let catalogBefore = try Data(contentsOf: catalogURL)
        let extra = root.appendingPathComponent("should-not-catalog.png")
        try writePNG(to: extra, color: CGColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1))
        let vibe = try XCTUnwrap(store.moods.first)

        let summary = try await store.importAllDayWallpapers(from: [extra], in: vibe)
        XCTAssertEqual(summary.importedCount, 1)
        XCTAssertFalse(store.usesCatalog)
        XCTAssertEqual(try Data(contentsOf: catalogURL), catalogBefore)
        XCTAssertEqual(try LibraryMigration.loadCatalog(from: root).assets.count, 1)
        XCTAssertNil(try LibraryMigration.loadJournal(from: root).authorization)
    }

    /// If catalog.json cannot be written, a new canonical file must not remain.
    func testFailedCatalogSaveDoesNotLeaveOrphanCanonicalAsset() async throws {
        try seedLegacyLibrary()
        let store = makeStore()
        _ = try await store.updateLibrary()
        let assetsRoot = WallpaperCatalogFile.assetsRoot(in: root)
        let filesBefore = Set(
            (try FileManager.default.contentsOfDirectory(
                at: assetsRoot, includingPropertiesForKeys: nil
            )).map(\.lastPathComponent)
        )
        let assetCountBefore = try XCTUnwrap(store.catalog?.assets.count)

        try FileManager.default.removeItem(at: catalogURL)
        try FileManager.default.createDirectory(at: catalogURL, withIntermediateDirectories: true)

        let extra = root.appendingPathComponent("orphan-attempt.png")
        try writePNG(to: extra, color: CGColor(red: 0.2, green: 0.9, blue: 0.4, alpha: 1))
        let vibe = try XCTUnwrap(store.moods.first)
        let summary = try await store.importAllDayWallpapers(from: [extra], in: vibe)
        XCTAssertEqual(summary.importedCount, 0)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(store.catalog?.assets.count, assetCountBefore)

        let filesAfter = Set(
            (try FileManager.default.contentsOfDirectory(
                at: assetsRoot, includingPropertiesForKeys: nil
            )).map(\.lastPathComponent)
        )
        XCTAssertEqual(filesAfter, filesBefore)
    }
}
