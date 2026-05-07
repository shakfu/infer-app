# Wiki feature: scope retrospective

Honest assessment of the per-workspace markdown wiki shipped across
phases 1 → 4e.1, written after a string of bugs (folder ghosts on
disk, save button disabled for nested paths, drag-vs-tap gesture
conflicts, "two abc" duplicate folders) made it clear the feature
has scope-crept past the point where its incremental value justifies
its incremental cost.

## What's genuinely valuable

The **idea** of curated, always-injected, pinned context tied to a
workspace is novel and worth keeping. It's a different mental model
than Obsidian's "AI sees the open document" or pure RAG retrieval:

- The user explicitly *opts in* to what the model sees per turn.
- Wikilinks let one pinned root pull in transitive context, so the
  user defines a graph rather than a flat list.
- It composes cleanly alongside RAG (curated + searchable) without
  fighting the embedding pipeline.

That's the part that's worth preserving across any restructure.

## What's not paying off

### 1. Reinventing a notes tool inside a chat app

Obsidian, Bear, Logseq, Apple Notes are mature, daily-driven tools
with years of polish on the editor / tree / search / sync axes. A
wiki that lives only inside Infer starts as the user's *secondary*
notes home. Most users won't author here when their primary notes
already exist elsewhere.

The "be a chat app" and "be a notes app" jobs-to-be-done don't
combine — they compete for the same surface area, and the chat side
has higher impact-per-user-minute (timestamps, search, system prompt
presets, push-to-talk are all still on the P1 list).

### 2. Always-inject + a wiki tree don't compose well

The pin-and-transitive-walk model has a hard token budget (default
8k). Once the user has more than ~10 pinned-transitive pages, the
budget cap fires and "always-inject" silently truncates pages into
`droppedPageIds`. The wiki tree UI implies "this scales to hundreds
of pages," but the inject model fundamentally doesn't.

The two bits of UX point in opposite directions:

- Tree + folders + drag-organize say: "build a knowledge base here."
- Always-inject says: "keep it small or you'll silently lose context."

A power user hitting the budget cap will be confused about why their
nicely-organized wiki isn't fully present in the model's context.

### 3. The maintenance surface is large

The wiki feature touches:

