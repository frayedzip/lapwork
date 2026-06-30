//
//  LapWorkApp.swift
//  LapWork
//
//  App entry. Owns the single TimerEngine, drives the MenuBarExtra label from
//  it, and exposes a Settings scene for ⌘,. The engine is injected into both
//  scenes via the environment.
//

import SwiftUI

@main
struct LapWorkApp: App {
    @StateObject private var engine = TimerEngine()

    init() {
        // Ask for banner permission once at launch.
        NotificationManager.shared.requestAuthorization()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(engine)
        } label: {
            // Dynamic title: ⊙ when closed, "L7 · 8:42" / "L7 done" when open.
            Text(engine.menuBarTitle)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(engine)
        }
    }
}
