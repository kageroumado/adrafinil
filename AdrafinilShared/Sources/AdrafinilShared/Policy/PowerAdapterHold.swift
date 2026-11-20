import Foundation

/// Policy for the opt-in *power-adapter hold*: while the setting is on and the Mac runs on its power
/// adapter, the daemon keeps one hold of its own, so a lid-closed MacBook stays awake on AC even when
/// no agent is working, and sleeps normally the moment it goes back on battery.
///
/// It is an ordinary registry assertion under a reserved key, so every safety net that drops holds
/// drops it too: the thermal cutout releases it and its latch keeps it from coming back until the Mac
/// cools; pausing releases it. It has no owning process and no TTL: the power source alone governs
/// it, so the CPU-idle rule, the dead-process rule and the max-age backstop never apply to it
/// (`IdleReleaseEvaluator`). Pure and testable; the daemon is the authority that applies it.
public enum PowerAdapterHold {
    /// The key namespace the daemon reserves for power-source holds (`CLIRequestValidator`
    /// refuses external acquires in it).
    public static let keyPrefix = "power:"

    /// The registry key of the one power-adapter hold.
    public static let key = keyPrefix + "adapter"

    /// Tool label on the hold; the menu shows its own wording for it.
    public static let tool = "power-adapter"

    public static func isKey(_ key: String) -> Bool {
        key == Self.key
    }

    /// Whether a set of assertions holds anything besides the power-adapter hold: agent work that a
    /// restart (an update relaunch) would interrupt. The power-adapter hold alone is not work; the
    /// relaunched daemon restores it from its state file.
    public static func holdsAgentWork(_ assertions: [Assertion]) -> Bool {
        assertions.contains { !isKey($0.key) }
    }

    /// The hold the daemon places. No pid (nothing to watch), no TTL (the power source ends it).
    public static func assertion(now: Date = Date()) -> Assertion {
        Assertion(
            key: key,
            tool: tool,
            reason: "On power adapter",
            pid: -1,
            processName: tool,
            acquiredAt: now,
            origin: .manual,
        )
    }

    public enum Action: Equatable, Sendable {
        case place
        case release
        case none
    }

    /// What to do with the hold given the current state.
    ///
    /// - Parameters:
    ///   - enabled: the user's `keepAwakeOnPowerAdapter` setting.
    ///   - onBattery: the last power-source reading; nil when there is none (a desktop Mac, or no
    ///     reading yet), which never holds.
    ///   - paused: Adrafinil is paused.
    ///   - latched: a safety cutout is latched; a placement would be refused until it clears.
    ///   - suppressed: the user released the hold themselves (force sleep, or releasing its row), so
    ///     it stays off until they re-engage: the charger is unplugged, the lid opens, Adrafinil is
    ///     resumed, or the setting is switched on again.
    ///   - held: the hold is currently in the registry.
    public static func decide(
        enabled: Bool,
        onBattery: Bool?,
        paused: Bool,
        latched: Bool,
        suppressed: Bool,
        held: Bool,
    ) -> Action {
        let wanted = enabled && onBattery == false && !paused && !latched && !suppressed
        if wanted, !held { return .place }
        if !wanted, held { return .release }
        return .none
    }
}