- `NSTextView` wrapping for the editor (autocomplete trigger
  detection, cursor rect, drag-vs-tap, undo, IME, smart-quotes
  defaults, programmatic insert that doesn't fire `textDidChange`).
- Drag-and-drop with custom `Transferable` payloads for pages,
  folders, and tabs (3 distinct UTIs).
- Filesystem races (`subpaths(atPath:)` vs `enumerator` symlink
  handling — already burned us once on `/var/folders` ↔
  `/private/var/folders`).
- View identity around `@AppStorage` keyed on dynamic folder ids.
- Recursive tree rendering with depth-aware indent guides.
- Tab lifecycle on rename / move / delete.
- Live-debounced auto-save + backlinks-refresh tasks that have to
  be cancelled in `onDisappear` to avoid leaks.

Every one of those bit us during phase 4. They'll keep biting:

- Phase 4d's drag-folder-into-folder hit a SwiftUI tap-vs-draggable
  conflict that needed `.simultaneousGesture` to fix.
- Phase 4b's recursive `listPages` returned empty on `/var/folders`
  test paths because of symlink standardisation.
- Phase 4e's empty-folder rendering required adding a parallel
  `wikiFolders` listing because the tree was synthesised purely
  from page paths.
- The `Save` button stayed disabled for nested-path pages because
  `canSave` rejected `/` in the title — a leftover from the flat-id
  era.

Each fix was a real bug discovered after shipping the previous
phase. The sheer count is a leading indicator that the feature is
larger than its testable surface.

### 4. The on-disk truth and the UI tree drift

Twice now (Phase 4b's symlink bug, Phase 4e's empty-folder bug) the
sidebar tree silently disagreed with the actual on-disk wiki dir.
That's the signature of a feature with too many layers of
indirection between data and view.

## The minimal distillation that captures the unique value

Keep:

- `WikiStore` storage layer (or a much-simplified version).
- The pin model.
- Always-inject + transitive resolution from pinned roots.
- The `Generation.swift:127` injection point — wiki context
  composes alongside RAG augmentation, no system-prompt rebuild.

Drop:

- Tabs in the main content area.
- The file tree UI (`WikiSidebar`'s recursive tree).
- Drag-and-drop (page → folder, folder → folder, tab reorder).
- Folder structure entirely (storage stays flat).
- `MarkdownTextView` and the `[[` autocomplete popover.
- Backlinks panel.
- Rename-with-link-rewrites (no rename UI in the minimal version).
- `MathMessageView` preview pane (already dropped in 4a; stays
  dropped).

Replace the sidebar UI with one of two simpler shapes:

**Option A — single context blob per workspace.**
A `Workspace context` multi-line `TextField` in
`WorkspaceSettingsInline`. Always injected. No pages, no folders, no
links. The user pastes a project brief or persona doc; that's it.
~50 lines. Solves 60% of the use case.

**Option B — pin external files.**
A "Pin a file" button that opens a file picker; user navigates to
their existing notes (`~/Documents/Obsidian Vault/Project.md`,
`~/Notes/Persona.md`). The pinned file path is stored as a
security-scoped bookmark; on each turn we read the file and inject
it. The user authors in their real notes tool; Infer just pins and
injects. ~150 lines. Solves 90% of the use case and integrates
cleanly with whatever notes app the user already uses.

Option B is closer to the original spirit (curated context the user
explicitly maintains) without re-implementing the authoring layer.

## Cost of the strip-back

Mostly deletions:

- `ChatView/WikiSidebar.swift` (375 lines)
- `ChatView/WikiPageView.swift` (220 lines)
- `ChatView/MarkdownTextView.swift` (190 lines)
- `ChatView/WikiAutocompletePopover.swift` (60 lines)
- `ChatView/MainContentTabs.swift` (140 lines, plus tab plumbing
  in `ChatView`)
- `ChatViewModel/Wiki.swift` shrinks ~75% (remove tab actions, tree
  building, folder ops, move ops).
- `InferCore/Wiki/WikiStore.swift` shrinks ~50% (remove `movePage`,
  `moveFolder`, `rewriteWikilinks`, `listFolders`, `listAllFolders`,
  `createFolder`, `deleteFolder`, path validation; keep `listPages`,
  `loadPage`, `savePage`, `deletePage`, pin set, build-context).
- `InferCore/Wiki/WikiLinkResolver.swift` may stay (transitive
  closure is still useful) or shrink to just `extractLinks` if
  Option A is chosen (no link resolution needed).

The 31+7+4 unit tests around path handling / folder moves / link
rewrites / drag scenarios are all deletable in the strip-back; the
~9 pin / context / link-extract tests stay.

Net code delta: roughly **−1,500 lines** of view code and
**+50 to +150 lines** of replacement settings UI, depending on which
option ships.

## Recommendation

**Pause Phase 4f and beyond.**

Decide between:

1. **Commit to Obsidian-parity.** Real cost, real ongoing
   maintenance. The next phases (rename UI, sidebar search, sort,
   per-folder hover affordances, image attachments, export-to-
   Obsidian, vault sync, etc.) compound. Justifies itself only if
   the user's workflow genuinely is "I want my chat client to be
   my notes app." Most users won't be.

2. **Strip back to Option A or B.** Reclaim the implementation
   budget for chat-specific items where impact-per-user-minute is
   higher (timestamps, Cmd+F transcript search, system prompt
   presets, hold-to-talk, whisper live-mic). The unique value of
   "pinned + always-injected workspace context" is preserved.

The author of this document leans (2). The bug rate during phase 4
is the strongest signal.
