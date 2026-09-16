import Foundation

/// Catalog v2 migrator. Folder-owned wallpaper copies become first-class
/// assets with memberships. Legacy Moods folders, backups, and journal.json
/// stay on disk until a later approved cleanup — this type never deletes them
/// after a successful migrate.
enum LibraryMigration {
    static let schemaVersion = WallpaperCatalog.schemaVersion
    static let migrationVersion = WallpaperCatalog.migrationVersion

    private static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "bmp"
    ]

    /// Test-only: stop after this journal phase so resume can be exercised.
    static var testInterruptAfterPhase: JournalPhase?
    /// Test-only: mutate staging after copy and before validate.
    static var testCorruptStagingBeforeValidation = false
    /// Test-only stand-in for Application Support/Moodpaper. Must never point
    /// at a real home-directory library.
    static var testLiveLibraryRoot: URL?

    // MARK: - Migration authorization guard
    //
    // Catalog v2 migration against a protected library root is blocked unless
    // the launch environment explicitly authorizes that exact root. The
    // authorization lives only in the process environment: it is never read
    // from or written to UserDefaults, so it cannot outlive the run. Process
    // name, build configuration, sandbox state, and XCTest-host detection
    // play no part in the decision.

    /// Launch environment variable whose value must equal the standardized
    /// path of the library root being migrated.
    static let authorizationEnvironmentKey = "MOODPAPER_AUTHORIZE_CATALOG_MIGRATION"

    /// Source of the launch environment. Tests inject a dictionary instead of
    /// mutating the process environment.
    static var environmentProvider: () -> [String: String] = {
        ProcessInfo.processInfo.environment
    }

    static let blockedDiagnostic =
        "Catalog migration blocked: explicit authorization required for real user library"

    struct MigrationBlockedError: LocalizedError {
        var errorDescription: String? { LibraryMigration.blockedDiagnostic }
    }

    static func defaultApplicationSupportLibraryRoot() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Moodpaper")
    }

    /// The user's real home-directory library, resolved through the passwd
    /// database so a sandboxed process still sees the real home rather than
    /// its container.
    static func realUserLibraryRoot() -> URL {
        let home: String
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Moodpaper", isDirectory: true)
    }

    static func resolvedLiveLibraryRoot() -> URL {
        testLiveLibraryRoot ?? defaultApplicationSupportLibraryRoot()
    }

    private static func comparablePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Roots that must never migrate without explicit authorization: the real
    /// home-directory library, this process's own default Application Support
    /// library, and the test stand-in for the live root when one is set.
    static func isProtectedLibraryRoot(_ libraryRoot: URL) -> Bool {
        var protected = liveLibraryRoots()
        if let testLiveLibraryRoot {
            protected.append(testLiveLibraryRoot)
        }
        return matches(libraryRoot, anyOf: protected)
    }

    /// The two places a real user library can actually live.
    private static func liveLibraryRoots() -> [URL] {
        [realUserLibraryRoot(), defaultApplicationSupportLibraryRoot()]
    }

    private static func matches(_ libraryRoot: URL, anyOf roots: [URL]) -> Bool {
        let candidate = comparablePath(libraryRoot)
        return roots.contains { comparablePath($0) == candidate }
    }

    /// True only when the launch environment names this exact root.
    /// Who authorized a migration. Recorded in the journal so a catalog that
    /// was published under explicit authorization can be adopted on later
    /// launches without asking again; a catalog with no such record (for
    /// example one written by a pre-guard build) stays unadopted.
    enum AuthorizationSource: String, Codable {
        /// Development and test launches: `MOODPAPER_AUTHORIZE_CATALOG_MIGRATION`.
        case environment
        /// The user confirmed the in-app library update.
        case user
    }

    /// One-shot, process-memory authorization created only after the user
    /// confirms the in-app library update. Bound to one exact resolved root,
    /// never persisted anywhere, and consumed by the next migration attempt
    /// whether it succeeds or fails.
    private static var oneShotAuthorizedRootPath: String?

    static func grantOneShotAuthorization(for libraryRoot: URL) {
        oneShotAuthorizedRootPath = comparablePath(libraryRoot)
    }

    static func clearOneShotAuthorization() {
        oneShotAuthorizedRootPath = nil
    }

    static var hasOneShotAuthorization: Bool {
        oneShotAuthorizedRootPath != nil
    }

    /// The active authorization for this exact root, if any. Both mechanisms
    /// converge here; the migration engine never asks anything else.
    static func authorizationSource(for libraryRoot: URL) -> AuthorizationSource? {
        let candidate = comparablePath(libraryRoot)
        if let raw = environmentProvider()[authorizationEnvironmentKey], !raw.isEmpty,
           comparablePath(URL(fileURLWithPath: raw)) == candidate {
            return .environment
        }
        if let oneShot = oneShotAuthorizedRootPath, oneShot == candidate {
            return .user
        }
        return nil
    }

    static func isMigrationAuthorized(for libraryRoot: URL) -> Bool {
        authorizationSource(for: libraryRoot) != nil
    }

    /// A published catalog may be adopted when the root is not protected,
    /// when the launch is authorized, or when the journal records that the
    /// completed migration was explicitly authorized.
    static func canAdoptPublishedCatalog(at libraryRoot: URL) -> Bool {
        if !isProtectedLibraryRoot(libraryRoot) { return true }
        if isMigrationAuthorized(for: libraryRoot) { return true }
        guard let journal = try? loadJournal(from: libraryRoot) else { return false }
        return journal.phase == .complete
            && journal.authorization != nil
            && journal.migrationVersion == migrationVersion
    }

    /// The single decision every migration, adoption, and publish path asks.
    static func isMigrationBlocked(for libraryRoot: URL) -> Bool {
        isProtectedLibraryRoot(libraryRoot) && !isMigrationAuthorized(for: libraryRoot)
    }

    /// Secondary, narrower rule: an XCTest host must not even load the real
    /// live library, so test runs cannot rewrite legacy moods.json. This is
    /// not the migration guard; `isMigrationBlocked` holds in every host and
    /// also covers `testLiveLibraryRoot`, which this rule deliberately skips
    /// so tests can drive a store against a protected temp root.
    static var isRunningInTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static func testHostMustNotLoadLibrary(at libraryRoot: URL) -> Bool {
        isRunningInTestHost && matches(libraryRoot, anyOf: liveLibraryRoots())
    }

    enum JournalPhase: String, Codable {
        case started
        case backupComplete
        case assetsCopying
        case catalogStaged
        case validated
        case complete
        case aborted
    }

    struct Journal: Codable, Equatable {
        var schemaVersion: Int
        var migrationVersion: Int
        var phase: JournalPhase
        var runID: String
        var backupFolderName: String?
        var sourcePathToAssetID: [String: String]
        var lastError: String?
        var startedAt: Date
        var updatedAt: Date
        /// Absent on journals written before the authorization guard.
        var authorization: AuthorizationSource?
    }

    struct Summary: Equatable {
        var assetCount: Int
        var membershipCount: Int
        var alreadyComplete: Bool
        var resumed: Bool
    }

    struct ValidationError: LocalizedError {
        var errorDescription: String?
    }

    struct InterruptedError: LocalizedError {
        var phase: JournalPhase
        var errorDescription: String? { "Migration interrupted after \(phase.rawValue)" }
    }

    static func needsMigration(libraryRoot: URL) -> Bool {
        if let catalog = try? loadCatalog(from: libraryRoot), catalog.isReady {
            return false
        }
        return !legacyImageFiles(in: libraryRoot).isEmpty
    }

    @discardableResult
    static func migrateIfNeeded(libraryRoot: URL) throws -> Summary {
        // A one-shot authorization is consumed by this attempt, success or not.
        defer { clearOneShotAuthorization() }
        if isMigrationBlocked(for: libraryRoot) {
            print("[LibraryMigration] \(blockedDiagnostic)")
            throw MigrationBlockedError()
        }
        let authorization = authorizationSource(for: libraryRoot)
        if let catalog = try? loadCatalog(from: libraryRoot), catalog.isReady {
            // A catalog completed before authorization was journaled (or by
            // an authorized run that predates the field) is stamped now so
            // later launches can adopt it without asking again.
            if let authorization,
               var journal = try? loadJournal(from: libraryRoot),
               journal.phase == .complete,
               journal.authorization == nil {
                journal.authorization = authorization
                try checkpoint(&journal, phase: .complete, libraryRoot: libraryRoot)
            }
            return Summary(
                assetCount: catalog.assets.count,
                membershipCount: catalog.memberships.count,
                alreadyComplete: true,
                resumed: false
            )
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: WallpaperCatalogFile.migrationRoot(in: libraryRoot),
            withIntermediateDirectories: true
        )

        var journal = (try? loadJournal(from: libraryRoot)) ?? Journal(
            schemaVersion: schemaVersion,
            migrationVersion: migrationVersion,
            phase: .started,
            runID: UUID().uuidString.lowercased(),
            backupFolderName: nil,
            sourcePathToAssetID: [:],
            lastError: nil,
            startedAt: Date(),
            updatedAt: Date(),
            authorization: authorization
        )
        if journal.authorization == nil {
            journal.authorization = authorization
        }
        let resumed = journal.phase != .started || journal.backupFolderName != nil
        try checkpoint(&journal, phase: .started, libraryRoot: libraryRoot)

        do {
            if journal.phase == .started || journal.backupFolderName == nil {
                journal.backupFolderName = try writeBackup(libraryRoot: libraryRoot, runID: journal.runID)
                try checkpoint(&journal, phase: .backupComplete, libraryRoot: libraryRoot)
            }

            try checkpoint(&journal, phase: .assetsCopying, libraryRoot: libraryRoot)
            let stagingRoot = WallpaperCatalogFile.stagingRoot(in: libraryRoot)
            try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let stagingAssets = stagingRoot.appendingPathComponent(
                WallpaperCatalogFile.assetsDirectoryName,
                isDirectory: true
            )
            try fileManager.createDirectory(at: stagingAssets, withIntermediateDirectories: true)

            let catalog = try buildCatalog(
                libraryRoot: libraryRoot,
                stagingAssets: stagingAssets,
                journal: &journal
            )
            try checkpoint(&journal, phase: .catalogStaged, libraryRoot: libraryRoot)

            if testCorruptStagingBeforeValidation {
                testCorruptStagingBeforeValidation = false
                let contents = try fileManager.contentsOfDirectory(
                    at: stagingAssets,
                    includingPropertiesForKeys: nil
                )
                if let first = contents.first {
                    try Data("corrupt".utf8).write(to: first)
                }
            }

            try validate(catalog, libraryRoot: libraryRoot, assetsRoot: stagingAssets)
            try checkpoint(&journal, phase: .validated, libraryRoot: libraryRoot)

            try publishCatalog(catalog, from: stagingRoot, libraryRoot: libraryRoot)
            journal.lastError = nil
            try checkpoint(&journal, phase: .complete, libraryRoot: libraryRoot)
            return Summary(
                assetCount: catalog.assets.count,
                membershipCount: catalog.memberships.count,
                alreadyComplete: false,
                resumed: resumed && journal.sourcePathToAssetID.isEmpty == false
            )
        } catch let interrupt as InterruptedError {
            throw interrupt
        } catch {
            journal.lastError = error.localizedDescription
            try? checkpoint(&journal, phase: .aborted, libraryRoot: libraryRoot)
            // Leave any incomplete catalog.json unpublished; never delete Moods/.
            throw error
        }
    }

    static func loadCatalog(from libraryRoot: URL) throws -> WallpaperCatalog {
        let data = try Data(contentsOf: WallpaperCatalogFile.catalogURL(in: libraryRoot))
        return try catalogDecoder.decode(WallpaperCatalog.self, from: data)
    }

    static func loadJournal(from libraryRoot: URL) throws -> Journal {
        let data = try Data(contentsOf: WallpaperCatalogFile.journalURL(in: libraryRoot))
        return try catalogDecoder.decode(Journal.self, from: data)
    }

    static func canonicalURL(for asset: WallpaperAsset, libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent(asset.relativePath)
    }

    // MARK: - Internals

    private static func checkpoint(
        _ journal: inout Journal,
        phase: JournalPhase,
        libraryRoot: URL
    ) throws {
        journal.phase = phase
        journal.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(journal)
        try data.write(to: WallpaperCatalogFile.journalURL(in: libraryRoot), options: .atomic)
        if let interrupt = testInterruptAfterPhase, interrupt == phase, phase != .complete {
            testInterruptAfterPhase = nil
            throw InterruptedError(phase: phase)
        }
    }

    private static func writeBackup(libraryRoot: URL, runID: String) throws -> String {
        let backups = WallpaperCatalogFile.backupsRoot(in: libraryRoot)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let name = "phase-6a-v\(migrationVersion)-\(runID)"
        let destination = backups.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            return name
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let moods = libraryRoot.appendingPathComponent("Moods", isDirectory: true)
        if FileManager.default.fileExists(atPath: moods.path) {
            try FileManager.default.copyItem(
                at: moods,
                to: destination.appendingPathComponent("Moods", isDirectory: true)
            )
        }
        let catalog = WallpaperCatalogFile.catalogURL(in: libraryRoot)
        if FileManager.default.fileExists(atPath: catalog.path) {
            try FileManager.default.copyItem(
                at: catalog,
                to: destination.appendingPathComponent(WallpaperCatalogFile.catalogFileName)
            )
        }
        return name
    }

    private static func buildCatalog(
        libraryRoot: URL,
        stagingAssets: URL,
        journal: inout Journal
    ) throws -> WallpaperCatalog {
        var catalog = WallpaperCatalog.readyEmpty()
        var identityIndex: [WallpaperAssetIdentity: String] = [:]
        let files = legacyImageFiles(in: libraryRoot)

        for file in files {
            let sourcePath = file.url.standardizedFileURL.path
            let hash = try WallpaperIdentity.sha256Hex(of: file.url)
            let byteCount = try file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let metadata = WallpaperIdentity.imageMetadata(at: file.url)
            let identity: WallpaperAssetIdentity? = {
                guard let metadata else { return nil }
                return WallpaperAssetIdentity(
                    contentHash: hash,
                    byteCount: byteCount,
                    pixelWidth: metadata.width,
                    pixelHeight: metadata.height
                )
            }()

            let assetID: String
            if let identity, let existingID = identityIndex[identity] {
                assetID = existingID
            } else if let existingID = journal.sourcePathToAssetID[sourcePath] {
                assetID = existingID
            } else {
                assetID = UUID().uuidString.lowercased()
            }

            if let identity {
                identityIndex[identity] = assetID
            }

            let ext = file.url.pathExtension.isEmpty ? "jpg" : file.url.pathExtension.lowercased()
            let relative = "\(WallpaperCatalogFile.assetsFolderName)/\(WallpaperCatalogFile.assetsDirectoryName)/\(assetID).\(ext)"
            let destination = stagingAssets.appendingPathComponent("\(assetID).\(ext)")

            if var existing = catalog.asset(id: assetID) {
                if !existing.legacySourcePaths.contains(sourcePath) {
                    existing.legacySourcePaths.append(sourcePath)
                }
                catalog.upsert(existing)
            } else {
                catalog.upsert(
                    WallpaperAsset(
                        id: assetID,
                        originalFilename: file.url.lastPathComponent,
                        relativePath: relative,
                        contentHash: hash,
                        byteCount: byteCount,
                        pixelWidth: metadata?.width,
                        pixelHeight: metadata?.height,
                        uti: metadata?.uti,
                        createdAt: Date(),
                        legacySourcePaths: [sourcePath]
                    )
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: file.url, to: destination)
            }

            journal.sourcePathToAssetID[sourcePath] = assetID
            try checkpoint(&journal, phase: .assetsCopying, libraryRoot: libraryRoot)

            var membership = catalog.memberships.first {
                $0.assetID == assetID && $0.moodID == file.moodID
            } ?? WallpaperMembership(
                assetID: assetID,
                moodID: file.moodID,
                throughoutTheDay: false,
                slotIDs: []
            )
            if file.folderName == "AllDay" {
                membership.throughoutTheDay = true
            } else if TimeSlot(rawValue: file.folderName) != nil {
                if !membership.slotIDs.contains(file.folderName) {
                    membership.slotIDs.append(file.folderName)
                    membership.slotIDs.sort()
                }
            }
            catalog.replaceMembership(membership)
        }

        // Identity is settled above by content; only the visible name is chosen
        // here, once every equivalent legacy source is known.
        for var asset in catalog.assets {
            if let name = preferredOriginalFilename(forLegacySourcePaths: asset.legacySourcePaths) {
                asset.originalFilename = name
                catalog.upsert(asset)
            }
        }

        return catalog
    }

    /// The name a deduplicated asset shows to the user. Prefers a file the
    /// user placed in a Vibe's general (AllDay) pool over a period copy the
    /// app generated, then the shortest basename, then a stable lexical
    /// order, so `lake.png` wins over `lake-copy.png` and over
    /// `Morning/lake.png` no matter how the paths happen to sort.
    static func preferredOriginalFilename(forLegacySourcePaths paths: [String]) -> String? {
        let ranked = paths.map { path -> (isGeneral: Bool, basename: String, path: String) in
            let url = URL(fileURLWithPath: path)
            let folder = url.deletingLastPathComponent().lastPathComponent
            return (folder == "AllDay", url.lastPathComponent, path)
        }
        let best = ranked.min { lhs, rhs in
            if lhs.isGeneral != rhs.isGeneral { return lhs.isGeneral }
            if lhs.basename.count != rhs.basename.count { return lhs.basename.count < rhs.basename.count }
            if lhs.basename != rhs.basename { return lhs.basename < rhs.basename }
            return lhs.path < rhs.path
        }
        return best?.basename
    }

    private static func validate(
        _ catalog: WallpaperCatalog,
        libraryRoot: URL,
        assetsRoot: URL
    ) throws {
        let legacy = legacyImageFiles(in: libraryRoot)
        let accounted = Set(catalog.assets.flatMap(\.legacySourcePaths))
        for file in legacy {
            let path = file.url.standardizedFileURL.path
            guard accounted.contains(path) else {
                throw ValidationError(errorDescription: "Legacy file was not catalogued: \(path)")
            }
        }

        var seenIdentity: [WallpaperAssetIdentity: String] = [:]
        for asset in catalog.assets {
            let url = assetsRoot.appendingPathComponent((asset.relativePath as NSString).lastPathComponent)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError(errorDescription: "Canonical file missing for \(asset.id)")
            }
            let hash = try WallpaperIdentity.sha256Hex(of: url)
            guard hash == asset.contentHash else {
                throw ValidationError(errorDescription: "Canonical hash mismatch for \(asset.id)")
            }
            if let identity = asset.identityKey {
                if let other = seenIdentity[identity], other != asset.id {
                    throw ValidationError(errorDescription: "Duplicate identity published as distinct assets")
                }
                seenIdentity[identity] = asset.id
            }
        }

        let moodIDs = Set((try? decodeMoodIDs(in: libraryRoot)) ?? [])
        for membership in catalog.memberships {
            guard catalog.asset(id: membership.assetID) != nil else {
                throw ValidationError(errorDescription: "Membership references missing asset")
            }
            if !moodIDs.isEmpty {
                guard moodIDs.contains(membership.moodID) else {
                    throw ValidationError(errorDescription: "Membership references missing Vibe")
                }
            }
        }
    }

    private static func publishCatalog(
        _ catalog: WallpaperCatalog,
        from stagingRoot: URL,
        libraryRoot: URL
    ) throws {
        if isMigrationBlocked(for: libraryRoot) {
            throw MigrationBlockedError()
        }
        let fileManager = FileManager.default
        let liveAssets = WallpaperCatalogFile.assetsRoot(in: libraryRoot)
        try fileManager.createDirectory(
            at: liveAssets.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stagingAssets = stagingRoot.appendingPathComponent(
            WallpaperCatalogFile.assetsDirectoryName,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: liveAssets.path) {
            // Resume: fill any missing canonical files, never replace validated ones.
            let staged = try fileManager.contentsOfDirectory(at: stagingAssets, includingPropertiesForKeys: nil)
            for file in staged {
                let dest = liveAssets.appendingPathComponent(file.lastPathComponent)
                if !fileManager.fileExists(atPath: dest.path) {
                    try fileManager.copyItem(at: file, to: dest)
                }
            }
        } else {
            try fileManager.copyItem(at: stagingAssets, to: liveAssets)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(catalog).write(
            to: WallpaperCatalogFile.catalogURL(in: libraryRoot),
            options: .atomic
        )
    }

    private static var catalogDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func legacyImageFiles(in libraryRoot: URL) -> [(url: URL, moodID: String, folderName: String)] {
        let moodsRoot = libraryRoot.appendingPathComponent("Moods", isDirectory: true)
        guard let moodFolders = try? FileManager.default.contentsOfDirectory(
            at: moodsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [(url: URL, moodID: String, folderName: String)] = []
        for moodFolder in moodFolders {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: moodFolder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  moodFolder.lastPathComponent != "moods.json" else { continue }
            let moodID = moodFolder.lastPathComponent
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: moodFolder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for folder in children {
                var folderIsDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &folderIsDirectory),
                      folderIsDirectory.boolValue else { continue }
                let folderName = folder.lastPathComponent
                guard folderName == "AllDay" || TimeSlot(rawValue: folderName) != nil else {
                    continue
                }
                let images = (try? FileManager.default.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for image in images where supportedImageExtensions.contains(image.pathExtension.lowercased()) {
                    files.append((image, moodID, folderName))
                }
            }
        }
        return files.sorted { $0.url.path < $1.url.path }
    }

    private static func decodeMoodIDs(in libraryRoot: URL) throws -> [String] {
        let url = libraryRoot.appendingPathComponent("Moods").appendingPathComponent("moods.json")
        let data = try Data(contentsOf: url)
        let moods = try JSONDecoder().decode([Mood].self, from: data)
        return moods.map(\.id)
    }
}
