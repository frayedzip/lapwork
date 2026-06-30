//
//  DiaryStore.swift
//  LapWork
//
//  Persistence layer with two distinct concerns kept deliberately separate:
//
//   1. Ephemeral state (Gas, lap progress, diary flags, settings) → UserDefaults.
//      This is allowed to be flushed/reset by the daily ritual.
//
//   2. PERMANENT experiment data (completed laps + break events) → a JSON file
//      in Application Support. This is append-only and is NEVER cleared by the
//      Gas flush. It is the whole point of the app.
//
//  Also owns CSV export, the format used for external analysis.
//

import Foundation

@MainActor
final class DiaryStore {
    static let shared = DiaryStore()

    private let defaults = UserDefaults.standard
    private let stateKey = "lapwork.state.v1"

    // MARK: - Date helpers

    /// "yyyy-MM-dd" in the user's current calendar/timezone.
    static func dayKey(for date: Date = Date()) -> String {
        dayKeyFormatter.string(from: date)
    }

    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "HH:mm:ss" local, for CSV start/end columns.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Ephemeral state (UserDefaults)

    func loadState() -> PersistedState {
        guard let data = defaults.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else {
            return PersistedState()
        }
        return state
    }

    func saveState(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: stateKey)
    }

    // MARK: - Permanent log (Application Support JSON, append-only)

    private struct LogFile: Codable {
        var laps: [LapRecord] = []
        var breaks: [BreakEvent] = []
    }

    private var logURL: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("LapWork", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("log.json")
    }

    private func readLog() -> LogFile {
        guard let data = try? Data(contentsOf: logURL),
              let log = try? JSONDecoder().decode(LogFile.self, from: data)
        else { return LogFile() }
        return log
    }

    private func writeLog(_ log: LogFile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(log) else { return }
        try? data.write(to: logURL, options: .atomic)
    }

    /// Append a completed lap. Permanent — never removed by the Gas flush.
    func appendLap(_ record: LapRecord) {
        var log = readLog()
        log.laps.append(record)
        writeLog(log)
    }

    /// Append a finished break event. Permanent.
    func appendBreak(_ event: BreakEvent) {
        var log = readLog()
        log.breaks.append(event)
        writeLog(log)
    }

    func allLaps() -> [LapRecord] { readLog().laps }
    func allBreaks() -> [BreakEvent] { readLog().breaks }

    // MARK: - CSV export

    private func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    /// Build a per-day CSV: a lap section keyed by lap number, then a break
    /// section for the same day. Returns nil if there is no data for that day.
    func csv(for day: String) -> String? {
        let laps = allLaps().filter { $0.date == day }.sorted { $0.lapNumber < $1.lapNumber }
        let breaks = allBreaks().filter { $0.date == day }.sorted { $0.startTime < $1.startTime }
        guard !laps.isEmpty || !breaks.isEmpty else { return nil }

        var lines: [String] = []
        let tf = Self.timeFormatter

        // Lap section.
        lines.append("date,lap_number,start_time,end_time,lap_length_min,accrual_percent,gas_earned_min")
        for lap in laps {
            lines.append([
                lap.date,
                String(lap.lapNumber),
                tf.string(from: lap.startTime),
                tf.string(from: lap.endTime),
                String(format: "%.2f", lap.lapLengthMin),
                String(format: "%.0f", lap.accrualPercent),
                String(format: "%.2f", lap.gasEarnedMin)
            ].map(escape).joined(separator: ","))
        }

        // Break section.
        lines.append("")
        lines.append("break_index,date,start_time,end_time,gas_drained_min")
        for (i, ev) in breaks.enumerated() {
            lines.append([
                String(i + 1),
                ev.date,
                tf.string(from: ev.startTime),
                tf.string(from: ev.endTime),
                String(format: "%.2f", ev.drainedMin)
            ].map(escape).joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Distinct days that have any logged data, newest first.
    func loggedDays() -> [String] {
        var set = Set<String>()
        allLaps().forEach { set.insert($0.date) }
        allBreaks().forEach { set.insert($0.date) }
        return set.sorted(by: >)
    }

    /// Write a day's CSV into Application Support/LapWork/exports and return
    /// the file URL (or nil if there was nothing to export).
    @discardableResult
    func exportCSVFile(for day: String) -> URL? {
        guard let csv = csv(for: day) else { return nil }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("LapWork/exports", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("LapWork-\(day).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
