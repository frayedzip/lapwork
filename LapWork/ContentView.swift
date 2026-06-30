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
            if engine.isLapRunning, let lap = engine.state.runningLapNumber {
                HStack {
                    Text("Lap \(lap)")
                        .font(.title3).bold()
                    Spacer()
                    Text(TimerEngine.mmss(engine.lapRemaining))
                        .font(.system(.title3, design: .monospaced))
                        .monospacedDigit()
                }
                Button(role: .destructive) {
                    engine.cancelLap()
                } label: {
                    Label("Cancel lap (forfeit)", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
            } else {
                if let done = engine.state.justCompletedLapNumber {
                    Text("Lap \(done) done — banked \(TimerEngine.clock(minutes: engine.settings.gasPerLapMin))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button {
                    engine.startLap()
                } label: {
                    Label("Start Lap \(engine.state.nextLapNumber)", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(engine.isBreakActive)
            }
            Text("Lap length \(Int(engine.settings.lapLengthMin)) min · earns \(TimerEngine.clock(minutes: engine.settings.gasPerLapMin))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
