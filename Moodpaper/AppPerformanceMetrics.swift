import Foundation
internal import Combine

@MainActor
final class AppPerformanceMetrics: ObservableObject {
    static let shared = AppPerformanceMetrics()

    @Published private(set) var lastPreviewDecodeDurationMs: Double?
    @Published private(set) var averagePreviewDecodeDurationMs: Double?
    @Published private(set) var lastWallpaperApplyDurationMs: Double?
    @Published private(set) var averageWallpaperApplyDurationMs: Double?
    @Published private(set) var wallpaperRollbackCount: Int = 0

    private var previewSampleCount = 0
    private var wallpaperApplySampleCount = 0

    private init() {}

    func recordPreviewDecode(durationMs: Double) {
        lastPreviewDecodeDurationMs = durationMs
        previewSampleCount += 1
        if let currentAverage = averagePreviewDecodeDurationMs {
            averagePreviewDecodeDurationMs = ((currentAverage * Double(previewSampleCount - 1)) + durationMs) / Double(previewSampleCount)
        } else {
            averagePreviewDecodeDurationMs = durationMs
        }
    }

    func recordWallpaperApply(durationMs: Double) {
        lastWallpaperApplyDurationMs = durationMs
        wallpaperApplySampleCount += 1
        if let currentAverage = averageWallpaperApplyDurationMs {
            averageWallpaperApplyDurationMs = ((currentAverage * Double(wallpaperApplySampleCount - 1)) + durationMs) / Double(wallpaperApplySampleCount)
        } else {
            averageWallpaperApplyDurationMs = durationMs
        }
    }

    func recordWallpaperRollback() {
        wallpaperRollbackCount += 1
    }
}
