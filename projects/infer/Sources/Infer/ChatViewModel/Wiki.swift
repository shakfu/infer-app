import Foundation
import InferCore

/// Sort order applied to *pages* within each folder in the sidebar
/// tree. Folders themselves always sort alphabetically (Obsidian
/// behaviour); only the leaf-page ordering changes. Persisted
/// per-workspace so each workspace remembers its own preference.
enum WikiSortMode: String, CaseIterable, Sendable {
    case alphabetical
    case modified
    case pinFirst

    /// Menu label.
    var label: String {
        switch self {
        case .alphabetical: return "Name"
        case .modified: return "Date modified"
        case .pinFirst: return "Pinned first"
        }
    }

    /// SF Symbol shown beside the label in the sort menu.
    var systemImage: String {
        switch self {
        case .alphabetical: return "textformat"
        case .modified: return "clock"
        case .pinFirst: return "pin"
        }
    }
}

/// One node in the sidebar's tree view: either a folder (whose
/// `children` are nested nodes) or a leaf page. Built by
/// `ChatViewModel.buildWikiTree` from the flat `wikiPages` list.
enum WikiTreeNode: Identifiable, Equatable {
    case folder(id: String, name: String, children: [WikiTreeNode])
    case page(WikiPage)

    var id: String {
        switch self {
        case .folder(let id, _, _): return "folder:" + id
        case .page(let page): return "page:" + page.id
        }
    }
}

/// One tab in the main content area. Chat is the always-present
/// fixed-position tab 0; pages are wiki pages opened from the sidebar
/// (page id = filename stem; the empty string is the new-page
/// sentinel for unsaved drafts).
enum WikiTab: Hashable, Sendable, Codable {
    case chat
    case page(id: String)

    var pageId: String? {
        if case .page(let id) = self { return id }
        return nil
    }
}

/// Per-turn supplement built from `[[Page]]` mentions found in the
/// user's chat message. Distinct from `WikiContext` (which is the
/// always-injected pinned set) — mentions live for one turn only.
/// Format wraps the resolved pages in a `<wiki_mentions>` block so
/// the model sees the user's `[[Page]]` syntax in the message body
/// alongside the resolved content as adjacent context.
public struct WikiMentionsContext: Equatable, Sendable {
    public let text: String
    public let pageIds: [String]
    public let unresolvedTargets: [String]
    public let approximateTokens: Int

    public static let empty = WikiMentionsContext(
        text: "",
        pageIds: [],
        unresolvedTargets: [],
        approximateTokens: 0
    )

    static func format(_ pages: [WikiPage]) -> String {
        guard !pages.isEmpty else { return "" }
        var body = "<wiki_mentions>\nThe user referenced these pages in this message; treat them as supplementary context for this turn.\n\n"
        for page in pages {
            body += "## \(page.id)\n\n"
            body += page.content.trimmingCharacters(in: .whitespacesAndNewlines)
            body += "\n\n"
        }
        body += "</wiki_mentions>\n"
        return body
    }
}

/// Snapshot of what the next chat turn would inject from the wiki.
/// Surfaced in the sidebar footer so users see the cost of their pin
/// set without having to reason about it. Mirrors `WikiContext`'s
/// counts but doesn't carry the (potentially large) text body — the
/// VM stores this for UI binding while letting the per-turn build
/// reconstruct the full text on demand.
struct WikiContextStats: Equatable, Sendable {
    let pageCount: Int
    let approximateTokens: Int
}

