//
//  Models.swift
//  LapWork
//
//  Core value types: user settings, the permanent lap log, and break events.
//  These are deliberately plain Codable structs so they survive quit/restart
//  and serialize cleanly to JSON (state) and CSV (the experiment export).
//

import Foundation

/// User-tunable knobs. Persisted as part of `PersistedState`.
struct FocusSettings: Codable, Equatable, Sendable {
    /// Length of a single focus lap, in minutes.
    var lapLengthMin: Double = 12
    /// Fraction of a completed lap banked as Gas, expressed 0–100.
    var accrualPercent: Double = 20
    /// How far Gas may go negative, stored as a positive magnitude (floor = -this).
    var overdraftFloorMin: Double = 5
    /// Ring a bell when a lap ends.
    var soundEnabled: Bool = true
    /// Post a system notification banner when a lap ends.
    var notificationsEnabled: Bool = true

    /// Tempo mode: when on, one "Start Lap" kicks off a continuous cadence —
    /// laps run back-to-back with a fixed mandatory rest between each, until
    /// the user stops it. When off, laps advance manually (the default).
    var tempoModeEnabled: Bool = false
    /// Length of the mandatory rest between laps in tempo mode, in seconds.
    /// This rest is "free" — it never touches the Gas bank.
    var restLengthSec: Double = 30

    /// Gas earned by completing one full lap at the current settings, in minutes.
    var gasPerLapMin: Double { lapLengthMin * (accrualPercent / 100.0) }

    /// The (negative) Gas floor in minutes.
    var overdraftFloor: Double { -abs(overdraftFloorMin) }
}

/// One PERMANENT record of a completed lap. This is the experiment data —
/// it is never touched by the daily Gas flush. Partial/forfeited laps are
/// never recorded.
struct LapRecord: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    /// Local calendar day, "yyyy-MM-dd". Lap numbering resets each day.
    var date: String
    /// Lap number within `date`, starting at 1.
    var lapNumber: Int
    var startTime: Date
    var endTime: Date
    /// Lap length in effect when this lap ran (minutes).
    var lapLengthMin: Double
    /// Accrual percent in effect when this lap ran (0–100).
    var accrualPercent: Double
    /// Gas added to the bank by completing this lap (minutes).
    var gasEarnedMin: Double
}

/// One PERMANENT record of a break: a stretch where Gas was drained live.
struct BreakEvent: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var date: String
    var startTime: Date
    var endTime: Date
    /// How much Gas was drained over this break (minutes).
    var drainedMin: Double
}

/// A wrap-up of a single diary session, computed when the diary is completed.
/// Breaks the "diary open → diary complete" span into where the time went:
/// focus laps, rest (breaks), and idle (nothing logged — e.g. logged off).
struct DaySummary: Codable, Sendable {
    var day: String
    /// When the diary was opened and completed for this session.
    var start: Date
    var end: Date
    /// Number of completed laps logged on `day`.
    var lapCount: Int
    /// Total wall-clock time inside completed laps (seconds).
    var lapTimeSec: TimeInterval
    /// Total wall-clock time inside breaks (seconds).
    var breakTimeSec: TimeInterval
    /// Time in the span accounted for by neither laps nor breaks (seconds).
    var idleTimeSec: TimeInterval
    /// Total Gas earned across the session's laps (minutes).
    var gasEarnedMin: Double

    /// Full diary span, start → end (seconds).
    var spanSec: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// Everything ephemeral that must survive quit/restart but is NOT experiment
/// data: the live Gas counter, lap progress, diary state, and settings.
/// Stored as a single JSON blob in UserDefaults.
struct PersistedState: Codable, Sendable {
    var settings = FocusSettings()

    /// Live Gas balance in minutes. Flushed to 0 at the daily reset.
    var bankedGas: Double = 0

    /// The calendar day this state belongs to, "yyyy-MM-dd".
    var dayKey: String = ""

    /// True while the diary is open (session mode).
    var diaryOpen: Bool = false

    /// Wall-clock moment the diary was opened this session (for the span in the
    /// completion summary). Nil when the diary is closed.
    var diaryOpenedAt: Date? = nil

    /// Summary of the most recently completed diary session, shown until the
    /// next diary is opened. Nil before any completion this cycle.
    var lastSummary: DaySummary? = nil

    /// The lap number that "Start Lap" will begin next (resets to 1 each day).
    var nextLapNumber: Int = 1

    /// Non-nil while a lap is actively running.
    var runningLapNumber: Int? = nil
    /// Wall-clock start of the running lap (for drift-free countdown).
    var lapStartDate: Date? = nil

    /// The just-completed lap number, held for the "L7 done" display until the
    /// next lap is started. Cleared on start / diary complete.
    var justCompletedLapNumber: Int? = nil

    // Live break drain (also resumed across restart).
    var breakActive: Bool = false
    var breakStartDate: Date? = nil
    var gasAtBreakStart: Double = 0

    // Tempo mode: the mandatory rest between laps. Wall-clock based so it
    // resumes across restart. `restActive` is distinct from `breakActive` —
    // a mandatory rest drains no Gas.
    var restActive: Bool = false
    var restStartDate: Date? = nil
    /// Set while a tempo lap is running to request the cadence stop cleanly
    /// after this lap completes (the lap still counts; no rest follows).
    var tempoStopRequested: Bool = false
}
