#if DEBUG
    import AdrafinilShared
    import AppKit
    import Propofol
    import SwiftUI

    /// The README's three popover states, each in Propofol's chrome-less `PopoverStageWindow`.
    ///
    /// Present by launching with `-ADRAFINIL_STAGE awake|idle|hold`; one state per launch, because
    /// tinted glass (the awake hero, the prominent button) takes its color only in the key window
    /// of the frontmost app. Capture with `screencapture -l <window id> -o out.png`, finding the id
    /// by the window title `Adrafinil — Stage`.
    @MainActor
    enum ScreenshotStage {
        private static var window: NSWindow?

        static func present(_ state: String) {
            let window = PopoverStageWindow(title: "Adrafinil — Stage") { popover(for: state) }
            window.center()
            self.window = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        @ViewBuilder
        private static func popover(for state: String) -> some View {
            switch state {
            case "idle":
                MenuPopover(status: AppStatusModel(previewStatus: Fixtures.idle))
            case "hold":
                MenuPopover(status: AppStatusModel(previewStatus: Fixtures.idle), startsPickingDuration: true)
            default:
                MenuPopover(status: AppStatusModel(previewStatus: Fixtures.oneAgent))
            }
        }
    }
#endif
