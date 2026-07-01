import Observation
import SwiftUI

/// The tabs of the Settings window, as stable tags so callers can deep-link to one.
enum SettingsTab: Hashable {
    case general
    case agents
    case safety
    case about
}

/// Shared selection for the Settings `TabView`, so the menu-bar popover can open Settings on a
/// *specific* tab — e.g. a hook attention card (drift / Codex trust) opens **Agents**, not the
/// default General. `SettingsLink` / `openSettings()` can't target a tab, so callers set
/// `selection` here first, then open Settings; `SettingsView` binds its `TabView` to it.
@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selection: SettingsTab = .general
    private init() {}
}
