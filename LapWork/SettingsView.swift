//
//  SettingsView.swift
//  LapWork
//
//  The ⌘, preferences window (SwiftUI Settings scene). Edits a local copy of
//  FocusSettings and pushes it into the engine on change, so changes persist
//  immediately. Lap-length/accrual changes take effect on the NEXT lap.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var engine: TimerEngine
    @State private var draft = FocusSettings()

    var body: some View {
        Form {
            Section("Laps") {
                Stepper(value: $draft.lapLengthMin, in: 1...180, step: 1) {
                    LabeledContent("Lap length", value: "\(Int(draft.lapLengthMin)) min")
                }
                Stepper(value: $draft.accrualPercent, in: 0...100, step: 1) {
                    LabeledContent("Accrual", value: "\(Int(draft.accrualPercent))%")
                }
                LabeledContent("Earned per full lap",
                               value: String(format: "%.1f min", draft.gasPerLapMin))
                    .foregroundStyle(.secondary)
            }

            Section("Gas") {
                Stepper(value: $draft.overdraftFloorMin, in: 0...60, step: 1) {
                    LabeledContent("Overdraft floor",
                                   value: String(format: "%.0f min", -draft.overdraftFloorMin))
                }
            }

            Section("Alerts") {
                Toggle("Ring a bell when a lap ends", isOn: $draft.soundEnabled)
                Toggle("Show a notification banner", isOn: $draft.notificationsEnabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .onAppear { draft = engine.settings }
        .onChange(of: draft) { _, newValue in
            engine.updateSettings(newValue)
        }
    }
}
