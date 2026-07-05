import Foundation
import Testing
@testable import AdrafinilShared

/// The "Add your own agent" snippet renderer (issue #6): slug derivation and the exact commands the
/// Settings UI shows for copy-paste. All pure.
@Suite("ManualHookSnippet")
struct ManualHookSnippetTests {
    // MARK: - Slug derivation

    @Test
    func `a plain name lowercases and hyphenates`() {
        #expect(ManualHookSnippet.slug(from: "My Agent") == "my-agent")
        #expect(ManualHookSnippet.slug(from: "Amp") == "amp")
    }

    @Test
    func `runs of separators collapse to a single hyphen`() {
        #expect(ManualHookSnippet.slug(from: "my   agent") == "my-agent")
        #expect(ManualHookSnippet.slug(from: "my___agent") == "my-agent")
        #expect(ManualHookSnippet.slug(from: "my - _ agent") == "my-agent")
    }

    @Test
    func `leading and trailing separators are trimmed`() {
        #expect(ManualHookSnippet.slug(from: "  Agent  ") == "agent")
        #expect(ManualHookSnippet.slug(from: "--agent--") == "agent")
        #expect(ManualHookSnippet.slug(from: "_agent_") == "agent")
    }

    @Test
    func `punctuation is stripped and acts as a boundary`() {
        #expect(ManualHookSnippet.slug(from: "Café Bot!") == "caf-bot")
        #expect(ManualHookSnippet.slug(from: "agent.v2") == "agent-v2")
        #expect(ManualHookSnippet.slug(from: "gpt/codex") == "gpt-codex")
    }

    @Test
    func `digits are preserved`() {
        #expect(ManualHookSnippet.slug(from: "Agent 3000") == "agent-3000")
    }

    @Test
    func `empty or all-stripped names fall back to the default`() {
        #expect(ManualHookSnippet.slug(from: "") == ManualHookSnippet.fallbackSlug)
        #expect(ManualHookSnippet.slug(from: "   ") == ManualHookSnippet.fallbackSlug)
        #expect(ManualHookSnippet.slug(from: "!!!") == ManualHookSnippet.fallbackSlug)
        #expect(ManualHookSnippet.slug(from: "日本語") == ManualHookSnippet.fallbackSlug)
        #expect(ManualHookSnippet.fallbackSlug == "my-agent")
    }

    // MARK: - Rendered snippets

    @Test
    func `hook snippets embed the slug and quote the session id`() {
        let s = ManualHookSnippet(agentName: "My Agent")
        #expect(s.slug == "my-agent")
        #expect(s.acquire == #"adrafinil acquire "$SESSION_ID" --tool my-agent"#)
        #expect(s.release == #"adrafinil release "$SESSION_ID" --tool my-agent"#)
    }

    @Test
    func `the wrapper acquires and releases on the same PID-keyed tool`() {
        let s = ManualHookSnippet(agentName: "Amp")
        #expect(s.wrapperScript.contains("adrafinil acquire $$ --tool amp"))
        #expect(s.wrapperScript.contains("adrafinil release $$ --tool amp"))
        #expect(s.wrapperScript.hasPrefix("#!/bin/sh"))
        #expect(s.wrapperScript.contains("exit $status"), "must preserve the wrapped command's exit code")
    }

    @Test
    func `the one-shot hold names the agent in its reason`() {
        let s = ManualHookSnippet(agentName: "My Agent")
        // The reason uses the display name (not the slug) so the menu row reads naturally.
        #expect(s.oneShotHold == #"adrafinil hold --for 2h --pid $$ --reason "My Agent session""#)
    }

    @Test
    func `a blank name falls back to the slug for the reason too`() {
        let s = ManualHookSnippet(agentName: "   ")
        #expect(s.slug == "my-agent")
        #expect(s.name == "my-agent")
        #expect(s.oneShotHold.contains(#"--reason "my-agent session""#))
    }
}
