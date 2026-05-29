import SwiftUI
import AdrafinilShared

@main
struct AdrafinilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var status = AppStatusModel()
    @State private var settings: AdrafinilSettings = .load()

    var body: some Scene {
        MenuBarExtra(isInserted: $settings.showInMenuBar) {
            MenuPopover(status: status)
        } label: {
            MenuBarIcon(status: status)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appSettings: $settings)
                .frame(width: 520, height: 440)
        }
        // The first-run setup window (InstallerView) is presented from AppDelegate via AppKit,
        // since a menu-bar (LSUIElement) app does not auto-present SwiftUI windows at launch.
    }
}