extension ChatViewModel {
    /// Build the always-inject wiki context for the active workspace,
    /// or return `WikiContext.empty` if no workspace is active or no
    /// pages are pinned. Failures (missing dir, decode error) downgrade
    /// silently — the chat turn still goes through, just without wiki
    /// context. The error is logged so users at the debug filter see
    /// it.
    ///
    /// Called per-turn from `Generation.swift`. Cheap on the warm path
    /// (a few small file reads + a BFS over a deduped set), so we
    /// don't cache — pinning a page or editing a wiki body should
    /// reflect on the next turn without explicit cache invalidation.
    /// Scan the user's current message for `[[Page]]` mentions and
    /// build a per-turn context block from the matched pages — a
    /// "for this turn only" supplement to the always-injected pinned
    /// set. Resolution mirrors `WikiLinkResolver.resolveKey` (case-
    /// insensitive, basename fallback). Unresolved mentions surface
    /// in the result so the caller can log / surface them; they
    /// don't fail the build.
    ///
    /// Returns `.empty` when no workspace is active, the message
    /// contains no mentions, or every mention is unresolved.
    func buildWikiMentionsContext(in messageText: String) async -> WikiMentionsContext {
        guard let workspaceId = activeWorkspaceId else { return .empty }
        let rawTargets = WikiLinkResolver.extractLinks(from: messageText)
        guard !rawTargets.isEmpty else { return .empty }
        let pages = wikiPages
        let fullIndex = Dictionary(
            uniqueKeysWithValues: pages.map { ($0.id.lowercased(), $0) }
        )
        var basenameIndex: [String: String] = [:]
        for fullKey in fullIndex.keys.sorted() {
            let base = (fullKey as NSString).lastPathComponent
            if basenameIndex[base] == nil { basenameIndex[base] = fullKey }
        }
        // Resolve each mention; dedup by resolved id so `[[X]]` and
        // `[[x]]` don't double-count.
        var resolvedById: [String: WikiPage] = [:]
        var resolvedOrder: [String] = []
        var unresolved: [String] = []
        for raw in rawTargets {
            if let key = WikiLinkResolver.resolveKey(
                raw, fullIndex: fullIndex, basenameIndex: basenameIndex
            ),
               let page = fullIndex[key] {
                if resolvedById[page.id] == nil {
                    resolvedById[page.id] = page
                    resolvedOrder.append(page.id)
                }
            } else {
                unresolved.append(raw)
            }
        }
        // Re-load each resolved page from disk so the latest saved
        // content is what gets injected — `wikiPages` is cached and
        // could lag behind a recent save in very-short windows.
        var freshPages: [WikiPage] = []
        for id in resolvedOrder {
            if let fresh = try? await wiki.loadPage(workspaceId: workspaceId, id: id) {
                freshPages.append(fresh)
            } else if let stale = resolvedById[id] {
                freshPages.append(stale)
            }
        }
        let approxTokens = freshPages.reduce(0) {
            $0 + WikiContext.estimateTokens(for: $1)
        }
        return WikiMentionsContext(
            text: WikiMentionsContext.format(freshPages),
            pageIds: freshPages.map { $0.id },
            unresolvedTargets: unresolved,
            approximateTokens: approxTokens
        )
    }

    func buildWikiContextIfAvailable() async -> WikiContext {
        guard let workspaceId = activeWorkspaceId else { return .empty }
        let store = self.wiki
        let budget = self.wikiBudgetTokens
        do {
            return try await store.buildContext(
                workspaceId: workspaceId,
                budgetTokens: budget
            )
        } catch {
            // Best-effort: a malformed `.pins.json` or filesystem
            // permissions issue shouldn't block generation. Log so
            // the user at the debug filter can investigate.
            self.logs.log(
                .warning,
                source: "wiki",
                message: "wiki context build failed for workspace \(workspaceId): \(error)"
            )
            return .empty
        }
    }

    // MARK: - Wiki UI state

