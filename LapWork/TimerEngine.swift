//
//  TimerEngine.swift
//  LapWork
//
//  The brain: lap countdown, Gas math, diary/day state. @MainActor so all
//  @Published mutation and AppKit calls (NSSound) are main-isolated, which
//  keeps Swift 6 strict concurrency happy.
//
//  Timekeeping is based on absolute wall-clock dates (lapStartDate, breakStart)
//  rather than decrementing counters, so countdowns stay correct across app
//  sleep, lag, and quit/restart.
//

import Foundation
import Combine
import AppKit

@MainActor
final class TimerEngine: ObservableObject {

    // MARK: - Published UI state

    @Published private(set) var state: PersistedState
    /// A monotonically updated "now" that drives live countdown/Gas redraws.
    @Published private(set) var now: Date = Date()

    private let store = DiaryStore.shared
    private let notifier = NotificationManager.shared
    private var ticker: Task<Void, Never>?

    // MARK: - Init / restore

    init() {
        self.state = DiaryStore.shared.loadState()
        restoreOnLaunch()
        startTicking()
    }

    /// Reconcile persisted state with the real clock at launch.
    private func restoreOnLaunch() {
        // New day while we were away → fresh day (use-it-or-lose-it Gas).
        let today = DiaryStore.dayKey()
        if state.dayKey != today {
            rolloverToNewDay(today)
        }

        // A lap was running when we quit. If its end time has already passed,
        // complete it now (and ring); otherwise it simply keeps running. We do
        // NOT auto-advance the tempo cadence here: replaying laps across time
        // the app was closed would fabricate work that never happened, so the
        // cadence simply pauses in the ready state.
        if let lapNo = state.runningLapNumber, let start = state.lapStartDate {
            let end = start.addingTimeInterval(state.settings.lapLengthMin * 60)
            if Date() >= end {
                completeRunningLap(at: end, lapNumber: lapNo, start: start, autoAdvance: false)
            }
        }

        // A mandatory rest was counting down when we quit. If it already
        // finished, end it (logging the rest) but don't auto-start the next lap
        // — same reason as above. If it's still within its window, it keeps
        // counting and the ticker will advance it normally.
        if state.restActive, let restStart = state.restStartDate {
            let restEnd = restStart.addingTimeInterval(state.settings.restLengthSec)
            if Date() >= restEnd {
                endRest(at: restEnd, autoAdvance: false)
            }
        }
        persist()
    }

    // MARK: - Derived values

    var settings: FocusSettings { state.settings }
    var diaryOpen: Bool { state.diaryOpen }
    var isLapRunning: Bool { state.runningLapNumber != nil }
    var isBreakActive: Bool { state.breakActive }

    /// True while a mandatory tempo rest is counting down between laps.
    var isResting: Bool { state.restActive }
    /// True when the tempo cadence is live (a running lap or a mandatory rest).
    var isTempoRunning: Bool { state.restActive || (isLapRunning && settings.tempoModeEnabled) }
    /// True when the current tempo lap is set to stop the cadence when it ends.
    var tempoStopPending: Bool { state.tempoStopRequested }

    /// Seconds remaining in the running lap (0 if none).
    var lapRemaining: TimeInterval {
        guard let start = state.lapStartDate else { return 0 }
        let end = start.addingTimeInterval(state.settings.lapLengthMin * 60)
        return max(0, end.timeIntervalSince(now))
    }

    /// Seconds remaining in the mandatory rest (0 if not resting).
    var restRemaining: TimeInterval {
        guard let start = state.restStartDate else { return 0 }
        let end = start.addingTimeInterval(state.settings.restLengthSec)
        return max(0, end.timeIntervalSince(now))
    }

    /// Live Gas in minutes: banked value, minus any in-progress break drain.
    var currentGas: Double {
        guard state.breakActive, let bs = state.breakStartDate else { return state.bankedGas }
        let drainedMin = now.timeIntervalSince(bs) / 60.0
        return max(settings.overdraftFloor, state.gasAtBreakStart - drainedMin)
    }

    /// True when Gas is at/below the overdraft floor (break must stop / can't start).
    var atOverdraftFloor: Bool { currentGas <= settings.overdraftFloor + 0.0001 }

    var canTakeBreak: Bool {
        diaryOpen && !isLapRunning && !isResting && !atOverdraftFloor
    }

    /// The string shown in the menu bar.
    var menuBarTitle: String {
        guard state.diaryOpen else { return "⊙" }
        if state.breakActive {
            return "☕ \(Self.clock(minutes: currentGas))"
        }
        if state.restActive {
            return "rest · \(Self.mmss(restRemaining))"
        }
        if let lapNo = state.runningLapNumber {
            return "L\(lapNo) · \(Self.mmss(lapRemaining))"
        }
        if let done = state.justCompletedLapNumber {
            return "L\(done) done"
        }
        return "L\(state.nextLapNumber) ▸"
    }

