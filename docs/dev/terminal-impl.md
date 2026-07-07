# Embedded terminal (SwiftTerm) — implementation notes

Status: **spike landed, working.** An embedded terminal renders as a
main-content tab. The agent-integration (tee) path is **not yet built** —
this is currently an interactive shell only. Pick up from "Next steps".

## Decision: why SwiftTerm

Evaluated three options for embedding a terminal in the Infer app:

- **arach/Termini** — SwiftUI terminal, wraps Ghostty's `libghostty`
  (prebuilt binary xcframework). Turnkey PTY workspace + SSH, but very
  early (1 release) and a binary blob.
- **Lakr233/libghostty-spm (GhosttyKit)** — lower-level wrapper of the
  same `libghostty` binary. More mature than Termini, but still an
  opaque prebuilt static lib; you manage the PTY yourself.
- **SwiftTerm (Miguel de Icaza, MIT)** — pure-Swift terminal emulator +
  PTY. Chosen: mature (~1.6k stars, v1.13.0), no binary blob, patchable,
  no notarization/bundle friction, cleaner Swift 6 interop.

Both Ghostty options share one engine (`libghostty`) and differ only in
how much they wrap it. SwiftTerm trades Ghostty's Metal GPU renderer for
CPU/CoreAnimation rendering — a non-issue for command output — in exchange
for source you can vendor and patch.

## What is implemented

An interactive login shell embedded as a main-content **tab** (Chat is
tab 0; wiki pages and now the terminal are additional tabs). Opened via
the menu command **"Open Terminal" / Cmd-Shift-T**. Session-only: never
persisted, never restored on relaunch; the shell is killed when the tab
closes or the app quits.

### Files touched

- `projects/infer/Package.swift` — SwiftTerm dependency
  (`from: "1.13.0"`) + `.product(name: "SwiftTerm", ...)` on the `Infer`
  target. Statically links; nothing extra to embed in `make bundle`
  (unlike llama/MLX, which ship frameworks/resource bundles).
- `projects/infer/Sources/Infer/TerminalSpikeView.swift` (new) —
  - `TerminalSession` (`@MainActor`): retains the AppKit
    `LocalProcessTerminalView` + its delegate **outside** the SwiftUI
    tree; spawns the shell once in `init`; `terminate()` kills the child.
  - `TerminalSession.Coordinator`: the `LocalProcessTerminalViewDelegate`
    (4 stubbed callbacks).
  - `TerminalTabView` (`NSViewRepresentable`): stateless; `makeNSView`
    returns `session.view` (re-parents the retained view).
- `ChatViewModel/Wiki.swift` — `WikiTab` gains `case terminal` (no
  associated value → single terminal tab, deduped by
  `openTabs.contains(.terminal)`); `openTerminal()` (lazily creates the
  session, appends + activates the tab); `closeTab(.terminal)` terminates
  the shell and nils the session.
- `ChatViewModel/ChatViewModel.swift` — `terminalSession: TerminalSession?`
  (`@ObservationIgnored`).
- `ChatView/ChatView.swift` — content area restructured into a `ZStack`
  (see "Scroll-position fix").
- `ChatView/MainContentTabs.swift` — tab title "Terminal" + `terminal`
  SF Symbol. Close/drag/reorder work for free (that logic was already
  generic over non-chat tabs).
- `InferApp.swift` — "Open Terminal" menu command (Cmd-Shift-T) calls
  `chatVM.openTerminal()`; `terminal.terminate` step wired into
  `applicationWillTerminate`'s per-step teardown sequence.

## Two non-obvious gotchas (both resolved)

### 1. Swift 6 isolated conformance

SwiftTerm compiles in Swift 5 mode (`swiftLanguageVersions: [.v5]`), so
its delegate protocols (`LocalProcessTerminalViewDelegate`, and later
`TerminalViewDelegate` / `LocalProcessDelegate`) are `nonisolated`. A
`@MainActor` type conforming to them fails to compile in this `.v6`
package: *"conformance crosses into main actor-isolated code."*

Fix = Swift 6.1 **isolated conformance** — put `@MainActor` before the
protocol in the conformance clause:

```swift
final class Coordinator: NSObject, @MainActor LocalProcessTerminalViewDelegate { ... }
```

Sound because SwiftTerm drives these callbacks on the main thread. Reuse
this pattern for the delegates in the tee refactor.

### 2. Scroll-position fix (mount-once, don't switch-in)

The content area is a SwiftUI `switch` on `activeTab` that **drops the
inactive branch**. A terminal rendered inside that switch is unmounted on
tab-away and re-added on tab-back; the re-add forces a fresh layout pass,
SwiftTerm reflows and jumps to the bottom, losing scroll position.
(Retaining the view object in `TerminalSession` keeps the *shell* alive
but does not prevent this layout churn.)

Fix: keep the terminal **continuously mounted** once the session exists,
and toggle only visibility. In `ChatView`, the content is a `ZStack`:
the `switch` renders chat/page normally and `Color.clear` for `.terminal`;
an always-present overlay renders `TerminalTabView` whenever
`terminalSession != nil`, with `.opacity(active ? 1 : 0)` and
`.allowsHitTesting(active)`. SwiftUI never unmounts the view (it's only
removed when the tab closes, which nils the session), so no relayout, no
scroll jump. Cost: the terminal stays laid out (invisibly) behind other
tabs — cheap for an idle shell, and it keeps scrollback + processes PTY
output while hidden.

## Current exposure

- **Compiled in unconditionally** — no build flag / `#if` gate.
- **Opt-in at runtime** — no terminal tab until "Open Terminal"
  (Cmd-Shift-T) is invoked. No settings toggle, no sidebar entry.

## Verified

`make build`, `make bundle`, `make test` all pass (0 failures). SwiftTerm
symbols statically linked into the `Infer` Mach-O. Manually confirmed:
tab opens, renders an interactive shell, survives switch-away/back with
scroll position intact, dies on close.

Note: CLAUDE.md references `make build-infer` / `bundle-infer`, but the
real Makefile targets are `make build` / `bundle` / `run`.

## Next steps

1. **Agent tee (the actual feature).** `LocalProcessTerminalView` is
   interactive-only — it feeds child output straight into the emulator
   with no tee, so an agent can't read output without grid-scraping
   (avoid). Real path: drive commands through SwiftTerm's lower-level
   `LocalProcess` (delegate `dataReceived(slice:)` hands you raw bytes),
   then fan bytes out two ways — `TerminalView.feed(byteArray:)` for the
   human render AND the agent's stdout consumer. One source, clean tee.
   This means swapping `LocalProcessTerminalView` for `LocalProcess` +
   plain `TerminalView`, and implementing the full `TerminalViewDelegate`
   (~10 methods) with the isolated-conformance pattern above.
2. **Decide gating.** Options: settings toggle (`PersistKey.*`), build
   flag `#if INFER_TERMINAL` (recommended while it's a spike, so it can't
   ship to release users), a sidebar affordance for discoverability, or
   leave as the hidden menu command. Not yet decided.
3. **First-responder follow-up.** `allowsHitTesting(false)` blocks the
   mouse on the hidden terminal, but keyboard first-responder can linger.
   If keystrokes leak to the terminal after switching away, resign first
   responder on tab switch. Not observed to be a problem yet — verify.
4. **Rename off "spike".** `TerminalSpikeView.swift` and the SPIKE
   comments should be renamed/cleaned once this graduates from spike to
   feature.
