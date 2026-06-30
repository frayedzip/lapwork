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
        // complete it now (and ring); otherwise it simply keeps running.
        if let lapNo = state.runningLapNumber, let start = state.lapStartDate {
            let end = start.addingTimeInterval(state.settings.lapLengthMin * 60)
            if Date() >= end {
                completeRunningLap(at: end, lapNumber: lapNo, start: start)
            }
        }
        persist()
    }

    // MARK: - Derived values

    var settings: FocusSettings { state.settings }
    var diaryOpen: Bool { state.diaryOpen }
    var isLapRunning: Bool { state.runningLapNumber != nil }
    var isBreakActive: Bool { state.breakActive }

    /// Seconds remaining in the running lap (0 if none).
    var lapRemaining: TimeInterval {
        guard let start = state.lapStartDate else { return 0 }
        let end = start.addingTimeInterval(state.settings.lapLengthMin * 60)
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
        diaryOpen && !isLapRunning && !atOverdraftFloor
    }

    /// The string shown in the menu bar.
    var menuBarTitle: String {
        guard state.diaryOpen else { return "⊙" }
        if state.breakActive {
            return "☕ \(Self.clock(minutes: currentGas))"
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

    // MARK: - Diary ritual

    func openDiary() {
        let today = DiaryStore.dayKey()
        if state.dayKey != today {
            rolloverToNewDay(today)
        } else if state.dayKey.isEmpty {
            state.dayKey = today
        }
        state.diaryOpen = true
        persist()
    }

    /// Finalize the day: flush Gas (use it or lose it), make export ready,
    /// reset lap numbering. Permanent lap logs are untouched.
    func completeDiary() {
        if state.breakActive { stopBreak() }
        if isLapRunning { cancelLap() } // an unfinished lap is forfeited
        state.diaryOpen = false
        state.bankedGas = 0
        state.nextLapNumber = 1
        state.justCompletedLapNumber = nil
        // Day key stays as-is; the next openDiary on a new calendar day rolls over.
        persist()
    }

    private func rolloverToNewDay(_ today: String) {
        state.dayKey = today
        state.bankedGas = 0
        state.nextLapNumber = 1
        state.runningLapNumber = nil
        state.lapStartDate = nil
        state.justCompletedLapNumber = nil
        state.breakActive = false
        state.breakStartDate = nil
    }

    // MARK: - Laps

    func startLap() {
        guard state.diaryOpen, !isLapRunning else { return }
        if state.breakActive { stopBreak() } // can't run a lap and a break at once
        state.runningLapNumber = state.nextLapNumber
        state.lapStartDate = Date()
        state.justCompletedLapNumber = nil
        persist()
    }

    /// Forfeit the running lap. Earns nothing, logs nothing.
    func cancelLap() {
        guard isLapRunning else { return }
        state.runningLapNumber = nil
        state.lapStartDate = nil
        persist()
    }

    /// Called by the ticker when a running lap's countdown reaches zero.
    private func completeRunningLap(at end: Date, lapNumber: Int, start: Date) {
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

        // Auto-complete a finished lap.
        if let lapNo = state.runningLapNumber, let start = state.lapStartDate {
            let end = start.addingTimeInterval(state.settings.lapLengthMin * 60)
            if now >= end {
                completeRunningLap(at: end, lapNumber: lapNo, start: start)
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
