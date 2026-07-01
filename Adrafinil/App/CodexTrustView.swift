import AdrafinilShared
import AppKit
import SwiftUI

/// Explains how to trust Adrafinil's hooks in Codex, and live-verifies that trust.
///
/// Codex is the one integration that won't run a hook until the user approves it: Adrafinil writes the
/// `acquire`/`release` commands into `~/.codex/hooks.json`, but Codex only fires them once the user
/// runs `/hooks` in the TUI and approves each handler (it records a `trusted_hash` in `config.toml`).
/// We can't do that step for the user, so this screen walks them through it and polls
/// `CodexHookTrust.status` so the badge flips to "Trusted" the moment they approve — without it, a
/// connected-but-untrusted Codex would silently never keep the Mac awake.
///
/// Reused by the installer (as a flow step, `primaryTitle: "Continue"`) and Settings (in a sheet,
/// `primaryTitle: "Done"`).
struct CodexTrustView: View {
    /// Reads the current trust status (live from disk in production; canned in previews).
    let readStatus: () -> CodexHookTrust.Status
    /// Primary button label and action — "Continue" advances the installer; "Done" dismisses the sheet.
    let primaryTitle: String
    let onPrimary: () -> Void

    @State private var status: CodexHookTrust.Status = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            header
            steps
            statusRow
            Spacer(minLength: 0)
            footer
        }
        // No self-padding: the installer pads at its container level and the Settings sheet pads
        // explicitly, matching how the other installer steps rely on the shared container chrome.
        .task {
            // Poll while untrusted so the badge turns green the instant the user approves in Codex.
            // A config.toml read is cheap; stop once fully trusted (nothing left to detect).
            status = readStatus()
            while !Task.isCancelled, status != .trusted {
                try? await Task.sleep(for: .seconds(2))
                status = readStatus()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Image(systemName: "lock.shield")
                .font(.system(size: 40))
                .foregroundStyle(Theme.awake)
                .symbolRenderingMode(.hierarchical)
            Text("Trust Adrafinil in Codex")
                .font(.system(.title2, design: .rounded).weight(.semibold))
            Text("Codex only runs hooks you've approved. Until you trust Adrafinil's, Codex won't tell it when a turn starts or ends — so your Mac may sleep mid-task, or stay awake after Codex is done.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            TrustStep(number: 1, title: "Open Codex in your terminal") {
                Text("Start a Codex session where you'd normally use it.")
            }
            TrustStep(number: 2, title: "Run the /hooks command") {
                HStack(spacing: Theme.Space.xs) {
                    Text("Type")
                    Text("/hooks")
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .foregroundStyle(.primary)
                    Text("and press return.")
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString("/hooks", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy “/hooks”")
                }
                .foregroundStyle(.secondary)
            }
            TrustStep(number: 3, title: "Approve Adrafinil's two hooks") {
                Text("Trust the entries that run **adrafinil acquire** (on prompt submit) and **adrafinil release** (on stop). They're listed under your hooks file; approving each is a one-time step.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: Theme.Space.md) {
            statusChip
            Spacer()
            Button {
                status = readStatus()
            } label: {
                Label("Re-check", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .padding(Theme.Space.md)
        .glassCard()
    }

    @ViewBuilder
    private var statusChip: some View {
        switch status {
        case .trusted:
            StateChip(text: "Hooks trusted", systemImage: "checkmark.seal.fill", tint: Theme.ok)
        case .partiallyTrusted:
            StateChip(text: "Partly trusted — approve both", systemImage: "exclamationmark.triangle.fill", tint: Theme.warn)
        case .untrusted:
            StateChip(text: "Not trusted yet", systemImage: "hourglass", tint: Theme.warn)
        case .unknown:
            StateChip(text: "Can't verify — trust it in Codex", systemImage: "questionmark.circle", tint: .secondary)
        }
    }

    private var footer: some View {
        HStack {
            if status == .trusted {
                Text("All set — Codex will keep your Mac awake while it works.")
                    .font(.caption)
                    .foregroundStyle(Theme.ok)
            }
            Spacer()
            Button(primaryTitle, action: onPrimary)
                .buttonStyle(.glassProminent)
                .tint(Theme.awake)
                .controlSize(.large)
        }
    }
}

/// One numbered instruction row: a circled step number beside a heading and detail content.
private struct TrustStep<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Text("\(number)")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(Theme.onAwake)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.awake))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(.body, design: .rounded).weight(.medium))
                content.font(.callout)
            }
        }
    }
}

#if DEBUG
    #Preview("Untrusted") {
        CodexTrustView(readStatus: { .untrusted }, primaryTitle: "Continue", onPrimary: {})
            .padding(Theme.Space.xl + Theme.Space.sm)
            .frame(minWidth: 460)
    }

    #Preview("Trusted") {
        CodexTrustView(readStatus: { .trusted }, primaryTitle: "Done", onPrimary: {})
            .padding(Theme.Space.xl + Theme.Space.sm)
            .frame(minWidth: 460)
    }
#endif
