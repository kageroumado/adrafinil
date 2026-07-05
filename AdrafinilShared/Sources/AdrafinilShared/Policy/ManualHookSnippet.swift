import Foundation

/// Renders the copy-paste snippets for wiring an *arbitrary* agent into Adrafinil by hand — the
/// "Add your own agent" flow (issue #6). No daemon or CLI change is needed: the daemon socket already
/// accepts any `--tool` from a same-user caller, so `adrafinil acquire … --tool <slug>` works
/// end-to-end for a tool Adrafinil has never heard of. This type just turns a user-typed agent name
/// into the exact commands to paste, all keyed on a slug derived from that name.
///
/// Pure and fully unit-tested; the Settings view is a thin renderer over it.
public struct ManualHookSnippet: Equatable, Sendable {
    /// The slug used when the typed name has no slug-able characters (blank, or all punctuation /
    /// non-Latin). Also the default the UI seeds the name field with.
    public static let fallbackSlug = "my-agent"

    /// The trimmed agent name as typed — used verbatim in the hold reason. Falls back to the slug
    /// when the input is blank, so the reason is never an empty `"" session`.
    public let name: String

    /// The `--tool` value: the name lowercased and reduced to `[a-z0-9-]`. This is the label the hold
    /// carries and what the menu shows, so it must be stable and shell-safe.
    public let slug: String

    public init(agentName: String) {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let derived = Self.slug(from: trimmed)
        self.slug = derived
        self.name = trimmed.isEmpty ? derived : trimmed
    }

    /// Acquire, for an agent that fires start/end hooks. `$SESSION_ID` is the placeholder the user maps
    /// to their agent's session-id variable; quoting guards a value with spaces. The matching `Stop`/
    /// end hook runs `release`.
    public var acquire: String {
        #"adrafinil acquire "$SESSION_ID" --tool \#(slug)"#
    }

    /// Release, paired with `acquire` on the agent's end/stop hook. Same `--tool` so it targets the key
    /// the acquire placed — dropping `--tool` would release `unknown:$SESSION_ID`, leaking the real hold.
    public var release: String {
        #"adrafinil release "$SESSION_ID" --tool \#(slug)"#
    }

    /// A wrapper script for an agent with *no* hooks: acquire, run the real command, release — keyed on
    /// the wrapper's own PID (`$$`), which the release reuses so the hold is bracketed to the command's
    /// lifetime. `exit $status` preserves the wrapped command's exit code.
    public var wrapperScript: String {
        """
        #!/bin/sh
        # Keep your Mac awake while \(name) runs, then let it sleep again.
        adrafinil acquire $$ --tool \(slug)
        <your-agent-command> "$@"
        status=$?
        adrafinil release $$ --tool \(slug)
        exit $status
        """
    }

    /// A one-shot hold for a background job: keep the Mac awake for up to 2h, ending when this shell
    /// (`$$`) exits, the time runs out, or the hold is released — no start/end hooks needed.
    public var oneShotHold: String {
        #"adrafinil hold --for 2h --pid $$ --reason "\#(name) session""#
    }

    /// Reduces a display name to a shell- and menu-safe slug: lowercased, `[a-z0-9]` kept, runs of
    /// spaces / underscores / hyphens / stripped characters collapsed to a single `-`, and leading /
    /// trailing hyphens trimmed. Punctuation and non-Latin scalars are dropped (so `Café Bot!` →
    /// `caf-bot`); a result with nothing left falls back to `fallbackSlug`.
    public static func slug(from name: String) -> String {
        var out = ""
        var pendingSeparator = false
        for scalar in name.lowercased().unicodeScalars {
            switch scalar {
            case "a" ... "z", "0" ... "9":
                if pendingSeparator, !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.unicodeScalars.append(scalar)
            default:
                // Any non-slug scalar (space, underscore, hyphen, punctuation, accent, non-Latin) is a
                // word boundary: remember it so the *next* kept character emits one separating hyphen.
                pendingSeparator = true
            }
        }
        return out.isEmpty ? fallbackSlug : out
    }
}
