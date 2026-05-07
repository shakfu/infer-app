import SwiftUI
import AppKit
import InferCore

/// Inline wiki page editor — what the main content area renders when
/// the active tab is a `.page(id:)`. Replaces the modal
/// `WikiPageEditorSheet` Phase 2a/2b shipped; no preview pane (per
/// design feedback — chat already does live KaTeX, the wiki editor
/// stays plain markdown for focus).
///
/// One instance per page tab, identified by the .id(pageId) on the
/// containing view, so switching tabs unloads / reloads cleanly
/// rather than carrying stale @State across pages.
struct WikiPageView: View {
    @Bindable var vm: ChatViewModel
    let pageId: String

    @State private var title: String
    @State private var content: String = ""
    @State private var loaded = false
    @State private var confirmingDelete = false
    @State private var backlinks: [String] = []
    @State private var dirty = false
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var backlinksTask: Task<Void, Never>?
    @StateObject private var editorController = MarkdownTextViewController()

    init(vm: ChatViewModel, pageId: String) {
        self.vm = vm
        self.pageId = pageId
        // Title field shows the *basename* — folder context is
        // conveyed by the breadcrumb row above. New pages (sentinel
        // id "") start with an empty title field. Renames (an edit
        // to the title) keep the page in its current folder; to
        // move across folders the user drags the page in the
        // sidebar.
        _title = State(initialValue: (pageId as NSString).lastPathComponent)
    }

    private var isNew: Bool { pageId.isEmpty }

    /// Folder path containing this page, or empty string when the
    /// page sits at the wiki root. Used by `breadcrumb` to render
    /// the parent context above the title.
    private var parentPath: String {
        (pageId as NSString).deletingLastPathComponent
    }