    /// Reload `wikiPages` + `wikiPins` from disk. Cheap; called when
    /// the workspace switches or after a save/delete/pin-toggle so the
    /// sidebar reflects the latest state without a full app refresh.
    func refreshWiki() {
        guard let workspaceId = activeWorkspaceId else {
            wikiRefreshTask?.cancel()
            wikiRefreshTask = nil
            wikiPages = []
            wikiPins = []
            wikiFolders = []
            wikiContextStats = nil
            return
        }
        wikiRefreshTask?.cancel()
        let store = self.wiki
        let budget = self.wikiBudgetTokens
        wikiRefreshTask = Task { [weak self] in
            let pages = (try? await store.listPages(workspaceId: workspaceId)) ?? []
            let pins = (try? await store.loadPins(workspaceId: workspaceId)) ?? []
            let folders = (try? await store.listAllFolders(workspaceId: workspaceId)) ?? []
            if Task.isCancelled { return }
            // Reuse the same context-build pinned-roots-bypass-budget
            // logic the chat turn uses, so the sidebar's preview can't
            // diverge from what actually injects. Failure → no stats
            // banner, but pages + pins still surface.
            let ctx = (try? await store.buildContext(
                workspaceId: workspaceId,
                budgetTokens: budget
            )) ?? .empty
            let stats = pins.isEmpty ? nil : WikiContextStats(
                pageCount: ctx.pageIds.count,
                approximateTokens: ctx.approximateTokens
            )
            // Build the inverse backlinks index keyed by lowercased
            // page id. For each page, extract its raw `[[link]]`
            // targets, resolve each via the same case-insensitive +
            // basename-fallback rule the editor uses, and record
            // (resolved_id → source_id). A target that resolves both
            // by exact match and basename fallback only contributes
            // once — `WikiLinkResolver.resolveKey` returns the same
            // id either way.
            let backlinksIndex = Self.buildBacklinksIndex(pages: pages)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.wikiPages = pages
                self.wikiPins = pins
                self.wikiFolders = folders
                self.wikiContextStats = stats
                self.wikiBacklinksIndex = backlinksIndex
            }
        }
    }

    /// Walk every page once, extract its outbound wikilinks, resolve
    /// each, and bucket the source id under the resolved target's
    /// lowercased id. Returns a map from `lowercased(target_id)` to
    /// a sorted, deduped list of source ids that link to it.
    /// Self-links (a page wikilinking to itself) are dropped.
    private static func buildBacklinksIndex(
        pages: [WikiPage]
    ) -> [String: [String]] {
        let fullIndex = Dictionary(
            uniqueKeysWithValues: pages.map { ($0.id.lowercased(), $0) }
        )
        var basenameIndex: [String: String] = [:]
        for fullKey in fullIndex.keys.sorted() {
            let base = (fullKey as NSString).lastPathComponent
            if basenameIndex[base] == nil { basenameIndex[base] = fullKey }
        }
        var inverse: [String: Set<String>] = [:]
        for source in pages {
            for raw in WikiLinkResolver.extractLinks(from: source.content) {
                guard let key = WikiLinkResolver.resolveKey(
                    raw, fullIndex: fullIndex, basenameIndex: basenameIndex
                ),
                      let target = fullIndex[key],
                      target.id != source.id else { continue }
                inverse[target.id.lowercased(), default: []].insert(source.id)
            }
        }
        var result: [String: [String]] = [:]
        for (key, sources) in inverse {
            result[key] = sources.sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        }
        return result
    }

    /// Open a wiki page as a tab in the main content area. If the
    /// page is already open, focus the existing tab instead of
    /// duplicating. Pages new to the session append a new tab and
    /// activate it.
    func openWikiPage(_ id: String) {
        let target: WikiTab = .page(id: id)
        if !openTabs.contains(target) {
            openTabs.append(target)
        }
        activeTab = target
    }

    /// Append a fresh-draft tab using the new-page sentinel id and
    /// activate it. The page lives only in the editor's local state
    /// until the user picks a name + saves; `saveWikiPage` then
    /// rewrites the tab to use the chosen id.
    func openNewWikiPage() {
        let target: WikiTab = .page(id: ChatViewModel.newWikiPageSentinel)
        if !openTabs.contains(target) {
            openTabs.append(target)
        }
        activeTab = target
    }

    /// Close a tab. Chat is uncloseable. If the active tab was the
    /// one closed, fall back to chat (the always-present tab) so the
    /// main area never goes blank.
    func closeTab(_ tab: WikiTab) {
        guard tab != .chat else { return }
        openTabs.removeAll { $0 == tab }
        if activeTab == tab {
            activeTab = .chat
        }
    }

    func switchTab(_ tab: WikiTab) {
        guard openTabs.contains(tab) else { return }
        activeTab = tab
    }

    /// Persist the editor's draft. For new pages, `newId` is the
    /// chosen name (validated via `WikiStore`); otherwise it equals
    /// the page id being edited. Errors surface via the toast center
    /// so the sheet can stay open and the user can retry.
    func saveWikiPage(originalId: String, newId: String, content: String) {
        guard let workspaceId = activeWorkspaceId else { return }
        let store = self.wiki
        Task { [weak self] in
            do {
                // Rename: save under newId, then delete the original
                // file if the id changed (keeps pins coherent — the
                // pin set's old id is removed, and the caller can
                // re-pin under the new id if desired).
                _ = try await store.savePage(
                    workspaceId: workspaceId,
                    id: newId,
                    content: content
                )
                let isRename = !originalId.isEmpty && originalId != newId
                let isFreshSave = originalId.isEmpty
                if isRename {
                    try await store.deletePage(workspaceId: workspaceId, id: originalId)
                    // Carry the pin over to the new id so a rename
                    // doesn't silently un-pin a page.
                    let pins = (try? await store.loadPins(workspaceId: workspaceId)) ?? []
                    if pins.contains(originalId) {
                        try? await store.setPin(
                            workspaceId: workspaceId, id: newId, pinned: true
                        )
                    }
                    // Rewrite inbound wikilinks across the wiki so a
                    // rename doesn't orphan `[[oldId]]` references in
                    // sibling pages. Best-effort — failure logs a
                    // warning rather than rolling the rename back.
                    let changed = (try? await store.rewriteWikilinks(
                        workspaceId: workspaceId,
                        from: originalId,
                        to: newId
                    )) ?? 0
                    if changed > 0 {
                        await MainActor.run { [weak self] in
                            self?.toasts.show(
                                "Rewrote wikilinks in \(changed) page\(changed == 1 ? "" : "s")"
                            )
                        }
                    }
                }
                await MainActor.run {
                    guard let self else { return }
                    // Rewrite the tab so a fresh-save (new-page
                    // sentinel) or rename keeps the same tab focused
                    // under its new id, instead of leaving a stale
                    // sentinel/old-id tab dangling.
                    if isFreshSave || isRename {
                        let oldTab: WikiTab = .page(id: originalId)
                        let newTab: WikiTab = .page(id: newId)
                        if let idx = self.openTabs.firstIndex(of: oldTab) {
                            self.openTabs[idx] = newTab
                        } else if !self.openTabs.contains(newTab) {
                            self.openTabs.append(newTab)
                        }
                        if self.activeTab == oldTab || isFreshSave {
                            self.activeTab = newTab
                        }
                    }
                    self.refreshWiki()
                }
            } catch {
                await MainActor.run {
                    self?.toasts.show("Wiki save failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func deleteWikiPage(_ id: String) {
        guard let workspaceId = activeWorkspaceId else { return }
        let store = self.wiki
        Task { [weak self] in
            do {
                try await store.deletePage(workspaceId: workspaceId, id: id)
                await MainActor.run {
                    self?.closeTab(.page(id: id))
                    self?.refreshWiki()
                }
            } catch {
                await MainActor.run {
                    self?.toasts.show("Wiki delete failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func toggleWikiPin(_ id: String) {
        guard let workspaceId = activeWorkspaceId else { return }
        let store = self.wiki
        let isPinned = wikiPins.contains(id)
        // Hard cap enforcement: refuse new pins past the limit so
        // the always-inject cost stays bounded. Existing pins can
        // always be removed (no cap on unpinning).
        if !isPinned, wikiPins.count >= WikiStore.maxPinCount {
            toasts.show(
                "Pin limit reached (\(WikiStore.maxPinCount)). Unpin a page first, or rely on RAG retrieval for the rest of the wiki."
            )
            return
        }
        // Optimistic local update — re-sync from disk after the
        // write completes in case another path also touched the
        // pin set.
        if isPinned {
            wikiPins.remove(id)
        } else {
            wikiPins.insert(id)
        }
        Task { [weak self] in
            do {
                try await store.setPin(
                    workspaceId: workspaceId,
                    id: id,
                    pinned: !isPinned
                )
                await MainActor.run { self?.refreshWiki() }
            } catch {
                await MainActor.run {
                    self?.toasts.show("Pin toggle failed: \(error.localizedDescription)")
                    self?.refreshWiki()
                }
            }
        }
    }

    /// Build the sidebar tree from `wikiPages` AND `wikiFolders` so
    /// empty folders (no pages inside) still render — the storage
    /// layer can hold a folder independently of any pages, and a
    /// freshly-created folder shows up immediately rather than
    /// staying invisible until the user puts a page in it. Folders
    /// sort before pages at each level (Obsidian behaviour); both
    /// case-insensitive.
    func buildWikiTree() -> [WikiTreeNode] {
        // Folder set, keyed by lowercased path (so "abc" and "ABC"
        // can never both appear as siblings on a case-insensitive
        // filesystem) but preserving the original casing for display.
        // First observation of a key wins — subsequent observations
        // with different casing are ignored.
        var folderPaths: [String: String] = [:]  // lowerKey → originalPath
        for page in wikiPages where page.id.contains("/") {
            let parent = (page.id as NSString).deletingLastPathComponent
            addAncestors(of: parent, into: &folderPaths)
        }
        for folder in wikiFolders {
            addAncestors(of: folder, into: &folderPaths)
        }
        let allFolders = Set(folderPaths.values)
        return nodes(at: "", folderPaths: allFolders)
    }

    /// Order a folder's child pages per the active workspace's
    /// `wikiSortMode`. Alphabetical is the case-insensitive id compare
    /// used everywhere else; `modified` is newest-first (pages with no
    /// known mtime fall to the end, then break ties alphabetically);
    /// `pinFirst` floats pinned pages above unpinned, alphabetical
    /// within each band. All comparators are total + stable so the
    /// tree order is deterministic across refreshes.
    private func sortWikiPages(_ pages: [WikiPage]) -> [WikiPage] {
        func alpha(_ a: WikiPage, _ b: WikiPage) -> Bool {
            a.id.localizedCaseInsensitiveCompare(b.id) == .orderedAscending
        }
        switch wikiSortMode {
        case .alphabetical:
            return pages.sorted(by: alpha)
        case .modified:
            return pages.sorted { a, b in
                switch (a.modifiedAt, b.modifiedAt) {
                case let (da?, db?):
                    if da != db { return da > db }
                    return alpha(a, b)
                case (_?, nil): return true   // known date sorts before unknown
                case (nil, _?): return false
                case (nil, nil): return alpha(a, b)
                }
            }
        case .pinFirst:
            return pages.sorted { a, b in
                let pa = wikiPins.contains(a.id)
                let pb = wikiPins.contains(b.id)
                if pa != pb { return pa }     // pinned first
                return alpha(a, b)
            }
        }
    }

    private func addAncestors(of path: String, into table: inout [String: String]) {
        guard !path.isEmpty else { return }
        var current = path
        if table[current.lowercased()] == nil {
            table[current.lowercased()] = current
        }
        while let slash = current.lastIndex(of: "/") {
            current = String(current[current.startIndex..<slash])
            if current.isEmpty { break }
            if table[current.lowercased()] == nil {
                table[current.lowercased()] = current
            }
        }
    }

    /// Build the children of a folder at `prefix` (or the root when
    /// `prefix` is empty). All path comparisons are case-folded so
    /// `[[Folder/Page]]` and `[[folder/Page]]` resolve to the same
    /// node — matches the case-insensitive uniqueness the storage
    /// layer enforces and prevents the "two abc" phantom that
    /// previously appeared when stale state held both casings.
    private func nodes(at prefix: String, folderPaths: Set<String>) -> [WikiTreeNode] {
        let lowerPrefix = prefix.lowercased()
        let qualifiedLower = lowerPrefix.isEmpty ? "" : lowerPrefix + "/"
        // Direct child folders: case-fold both sides of the prefix
        // check, then split the suffix on `/` to ensure we only
        // pick direct children (no further slashes).
        var childFolders: [String] = []
        for folder in folderPaths {
            let lowered = folder.lowercased()
            let suffix: String
            if qualifiedLower.isEmpty {
                suffix = lowered
            } else {
                guard lowered.hasPrefix(qualifiedLower) else { continue }
                suffix = String(lowered.dropFirst(qualifiedLower.count))
            }
            if suffix.isEmpty || suffix.contains("/") { continue }
            childFolders.append(folder)
        }
        childFolders.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        // Direct child pages — same case-folded prefix logic.
        var childPages: [WikiPage] = []
        for page in wikiPages {
            let lowered = page.id.lowercased()
            let suffix: String
            if qualifiedLower.isEmpty {
                suffix = lowered
            } else {
                guard lowered.hasPrefix(qualifiedLower) else { continue }
                suffix = String(lowered.dropFirst(qualifiedLower.count))
            }
            if suffix.isEmpty || suffix.contains("/") { continue }
            childPages.append(page)
        }
        childPages = sortWikiPages(childPages)

        var out: [WikiTreeNode] = []
        for folder in childFolders {
            let basename = (folder as NSString).lastPathComponent
            out.append(.folder(
                id: folder,
                name: basename,
                children: nodes(at: folder, folderPaths: folderPaths)
            ))
        }
        for page in childPages {
            out.append(.page(page))
        }
        return out
    }

    /// Create a new folder under the wiki root. Used by the sidebar
    /// toolbar's "New folder" button. Failures (path validation,
    /// permissions) surface via the toast center.
    /// Move a page to a new path. Used by sidebar drag-to-move:
    /// dropping a page onto a folder builds `<folder>/<basename>` as
    /// the new id; dropping onto the root drop target uses the bare
    /// basename. The store layer carries pin state and rewrites
    /// inbound wikilinks; the VM updates the open-tab list so a tab
    /// for the moved page keeps tracking it under the new id.
    func moveWikiPage(from oldId: String, to newId: String) {
        guard let workspaceId = activeWorkspaceId else { return }
        guard oldId != newId else { return }
        let store = self.wiki
        Task { [weak self] in
            do {
                _ = try await store.movePage(
                    workspaceId: workspaceId,
                    from: oldId,
                    to: newId
                )
                await MainActor.run {
                    guard let self else { return }
                    let oldTab: WikiTab = .page(id: oldId)
                    let newTab: WikiTab = .page(id: newId)
                    if let idx = self.openTabs.firstIndex(of: oldTab) {
                        self.openTabs[idx] = newTab
                    }
                    if self.activeTab == oldTab {
                        self.activeTab = newTab
                    }
                    self.refreshWiki()
                }
            } catch {
                await MainActor.run {
                    self?.toasts.show(
                        "Move failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Move a folder (and every page beneath it) to a new path. The
    /// store layer carries pins + rewrites inbound wikilinks; this
    /// helper additionally remaps any open tabs whose page id was
    /// under the moved folder, so a tab tracking `Old/Page` keeps
    /// focus as `New/Page` after the move.
    func moveWikiFolder(from oldPath: String, to newPath: String) {
        guard let workspaceId = activeWorkspaceId else { return }
        guard oldPath != newPath else { return }
        let store = self.wiki
        Task { [weak self] in
            do {
                _ = try await store.moveFolder(
                    workspaceId: workspaceId,
                    from: oldPath,
                    to: newPath
                )
                await MainActor.run {
                    guard let self else { return }
                    let oldPrefix = oldPath + "/"
                    self.openTabs = self.openTabs.map { tab in
                        if case .page(let id) = tab, id.hasPrefix(oldPrefix) {
                            let suffix = String(id.dropFirst(oldPrefix.count))
                            return .page(id: newPath + "/" + suffix)
                        }
                        return tab
                    }
                    if case .page(let id) = self.activeTab, id.hasPrefix(oldPrefix) {
                        let suffix = String(id.dropFirst(oldPrefix.count))
                        self.activeTab = .page(id: newPath + "/" + suffix)
                    }
                    self.refreshWiki()
                }
            } catch {
                await MainActor.run {
                    self?.toasts.show(
                        "Folder move failed: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    /// Reorder tabs by inserting the source tab immediately before
    /// the target. No-op when source == target. Chat (tab 0) is
    /// fixed-position; if either side of the swap is chat, the move
    /// is silently rejected so the bar can never be in a state where
    /// chat isn't first.
    func reorderTab(_ source: WikiTab, before target: WikiTab) {
        guard source != target else { return }
        guard source != .chat, target != .chat else { return }
        guard let srcIdx = openTabs.firstIndex(of: source),
              let tgtIdx = openTabs.firstIndex(of: target) else { return }
        var working = openTabs
        working.remove(at: srcIdx)
        let newTgtIdx = working.firstIndex(of: target) ?? tgtIdx
        working.insert(source, at: newTgtIdx)
        openTabs = working
    }

    func createWikiFolder(_ path: String) {
        guard let workspaceId = activeWorkspaceId else { return }
        let store = self.wiki
        Task { [weak self] in
            do {
                try await store.createFolder(workspaceId: workspaceId, path: path)
                await MainActor.run { self?.refreshWiki() }
            } catch {
                await MainActor.run {
                    self?.toasts.show("Folder create failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func deleteWikiFolder(_ path: String) {
        guard let workspaceId = activeWorkspaceId else { return }
        let store = self.wiki
        Task { [weak self] in
            do {
                try await store.deleteFolder(workspaceId: workspaceId, path: path)
                await MainActor.run {
                    if let self {
                        let prefix = path + "/"
                        let toClose = self.openTabs.compactMap { tab -> WikiTab? in
                            if case .page(let id) = tab, id.hasPrefix(prefix) { return tab }
                            return nil
                        }
                        for tab in toClose { self.closeTab(tab) }
                    }
                    self?.refreshWiki()
                }
            } catch {
                await MainActor.run {
                    self?.toasts.show("Folder delete failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Pages whose body contains a wikilink resolving to `target`.
    /// O(1) lookup against `wikiBacklinksIndex` (built once per
    /// `refreshWiki`); previously walked every page in the workspace
    /// on every call. Returns ids in alphabetical order. Empty for
    /// the new-page sentinel.
    func loadBacklinks(for target: String) async -> [String] {
        guard !target.isEmpty else { return [] }
        return wikiBacklinksIndex[target.lowercased()] ?? []
    }

    /// Rank pages against a fuzzy query, shared by the inline sidebar
    /// search field and the Cmd+O quick switcher so both order results
    /// identically. Empty query returns the first `limit` pages in
    /// natural (already-sorted) order. Otherwise the bands are, in
    /// priority: basename prefix match, basename substring match, then
    /// full-path (folder name) substring match — so "filter by
    /// basename + folder name" both contribute, basename winning ties.
    /// Capped at `limit`; larger wikis lean on RAG for retrieval.
    func rankedWikiPages(matching query: String, limit: Int = 50) -> [WikiPage] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Array(wikiPages.prefix(limit)) }
        func base(_ id: String) -> String {
            (id as NSString).lastPathComponent.lowercased()
        }
        let prefix = wikiPages.filter { base($0.id).hasPrefix(q) }
        let contains = wikiPages.filter {
            let b = base($0.id)
            return !b.hasPrefix(q) && b.contains(q)
        }
        let inPath = wikiPages.filter {
            let b = base($0.id)
            return !b.contains(q) && $0.id.lowercased().contains(q)
        }
        return Array((prefix + contains + inPath).prefix(limit))
    }

    /// Read one page synchronously for the editor sheet. Falls back
    /// to empty content for the new-page sentinel.
    func loadWikiPageContent(_ id: String) async -> String {
        if id.isEmpty { return "" }
        guard let workspaceId = activeWorkspaceId else { return "" }
        let page = try? await wiki.loadPage(workspaceId: workspaceId, id: id)
        return page?.content ?? ""
    }
}
