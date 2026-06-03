import AdrafinilShared
import SwiftUI

@main
struct AdrafinilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var status: AppStatusModel
    @State private var settings: AdrafinilSettings = .load()

    init() {
        #if DEBUG
            // Back the menu-bar model with mock data so the debug control panel can drive scenarios
            // live. `DebugControl` keeps a reference so it can force an immediate refresh on switch.
            let model = AppStatusModel(provider: MockStatusProvider())
            DebugControl.shared.statusModel = model
            _status = State(initialValue: model)
        #else
            _status = State(initialValue: AppStatusModel())
        #endif
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $settings.showInMenuBar) {
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
