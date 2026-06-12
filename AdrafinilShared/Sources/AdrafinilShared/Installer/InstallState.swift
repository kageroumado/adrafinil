import Foundation

/// Per-agent hook-installation state, surfaced in the Settings → Agents tab.
public enum HookInstallState: String, Codable, Sendable {
    /// Adrafinil's hook entry is present and matches what we would write.
    case installed
    /// No Adrafinil hook entry exists in the agent's config.
    case notInstalled
    /// An Adrafinil entry exists but has been edited externally / no longer matches.
    case modifiedExternally
    /// The agent's config file exists but can't be parsed, so the install state is unknowable
    /// — and installing would risk the user's content. Surfaced so the UI doesn't offer a
    /// "Connect" that is guaranteed to fail.
    case configUnreadable
}
