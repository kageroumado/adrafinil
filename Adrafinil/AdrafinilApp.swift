import AdrafinilShared
import SwiftUI

@main
struct AdrafinilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var status: AppStatusModel
    @State private var settings: AdrafinilSettings = .load()

    init() {
        let model: AppStatusModel
        #if DEBUG
            // Back the menu-bar model with mock data so the debug control panel can drive scenarios
            // live. `DebugControl` keeps a reference so it can force an immediate refresh on switch.
            // No launch maintenance in DEBUG: it would migrate real ~/.codex hooks and hit the network
            // while exercising mock scenarios.
            model = AppStatusModel(provider: MockStatusProvider(), enableLaunchMaintenance: false)
            DebugControl.shared.statusModel = model
        #else
            model = AppStatusModel()
        #endif
        _status = State(initialValue: model)
        // Share the live model so AppKit can host the same popover contents in a real window when
        // the menu-bar icon is hidden (see `AppDelegate.presentMenuWindow`).
        AppDelegate.sharedStatus = model
    }

    var body: some Scene {
        // The insertion binding persists on every set: removing the icon by ⌘-dragging it out
        // flips the binding directly (never passing through SettingsView's onChange, which only
        // exists while that window is open), and an unsaved removal would silently revert on
        // relaunch.
        MenuBarExtra(isInserted: Binding(
            get: { settings.showInMenuBar },
            set: { newValue in
                settings.showInMenuBar = newValue
                try? settings.save()
            },
        )) {
            MenuPopover(status: status)
        } label: {
            MenuBarIcon(status: status)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appSettings: $settings)
                .frame(width: 520, height: 560)
        }
        // The first-run setup window (InstallerView) is presented from AppDelegate via AppKit,
        // since a menu-bar (LSUIElement) app does not auto-present SwiftUI windows at launch.
    }
}
