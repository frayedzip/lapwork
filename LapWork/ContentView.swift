//
//  ContentView.swift
//  LapWork
//
//  The MenuBarExtra dropdown panel. Reads everything from the shared
//  TimerEngine; it holds no timer state of its own.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var engine: TimerEngine
    @State private var exportNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if engine.diaryOpen {
                Divider()
                lapSection
                Divider()
                gasSection
                Divider()
                actions
            } else {
                Divider()
                if let summary = engine.state.lastSummary {
                    summarySection(summary)
                    Divider()
                }
                closedSection
            }

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 260)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("LapWork")
                .font(.headline)
            Spacer()
            Circle()
                .fill(engine.diaryOpen ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(engine.diaryOpen ? "Diary open" : "Diary closed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Day summary (shown after Diary Complete)

    private func summarySection(_ s: DaySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Day summary", systemImage: "checkmark.seal.fill")
                    .font(.callout).bold()
                Spacer()
                Text(s.day)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            summaryRow(
                "Active",
                value: TimerEngine.hoursMinutes(s.spanSec),
                detail: "\(TimerEngine.timeOfDay(s.start)) → \(TimerEngine.timeOfDay(s.end))"
            )
            summaryRow(
                "Laps",
                value: "\(s.lapCount)",
                detail: "earned \(TimerEngine.clock(minutes: s.gasEarnedMin))"
            )

            Divider()

            summaryRow("Lap time", value: TimerEngine.hoursMinutes(s.lapTimeSec))
            summaryRow("Rest time", value: TimerEngine.hoursMinutes(s.breakTimeSec))
            summaryRow("Idle (nothing logged)", value: TimerEngine.hoursMinutes(s.idleTimeSec))
        }
    }

    private func summaryRow(_ label: String, value: String, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
        }
    }

    // MARK: - Diary closed

    private var closedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open the diary to start your session.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                engine.openDiary()
            } label: {
                Label("Open Diary", systemImage: "book")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Lap

    private var lapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if engine.isResting {
                restingRows
            } else if engine.isLapRunning, let lap = engine.state.runningLapNumber {
                runningLapRows(lap: lap)
            } else {
                readyRows
            }
            Text(lapCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // Mandatory tempo rest between laps — counts down, then auto-starts.
    private var restingRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Rest", systemImage: "pause.circle")
                    .font(.title3).bold()
                Spacer()
                Text(TimerEngine.mmss(engine.restRemaining))
                    .font(.system(.title3, design: .monospaced))
                    .monospacedDigit()
            }
            Text("Lap \(engine.state.nextLapNumber) starts automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                engine.stopTempo()
            } label: {
                Label("Stop tempo", systemImage: "stop.circle")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func runningLapRows(lap: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Lap \(lap)")
                    .font(.title3).bold()
                Spacer()
                Text(TimerEngine.mmss(engine.lapRemaining))
                    .font(.system(.title3, design: .monospaced))
                    .monospacedDigit()
            }
            if engine.settings.tempoModeEnabled {
                Button {
                    engine.toggleTempoStop()
                } label: {
                    Label(engine.tempoStopPending ? "Keep tempo going" : "Stop tempo after this lap",
                          systemImage: engine.tempoStopPending ? "arrow.clockwise" : "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                if engine.tempoStopPending {
                    Text("Cadence stops when this lap ends.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button(role: .destructive) {
                engine.cancelLap()
            } label: {
                Label("Cancel lap (forfeit)", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var readyRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let done = engine.state.justCompletedLapNumber {
                Text("Lap \(done) done — banked \(TimerEngine.clock(minutes: engine.settings.gasPerLapMin))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                engine.startLap()
            } label: {
                Label(engine.settings.tempoModeEnabled
                      ? "Start Tempo (Lap \(engine.state.nextLapNumber))"
                      : "Start Lap \(engine.state.nextLapNumber)",
                      systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(engine.isBreakActive)
        }
    }

    private var lapCaption: String {
        let base = "Lap length \(Int(engine.settings.lapLengthMin)) min · earns \(TimerEngine.clock(minutes: engine.settings.gasPerLapMin))"
        guard engine.settings.tempoModeEnabled else { return base }
        return base + " · tempo rest \(Int(engine.settings.restLengthSec))s"
    }

    // MARK: - Gas

    private var gasSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Gas", systemImage: "fuelpump")
                    .font(.callout)
                Spacer()
                Text(TimerEngine.clock(minutes: engine.currentGas))
                    .font(.system(.title3, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(engine.currentGas < 0 ? .red : .primary)
            }

            Button {
                engine.toggleBreak()
            } label: {
                Label(engine.isBreakActive ? "Stop Break" : "Take Break",
                      systemImage: engine.isBreakActive ? "pause.fill" : "cup.and.saucer")
                    .frame(maxWidth: .infinity)
            }
            .tint(engine.isBreakActive ? .orange : .accentColor)
            .buttonStyle(.bordered)
            .disabled(!engine.canTakeBreak && !engine.isBreakActive)

            if engine.atOverdraftFloor && !engine.isBreakActive {
                Text("At overdraft floor (\(TimerEngine.clock(minutes: engine.settings.overdraftFloor))).")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Day actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                engine.completeDiary()
            } label: {
                Label("Diary Complete (finalize day)", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Footer (export + settings + quit)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                exportToday()
            } label: {
                Label("Export Today's CSV…", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if let note = exportNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                // Agent apps (LSUIElement, .accessory) open the Settings window
                // behind everything; activate so it comes to the front.
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.activate(ignoringOtherApps: true)
                })
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
    }

    // MARK: - Helpers

    private func exportToday() {
        let day = DiaryStore.dayKey()
        if let url = DiaryStore.shared.exportCSVFile(for: day) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            exportNote = "Exported to \(url.lastPathComponent)"
        } else {
            exportNote = "Nothing logged today yet."
        }
    }
}
