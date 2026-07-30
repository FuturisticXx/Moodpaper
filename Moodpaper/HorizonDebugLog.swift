import Foundation

/// File-based logger for diagnosing intermittent issues in Debug and Release builds.
///
/// Opt-in via Diagnostics → Debug Logging. Writes to
/// `~/Library/Logs/Moodpaper/moodpaper-debug.log`, rotated daily, keeps the 7 most
/// recent days. All writes are serialized on a dedicated queue; call sites never
/// block the main thread and never crash on I/O errors.
final class HorizonDebugLog {
    static let shared = HorizonDebugLog()

    private let queue = DispatchQueue(label: "com.horizon.debuglog", qos: .utility)
    private let isoFormatter: ISO8601DateFormatter
    private let dayFormatter: DateFormatter
    private let maxRotatedFiles = 7
    private var lastWriteDay: String = ""

    private init() {
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: HorizonScheduleDefaults.debugLoggingEnabledKey)
    }

    var logsDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/Moodpaper", isDirectory: true)
    }

    var currentLogFile: URL {
        logsDirectory.appendingPathComponent("moodpaper-debug.log")
    }

    var currentLogSize: Int {
        (try? FileManager.default.attributesOfItem(atPath: currentLogFile.path)[.size] as? Int) ?? 0
    }

    /// Log a structured event. No-op when the toggle is off.
    func log(_ event: String, fields: [String: Any] = [:]) {
        guard isEnabled else { return }
        let now = Date()
        let timestamp = isoFormatter.string(from: now)
        let day = dayFormatter.string(from: now)
        let line = format(timestamp: timestamp, event: event, fields: fields)
        queue.async { [weak self] in
            self?.writeLine(line, day: day)
        }
    }

    /// Delete the logs directory. The next enabled write will recreate it.
    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: self.logsDirectory)
            self.lastWriteDay = ""
        }
    }

    // MARK: - Private

    private func format(timestamp: String, event: String, fields: [String: Any]) -> String {
        var parts = ["[\(timestamp)]", event]
        for key in fields.keys.sorted() {
            parts.append("\(key)=\(encode(fields[key]))")
        }
        return parts.joined(separator: " ") + "\n"
    }

    private func encode(_ value: Any?) -> String {
        guard let value else { return "nil" }
        let raw = "\(value)"
        if raw.isEmpty { return "\"\"" }
        if raw.contains(" ") || raw.contains("=") || raw.contains("\"") {
            let escaped = raw.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return raw
    }

    private func writeLine(_ line: String, day: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        // Rotate if the log is stale from a previous day.
        var rotateFromDay: String? = nil
        if lastWriteDay.isEmpty {
            if let attrs = try? fm.attributesOfItem(atPath: currentLogFile.path),
               let mtime = attrs[.modificationDate] as? Date {
                let mtimeDay = dayFormatter.string(from: mtime)
                if mtimeDay != day { rotateFromDay = mtimeDay }
            }
        } else if lastWriteDay != day {
            rotateFromDay = lastWriteDay
        }
        if let prev = rotateFromDay {
            rotate(previousDay: prev)
        }
        lastWriteDay = day

        let path = currentLogFile.path
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: currentLogFile) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private func rotate(previousDay: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: currentLogFile.path) else { return }
        let rotated = logsDirectory.appendingPathComponent("horizon-debug.\(previousDay).log")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: currentLogFile, to: rotated)
        pruneOldRotations()
    }

    private func pruneOldRotations() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let rotated = files.filter {
            $0.lastPathComponent.hasPrefix("horizon-debug.")
                && $0.pathExtension == "log"
                && $0.lastPathComponent != "horizon-debug.log"
        }
        guard rotated.count > maxRotatedFiles else { return }
        let sorted = rotated.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        for old in sorted.dropFirst(maxRotatedFiles) {
            try? fm.removeItem(at: old)
        }
    }
}
