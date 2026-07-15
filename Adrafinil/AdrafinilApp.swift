import AdrafinilShared
import SwiftUI

@main
struct AdrafinilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var status: AppStatusModel
    @State private var settings: AdrafinilSettings = .load()
    /// Temporary-reveal state: with the icon hidden, relaunching the app briefly puts it back on
    /// the bar to host one popover session (see MenuBarPresence).
    @State private var presence = MenuBarPresence.shared

    init() {
        #if DEBUG
            // Back the menu-bar model with mock data so the debug control panel can drive scenarios
            // live. `DebugControl` keeps a reference so it can force an immediate refresh on switch.
            // No launch maintenance in DEBUG: it would migrate real ~/.codex hooks and hit the network
            // while exercising mock scenarios.
            let model = AppStatusModel(provider: MockStatusProvider(), enableLaunchMaintenance: false)
            DebugControl.shared.statusModel = model
            _status = State(initialValue: model)
        #else
            _status = State(initialValue: AppStatusModel())
        #endif
    }

    var body: some Scene {
        // The insertion binding persists on every set: removing the icon by ⌘-dragging it out
        // flips the binding directly (never passing through SettingsView's onChange, which only
        // exists while that window is open), and an unsaved removal would silently revert on
        // relaunch.
        MenuBarExtra(isInserted: Binding(
            get: { settings.showInMenuBar || presence.temporarilyShown },
            set: { newValue in
                // MenuBarExtra mirrors the status item's visibility back into this binding on its
                // own schedule. The only legitimate "insert" writers are the Settings toggle and
                // the temporary reveal, and both manage their own state — so a set(true) here is
                // always an echo of our own insertion (possibly arriving after the reveal already
                // ended; guarding on the reveal flag loses that race), and persisting it would
                // resurrect the icon for good. Never accept it. (WheelClick mutes its KVO observer
                // around self-driven visibility changes for the same reason.)
                guard !newValue else { return }
                // set(false) during a temporary reveal: the reveal's own teardown, not a user
                // action — the setting is already false.
                if presence.temporarilyShown {
                    presence.endTemporaryReveal()
                    return
                }
                // A real ⌘-drag off the bar. It never passes through SettingsView, so explain the
                // way back here.
                settings.showInMenuBar = false
                try? settings.save()
                presence.announceHiddenIfNeeded()
            },
        )) {
            MenuPopover(status: status)
                // If the icon was only revealed to host this popover, hide it again on close.
                .onDisappear { presence.popoverDidClose() }
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