    /// Format a duration given in SECONDS as m:ss (e.g. countdown).
    static func mmss(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Format a duration given in MINUTES (possibly negative) as m:ss, like a
    /// lap clock — used for Gas / break time. e.g. 2.4 → "2:24", -1.5 → "-1:30".
    static func clock(minutes: Double) -> String {
        let totalSeconds = Int((abs(minutes) * 60).rounded())
        let body = String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
        return minutes < 0 ? "-\(body)" : body
    }

    /// Format a duration given in SECONDS as compact hours/minutes for the day
    /// summary, e.g. 5820 → "1h 37m", 1080 → "18m", 0 → "0m".
    static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let totalMin = Int((seconds / 60).rounded())
        let h = totalMin / 60, m = totalMin % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    /// A wall-clock time of day, "HH:mm" local (e.g. "09:12"), for the span line.
    static func timeOfDay(_ date: Date) -> String {
        timeOfDayFormatter.string(from: date)
    }

    private static let timeOfDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    // MARK: - Diary ritual

    func openDiary() {
        let today = DiaryStore.dayKey()
        if state.dayKey != today {
            rolloverToNewDay(today)
        } else if state.dayKey.isEmpty {
            state.dayKey = today
        }
        state.diaryOpen = true
        // Start the span clock for this session, and clear any prior summary.
        state.diaryOpenedAt = Date()
        state.lastSummary = nil
        persist()
    }

    /// Finalize the day: flush Gas (use it or lose it), make export ready,
    /// reset lap numbering. Permanent lap logs are untouched.
    func completeDiary() {
        if state.breakActive { stopBreak() }
        if state.restActive { endRest(at: Date(), autoAdvance: false) } // log the rest so far
        if isLapRunning { cancelLap() } // an unfinished lap is forfeited
        let end = Date()
        state.lastSummary = makeSummary(day: state.dayKey, end: end)
        state.diaryOpen = false
        state.diaryOpenedAt = nil
        state.bankedGas = 0
        state.nextLapNumber = 1
        state.justCompletedLapNumber = nil
        state.tempoStopRequested = false
        // Day key stays as-is; the next openDiary on a new calendar day rolls over.
        persist()
    }

    /// Build the wrap-up for the day being completed, from the permanent log
    /// (untouched by the flush) plus the diary open/close timestamps. Rest and
    /// idle are measured in wall-clock time; idle is whatever the span isn't.
    private func makeSummary(day: String, end: Date) -> DaySummary {
        let laps = store.allLaps().filter { $0.date == day }
        let breaks = store.allBreaks().filter { $0.date == day }

        let lapTime = laps.reduce(0.0) { $0 + $1.endTime.timeIntervalSince($1.startTime) }
        let breakTime = breaks.reduce(0.0) { $0 + $1.endTime.timeIntervalSince($1.startTime) }
        let gas = laps.reduce(0.0) { $0 + $1.gasEarnedMin }

        // Span starts at diary open; fall back to the earliest logged event if
        // an older state carried no open timestamp.
        let earliest = (laps.map(\.startTime) + breaks.map(\.startTime)).min()
        let start = state.diaryOpenedAt ?? earliest ?? end

        let span = max(0, end.timeIntervalSince(start))
        let idle = max(0, span - lapTime - breakTime)

        return DaySummary(
            day: day,
            start: start,
            end: end,
            lapCount: laps.count,
            lapTimeSec: lapTime,
            breakTimeSec: breakTime,
            idleTimeSec: idle,
            gasEarnedMin: gas
        )
    }

    private func rolloverToNewDay(_ today: String) {
        state.dayKey = today
        state.bankedGas = 0
        state.nextLapNumber = 1
        state.runningLapNumber = nil
        state.lapStartDate = nil
        state.justCompletedLapNumber = nil
        state.diaryOpenedAt = nil
        state.breakActive = false
        state.breakStartDate = nil
        state.restActive = false
        state.restStartDate = nil
        state.tempoStopRequested = false
    }

    // MARK: - Laps

    func startLap() {
        guard state.diaryOpen, !isLapRunning, !isResting else { return }
        if state.breakActive { stopBreak() } // can't run a lap and a break at once
        beginLap(at: Date())
        persist()
    }

    /// Begin the next lap at a specific wall-clock instant. Shared by the manual
    /// Start button (at "now") and the tempo cadence (at the instant the rest
    /// ended, to keep the cadence drift-free).
    private func beginLap(at start: Date) {
        state.runningLapNumber = state.nextLapNumber
        state.lapStartDate = start
        state.justCompletedLapNumber = nil
    }

    /// Forfeit the running lap. Earns nothing, logs nothing. Also stops the
    /// tempo cadence (a forfeited lap ends the run).
    func cancelLap() {
        guard isLapRunning else { return }
        state.runningLapNumber = nil
        state.lapStartDate = nil
        state.tempoStopRequested = false
        persist()
    }

    /// Request the tempo cadence stop cleanly once the current lap finishes.
    /// The lap still completes and counts; no rest follows. Tapping again while
    /// pending resumes the cadence. Only meaningful during a tempo lap.
    func toggleTempoStop() {
        guard isLapRunning, settings.tempoModeEnabled else { return }
        state.tempoStopRequested.toggle()
        persist()
    }

    /// Stop the cadence during a mandatory rest: end the rest now (logging the
    /// partial rest as real rest time) and return to the ready state.
    func stopTempo() {
        guard state.restActive else { return }
        endRest(at: Date(), autoAdvance: false)
        persist()
    }

    /// Called by the ticker when a running lap's countdown reaches zero.
    /// `autoAdvance` drives the tempo cadence (start a rest afterward); it is
    /// false when replaying a completion at launch so we never fabricate a
    /// chain of laps across time the app was closed.
    private func completeRunningLap(at end: Date, lapNumber: Int, start: Date, autoAdvance: Bool) {
        let s = state.settings
        let earned = s.gasPerLapMin

        let record = LapRecord(
            date: DiaryStore.dayKey(for: start),
            lapNumber: lapNumber,
            startTime: start,
            endTime: end,
            lapLengthMin: s.lapLengthMin,
            accrualPercent: s.accrualPercent,
            gasEarnedMin: earned
        )
        store.appendLap(record)

        state.bankedGas += earned
        state.runningLapNumber = nil
        state.lapStartDate = nil
        state.justCompletedLapNumber = lapNumber
        state.nextLapNumber = lapNumber + 1

        ringLapEnd(lapNumber: lapNumber)

        // Tempo cadence: begin the mandatory rest, unless a stop was requested.
        if autoAdvance && s.tempoModeEnabled && !state.tempoStopRequested {
            startRest(from: end)
        } else {
            state.tempoStopRequested = false
        }
    }

    // MARK: - Tempo rest

    /// Begin the mandatory rest between tempo laps, timed from `date`.
    private func startRest(from date: Date) {
        state.restActive = true
        state.restStartDate = date
    }

    /// End the mandatory rest. Logs it as real rest time (a break event with no
    /// Gas drained), then — when `autoAdvance` — auto-starts the next lap at the
    /// rest's end instant to keep the cadence tight.
    private func endRest(at end: Date, autoAdvance: Bool) {
        if let restStart = state.restStartDate, end > restStart {
            store.appendBreak(BreakEvent(
                date: DiaryStore.dayKey(for: restStart),
                startTime: restStart,
                endTime: end,
                drainedMin: 0
            ))
        }
        state.restActive = false
        state.restStartDate = nil

        if autoAdvance {
            beginLap(at: end)
        }
    }

    // MARK: - Breaks

    func toggleBreak() {
        if state.breakActive { stopBreak() } else { startBreak() }
    }

    func startBreak() {
        guard canTakeBreak else { return }
        state.breakActive = true
        state.breakStartDate = Date()
        state.gasAtBreakStart = state.bankedGas
        persist()
    }

    func stopBreak() {
        guard state.breakActive, let bs = state.breakStartDate else { return }
        let end = Date()
        let remaining = currentGas                       // already floor-clamped
        let drained = state.gasAtBreakStart - remaining
        state.bankedGas = remaining
        state.breakActive = false
        state.breakStartDate = nil

        if drained > 0.0001 {
            store.appendBreak(BreakEvent(
                date: DiaryStore.dayKey(for: bs),
                startTime: bs,
                endTime: end,
                drainedMin: drained
            ))
        }
        persist()
    }

    // MARK: - Settings

    func updateSettings(_ newSettings: FocusSettings) {
        state.settings = newSettings
        persist()
    }

    // MARK: - Bell + banner

    private func ringLapEnd(lapNumber: Int) {
        if state.settings.soundEnabled {
            (NSSound(named: "Glass") ?? NSSound(named: "Ping"))?.play()
        }
        if state.settings.notificationsEnabled {
            notifier.postLapEnd(lapNumber: lapNumber,
                                gas: state.bankedGas,
                                playSound: state.settings.soundEnabled)
        }
    }

    // MARK: - Ticker

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                self?.tick()
            }
        }
    }

    private func tick() {
        now = Date()

        // Auto-complete a finished lap. In tempo mode this starts the rest.
        if let lapNo = state.runningLapNumber, let start = state.lapStartDate {
            let end = start.addingTimeInterval(state.settings.lapLengthMin * 60)
            if now >= end {
                completeRunningLap(at: end, lapNumber: lapNo, start: start, autoAdvance: true)
                persist()
            }
        }

        // Auto-advance the tempo cadence: when the mandatory rest ends, log it
        // and start the next lap at the rest's end instant.
        if state.restActive, let restStart = state.restStartDate {
            let restEnd = restStart.addingTimeInterval(state.settings.restLengthSec)
            if now >= restEnd {
                endRest(at: restEnd, autoAdvance: true)
                persist()
            }
        }

        // Auto-stop a break that has drained to the floor.
        if state.breakActive, atOverdraftFloor {
            stopBreak()
        }
    }

    // MARK: - Persistence

    private func persist() {
        store.saveState(state)
    }
}
