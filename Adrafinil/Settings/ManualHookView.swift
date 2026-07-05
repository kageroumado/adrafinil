import AdrafinilShared
import AppKit
import SwiftUI

/// "Add your own agent" — the manual / custom-hook control (issue #6). For any agent Adrafinil has no
/// built-in integration for, the user types a name and copies generated snippets: the daemon socket
/// already accepts an arbitrary `--tool` from a same-user caller, so `adrafinil acquire … --tool
/// <slug>` works end-to-end with no daemon change. Two modes mirror how agents differ — those that
/// fire start/stop hooks, and those that don't (wrap the command, or place a one-shot hold).
///
/// Presented as its own `Section`, so it drops straight into the Agents tab's `Form`. Snippet
/// rendering is delegated to the pure, unit-tested `ManualHookSnippet`.
struct ManualHookView: View {
    @State private var name = ManualHookSnippet.fallbackSlug
    @State private var mode: Mode = .hooks

    private enum Mode: String, CaseIterable, Identifiable {
        case hooks = "It has hooks / events"
        case wrap = "It has no hooks — wrap the command"
        var id: String { rawValue }
    }

    private var snippet: ManualHookSnippet { ManualHookSnippet(agentName: name) }

    var body: some View {
        Section {
            nameField
            Picker("Integration style", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch mode {
            case .hooks: hookSnippets
            case .wrap: wrapSnippets
            }
        } header: {
            Text("Add your own agent")
        } footer: {
            caveat
        }
    }

    // MARK: - Name

    private var nameField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            LabeledContent("Agent name") {
                TextField("my-agent", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
            // Show the slug the name resolves to — the exact `--tool` value the snippets carry and the
            // label the menu will show — so an edit's effect is visible before copying.
            Text("Tracked as \(Text(snippet.slug).font(.system(.caption, design: .monospaced))) in Adrafinil")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Snippets per mode

    private var hookSnippets: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Add these to your agent's start and stop hooks. Replace \(Text("$SESSION_ID").font(.system(.caption, design: .monospaced))) with your agent's session-id variable, so each turn's acquire and release share a key.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SnippetRow(label: "On start / prompt", code: snippet.acquire)
            SnippetRow(label: "On stop / finish", code: snippet.release)
        }
    }

    private var wrapSnippets: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("No hooks? Wrap the command so it stays awake for the whole run — or place a single timed hold for a background job.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SnippetRow(label: "Wrapper script", code: snippet.wrapperScript)
            SnippetRow(label: "One-shot hold", code: snippet.oneShotHold)
        }
    }

    // MARK: - Caveat

    private var caveat: some View {
        Text("Custom agents aren't auto-detected or watched, so pair every acquire with a reliable release — the idle-release timeout and each hold's time limit are the only safety net if one is missed. Snippets assume the \(Text("adrafinil").font(.system(.caption, design: .monospaced))) command is on your PATH (\(Text(AdrafinilConstants.cliInstallPath).font(.system(.caption, design: .monospaced))), or \(Text("~/.local/bin/adrafinil").font(.system(.caption, design: .monospaced)))).")
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Snippet row

/// A labeled, read-only monospaced code block with a copy button — the reusable snippet affordance.
/// A quaternary inset (not `glassCard`) reads as a code block and sits right inside the grouped
/// Form's own material rather than stacking glass on glass.
private struct SnippetRow: View {
    let label: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                CopyButton(text: code)
            }
            .padding(Theme.Space.sm)
            .background(.quaternary.opacity(0.6), in: Theme.innerShape)
        }
    }
}

/// A borderless copy button that flips to a checkmark for a moment after copying — the same pasteboard
/// pattern as the Codex-trust "copy /hooks" affordance.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Theme.ok : .secondary)
        }
        .buttonStyle(.borderless)
        .help("Copy to clipboard")
    }
}

#if DEBUG
    #Preview("Add your own agent") {
        Form {
            ManualHookView()
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }
#endif
