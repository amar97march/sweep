import AppKit
import SwiftUI
import SweepUI

@main
struct SweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        // One main window: "Open Sweep" in the menu bar brings it back instead of opening a second one.
        Window("Sweep", id: "main") {
            RootView(state: state)
                .onAppear { Snapshots.runIfRequested(state: state) }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView(state: state)
        }

        MenuBarExtra {
            MenuBarDashboard(state: state)
        } label: {
            // A cup while Keep Awake is on, so it's clear why the Mac isn't sleeping.
            Image(systemName: state.keepAwake.isActive ? "cup.and.saucer.fill" : "sparkles")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // The menu bar dashboard keeps running after the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