    /// `true` when the user's input in the title field is acceptable
    /// for save. New pages allow `/` in the title (so a user can
    /// create `Notes/Daily/2026-05-08` from the root + button without
    /// pre-creating folders). Existing pages restrict to basename —
    /// renames keep the page in its current folder; cross-folder
    /// moves go through drag-and-drop.
    private var canSave: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"), !trimmed.hasPrefix("\\"),
              trimmed != ".", trimmed != ".." else { return false }
        if !isNew, trimmed.contains("/") { return false }
        let comps = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        for c in comps {
            let s = String(c)
            if s.isEmpty || s == "." || s == ".." || s.hasPrefix(".") {
                return false
            }
        }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            editor
                .overlay(alignment: .topLeading) {
                    if let trigger = editorController.trigger {
                        WikiAutocompletePopover(
                            query: trigger.query,
                            candidates: pageIdsExcludingCurrent,
                            controller: editorController
                        )
                        .offset(
                            x: trigger.cursorRect.minX,
                            y: trigger.cursorRect.maxY + 2
                        )
                    }
                }
                .onChange(of: editorController.trigger) { _, _ in
                    editorController.suggestions = matchingSuggestions(
                        for: editorController.trigger?.query ?? ""
                    )
                }
            if !backlinks.isEmpty {
                Divider()
                backlinksPanel
            }
        }
        .background(Color(.textBackgroundColor))
        .task { await loadContent() }
        .task { await refreshBacklinks() }
        .onDisappear {
            // Cancel pending debounced work, then save synchronously
            // if the user navigated away with unsaved changes so a
            // tab close / app quit doesn't lose the draft.
            autoSaveTask?.cancel()
            backlinksTask?.cancel()
            if dirty, !isNew { saveIfPossible() }
        }
        .alert("Delete page?",
               isPresented: $confirmingDelete,
               actions: {
                   Button("Delete", role: .destructive) {
                       vm.deleteWikiPage(pageId)
                   }
                   Button("Cancel", role: .cancel) {}
               },
               message: {
                   Text("This removes “\(pageId)” from the wiki and clears any pin on it. Inbound wikilinks resolve as unresolved until updated.")
               })
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !isNew, !parentPath.isEmpty {
                breadcrumb
            }
            titleBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Folder-path breadcrumb above the title — Obsidian-style. Path
    /// components are dimmed muted text separated by chevron
    /// glyphs; non-clickable in v1 (folders aren't "openable" the
    /// way pages are; the sidebar's tree is the navigation surface
    /// for jumping between folders).
    private var breadcrumb: some View {
        HStack(spacing: 4) {
            let parts = parentPath.split(separator: "/").map(String.init)
            ForEach(Array(parts.enumerated()), id: \.offset) { idx, part in
                if idx > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(part)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            TextField(
                isNew ? "Untitled" : "Page name",
                text: $title
            )
            .textFieldStyle(.plain)
            .font(.title3.weight(.semibold))
            .onSubmit { saveIfPossible() }

            Spacer()

            Text(footerStatus)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if !isNew {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete page")
            }

            Button("Save") { saveIfPossible() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave || (!dirty && !isNew))
        }
    }

    private var editor: some View {
        MarkdownTextView(text: $content, controller: editorController)
            .onChange(of: content) { _, _ in
                dirty = true
                scheduleAutoSave()
                scheduleBacklinksRefresh()
            }
            .onReceive(editorController.wikilinkClickSubject) { rawTarget in
                handleWikilinkClick(rawTarget)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Resolve a Cmd-clicked wikilink target to an existing page id
    /// (case-insensitive, basename-fallback) and open it as a tab.
    /// Unresolved targets surface as a one-line toast so the user
    /// knows the click was registered but the linked page doesn't
    /// exist yet — could be a typo or a future "create stub on
    /// click" feature later.
    private func handleWikilinkClick(_ rawTarget: String) {
        // Save current draft so navigating away doesn't lose
        // unsaved changes — same idiom as the backlinks chips.
        if dirty, !isNew { saveIfPossible() }

        let pages = vm.wikiPages
        let fullIndex = Dictionary(
            uniqueKeysWithValues: pages.map { ($0.id.lowercased(), $0) }
        )
        var basenameIndex: [String: String] = [:]
        for fullKey in fullIndex.keys.sorted() {
            let base = (fullKey as NSString).lastPathComponent
            if basenameIndex[base] == nil { basenameIndex[base] = fullKey }
        }
        if let resolvedKey = WikiLinkResolver.resolveKey(
            rawTarget,
            fullIndex: fullIndex,
            basenameIndex: basenameIndex
        ),
           let page = fullIndex[resolvedKey] {
            vm.openWikiPage(page.id)
        } else {
            vm.toasts.show(
                "No page named “\(rawTarget)” in this workspace."
            )
        }
    }

    /// Debounced auto-save. 1.5 s after the user stops typing on an
    /// existing (non-sentinel) page, the draft is committed to disk.
    /// New-page sentinel drafts skip auto-save until the user names
    /// + saves explicitly — we don't want to litter the wiki with
    /// `<sentinel>.md` files while the user is mid-thought about
    /// what to call a fresh page.
    private func scheduleAutoSave() {
        guard !isNew, loaded else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            saveIfPossible()
        }
    }

    /// Debounced backlinks refresh. Edits to the current page might
    /// change the link graph (a new `[[Other]]` reference creates a
    /// backlink on Other; deleting one removes it). 800 ms after
    /// typing stops, refresh the panel.
    private func scheduleBacklinksRefresh() {
        guard !isNew else { return }
        backlinksTask?.cancel()
        backlinksTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            await refreshBacklinks()
        }
    }

    private var backlinksPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Backlinks (\(backlinks.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(backlinks, id: \.self) { id in
                        Button {
                            saveIfPossible()
                            vm.openWikiPage(id)
                        } label: {
                            Text(id)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(id) (saves the current page first)")
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private var pageIdsExcludingCurrent: [String] {
        vm.wikiPages
            .map(\.id)
            .filter { isNew ? true : $0.lowercased() != pageId.lowercased() }
    }

    private func matchingSuggestions(for query: String) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else {
            return Array(pageIdsExcludingCurrent.prefix(8))
        }
        let prefixHits = pageIdsExcludingCurrent.filter { $0.lowercased().hasPrefix(q) }
        let substringHits = pageIdsExcludingCurrent.filter {
            !$0.lowercased().hasPrefix(q) && $0.lowercased().contains(q)
        }
        return Array((prefixHits + substringHits).prefix(8))
    }

    private var footerStatus: String {
        let chars = content.count
        let approxTokens = chars / 4
        return "\(chars) chars · ~\(approxTokens) tok"
    }

    private func saveIfPossible() {
        guard canSave, dirty || isNew else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Compose the new id from the page's existing folder context
        // + the user's basename input. New pages with `/` in the
        // input (root creation of nested pages) use the input as-is
        // because they have no parent context yet. Existing pages
        // keep their parent path; cross-folder moves go through
        // sidebar drag.
        let newId: String
        if isNew {
            newId = trimmed
        } else if parentPath.isEmpty {
            newId = trimmed
        } else {
            newId = parentPath + "/" + trimmed
        }
        vm.saveWikiPage(
            originalId: pageId,
            newId: newId,
            content: content
        )
        dirty = false
    }

    private func loadContent() async {
        if isNew {
            loaded = true
            return
        }
        let body = await vm.loadWikiPageContent(pageId)
        await MainActor.run {
            self.content = body
            self.loaded = true
            self.dirty = false
        }
    }

    private func refreshBacklinks() async {
        guard !isNew else { return }
        let links = await vm.loadBacklinks(for: pageId)
        await MainActor.run {
            self.backlinks = links
        }
    }
}
