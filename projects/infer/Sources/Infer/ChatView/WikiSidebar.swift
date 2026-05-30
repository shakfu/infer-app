import SwiftUI
import AppKit
import InferCore
import UniformTypeIdentifiers

/// Payload carried by a sidebar drag — a single wiki page id. The
/// `.draggable` source is the leaf row; `.dropDestination` targets are
/// folder rows + a root drop zone, which assemble the new id by
/// appending the basename to the destination folder (or use the bare
/// basename for the root case).
struct WikiPageDragPayload: Codable, Transferable {
    let pageId: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .wikiPageDrag)
    }
}

/// Payload for dragging a whole folder. Distinct UTI from
/// `WikiPageDragPayload` so drop targets can opt into accepting one,
/// the other, or both — folder rows take both (drop-page nests the
/// page inside; drop-folder nests the source folder), the trailing
/// root drop target only takes pages (folder-to-root is "rename to
/// the basename" — a less common operation; users with that intent
/// can rename via context menu in Phase 4f).
struct WikiFolderDragPayload: Codable, Transferable {
    let folderId: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .wikiFolderDrag)
    }
}

extension UTType {
    static let wikiPageDrag = UTType(exportedAs: "com.infer.wiki.page.drag")
    static let wikiFolderDrag = UTType(exportedAs: "com.infer.wiki.folder.drag")
}

/// Left sidebar — per-workspace wiki page list with pin toggles plus a
/// shortcut to advanced workspace settings (which still live in the
/// modal `WorkspaceSheet` for now; full migration is Phase 2b).
///
/// Layout:
///   ┌─ Workspace picker (dropdown) ──────┐
///   ├─ Pages (header + new-page button) ─┤
///   │   📌 Pinned page                   │
///   │      Other page                    │
///   │      ...                           │
///   ├─ "Workspace settings…" button ─────┤
///   └────────────────────────────────────┘
///
/// Pin toggle is a click on the pin icon; clicking the row body opens
/// the editor sheet. Right-click context menu exposes Rename / Delete.
struct WikiSidebar: View {
    @Bindable var vm: ChatViewModel
    @State private var promptingNewFolder = false
    @State private var newFolderName = ""
    /// Shared font for the tree-toolbar glyphs. Light weight + a
    /// slightly larger point size mimics the thin 1.5px stroke of
    /// Obsidian's lucide icons, which read airier than SF Symbols at
    /// the default (regular) weight.
    private static let toolbarIconFont: Font = .system(size: 15, weight: .light)
    /// Inline tree-search query. Transient and per-workspace: cleared
    /// on workspace switch (below) so one workspace's search never
    /// bleeds into another. Non-empty flips the tree to a flat ranked
    /// result list.
    @State private var searchQuery = ""
    /// Drives the workspace-settings sheet presentation. Opened by
    /// the cog button in the footer; auto-closes if the active
    /// workspace changes mid-edit so the sheet always reflects the
    /// workspace the user thinks they're editing.
    @State private var showingWorkspaceSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.activeWorkspaceId == nil {
                emptyWorkspaceState
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        pageList
                    }
                }
            }
            // No divider above the footer — keeps the sidebar's
            // bottom edge symmetric with the chat / right-sidebar
            // panes which don't draw a horizontal rule before
            // their bottom controls. The cog + pin-stats sit
            // directly against the page list, separated only by
            // padding.
            footer
        }
        .frame(maxHeight: .infinity)
        .onAppear { vm.refreshWiki() }
        .onChange(of: vm.activeWorkspaceId) { _, _ in
            vm.refreshWiki()
            // Close the settings sheet on workspace switch so the
            // user never sees the sheet pinned to a workspace
            // they're no longer in.
            showingWorkspaceSettings = false
            // Per-workspace search: drop the query so the new
            // workspace starts with its full tree, not a filter
            // carried over from the workspace just left.
            searchQuery = ""
        }
        .sheet(isPresented: $showingWorkspaceSettings) {
            if let active = vm.workspaces.first(where: { $0.id == vm.activeWorkspaceId }) {
                WorkspaceSettingsSheet(
                    vm: vm,
                    workspace: active,
                    isPresented: $showingWorkspaceSettings
                )
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 6) {
            WorkspacePickerMenu(vm: vm) {
                showingWorkspaceSettings = true
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var pageList: some View {
        VStack(spacing: 0) {
            treeToolbar
            searchField
            let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedQuery.isEmpty {
                searchResults(query: trimmedQuery)
            } else if vm.wikiPages.isEmpty && vm.wikiFolders.isEmpty {
                // Show the tree whenever there's anything to render —
                // pages OR empty folders. The empty-state placeholder
                // only fires when the workspace's wiki is genuinely
                // bare on disk; an empty folder created via the toolbar
                // is reason enough to render the tree.
                emptyPagesState
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(vm.buildWikiTree()) { node in
                        WikiTreeRow(node: node, depth: 0, vm: vm)
                    }
                }
                // Trailing drop target: dragging a nested page onto
                // empty space below the tree moves it back to the
                // wiki root. Tall enough (24pt) to be a comfortable
                // hit target without dominating the layout.
                Color.clear
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .dropDestination(for: WikiPageDragPayload.self) { drops, _ in
                        moveDroppedPagesToRoot(drops)
                        return !drops.isEmpty
                    }
            }
        }
    }

    /// Collapse every folder in the tree by writing `false` to each
    /// folder's fold-state key. Walks the full built tree so even
    /// folders currently unmounted (because an ancestor is collapsed)
    /// are collapsed too — the next time they mount they read the
    /// stored `false`. Mounted `WikiFolderRow`s observe their
    /// `@AppStorage` key and re-render closed immediately.
    private func collapseAllFolders() {
        for id in folderIds(in: vm.buildWikiTree()) {
            UserDefaults.standard.set(false, forKey: WikiFolderRow.foldStateKey(id))
        }
    }

    /// Every folder id in a tree, depth-first.
    private func folderIds(in nodes: [WikiTreeNode]) -> [String] {
        var ids: [String] = []
        for node in nodes {
            if case .folder(let id, _, let children) = node {
                ids.append(id)
                ids.append(contentsOf: folderIds(in: children))
            }
        }
        return ids
    }

    /// Move every dropped page to the wiki root by stripping its
    /// folder prefix. No-op if the page is already at root.
    private func moveDroppedPagesToRoot(_ drops: [WikiPageDragPayload]) {
        for drop in drops {
            let basename = (drop.pageId as NSString).lastPathComponent
            if basename != drop.pageId {
                vm.moveWikiPage(from: drop.pageId, to: basename)
            }
        }
    }

    /// Obsidian-style centered icon row above the tree — no labels,
    /// equal spacing, slightly larger glyphs than the inline tree
    /// chevrons so the toolbar reads as the primary affordance area.
    private var treeToolbar: some View {
        HStack(spacing: 14) {
            Button { vm.openNewWikiPage() } label: {
                Image(systemName: "square.and.pencil")
                    .font(Self.toolbarIconFont)
            }
            .buttonStyle(WikiToolbarButtonStyle())
            .help("New page")

            Button { promptingNewFolder = true } label: {
                Image(systemName: "folder.badge.plus")
                    .font(Self.toolbarIconFont)
            }
            .buttonStyle(WikiToolbarButtonStyle())
            .help("New folder")

            Menu {
                Picker("Sort pages by", selection: Binding(
                    get: { vm.wikiSortMode },
                    set: { vm.wikiSortMode = $0 }
                )) {
                    ForEach(WikiSortMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                // Obsidian's "change sort order" is an up-arrow beside
                // stacked lines (lucide `arrow-up-narrow-wide`); the
                // macOS-native equivalent is this arrows-with-lines
                // sort glyph rather than the two opposing arrows of
                // `arrow.up.arrow.down`.
                Image(systemName: "arrow.up.and.down.text.horizontal")
                    .font(Self.toolbarIconFont)
            }
            // Render the menu *as a button* so it routes through the
            // same `WikiToolbarButtonStyle` as the plain buttons —
            // otherwise a menu carries its own tint / press treatment
            // and reads brighter than its dim siblings. `.fixedSize`
            // keeps it from stretching; the indicator chevron is hidden
            // so it's icon-only like the rest.
            .menuStyle(.button)
            .buttonStyle(WikiToolbarButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort pages (this workspace)")

            Button { collapseAllFolders() } label: {
                Image(systemName: "rectangle.compress.vertical")
                    .font(Self.toolbarIconFont)
            }
            .buttonStyle(WikiToolbarButtonStyle())
            .help("Collapse all folders")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .alert("New folder", isPresented: $promptingNewFolder) {
            TextField("folder name (use / for nested)", text: $newFolderName)
            Button("Create") {
                let trimmed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    vm.createWikiFolder(trimmed)
                }
                newFolderName = ""
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
    }

    /// Inline fuzzy-search field above the tree. Filters the active
    /// workspace's pages by basename + folder name; a non-empty query
    /// flips `pageList` to a flat ranked result list. The trailing
    /// clear button restores the full tree.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search pages…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    /// Flat, ranked result list shown while a search query is active.
    /// Rows reuse `WikiPageRow` at depth 0 (no tree indent) and carry
    /// the same open / pin / rename / delete actions as tree rows, so
    /// search is a fully-functional view of the wiki, not just a jump
    /// list. Ranking is shared with the Cmd+O switcher via
    /// `vm.rankedWikiPages`.
    @ViewBuilder
    private func searchResults(query: String) -> some View {
        let results = vm.rankedWikiPages(matching: query)
        if results.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("No pages match “\(query)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(results) { page in
                    WikiSearchResultRow(page: page, vm: vm)
                }
            }
        }
    }

    private var emptyWorkspaceState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Create or select a workspace to start a wiki.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxHeight: .infinity)
    }

    private var emptyPagesState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("No pages yet")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Create a page") { vm.openNewWikiPage() }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            // Cog at the bottom-left opens the modal workspace
            // settings sheet for the active workspace. Replaces the
            // prior inline-disclosure embedding above the footer.
            Button {
                showingWorkspaceSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(vm.isDefaultWorkspace(vm.activeWorkspaceId ?? -1)
                ? "Default workspace settings (global defaults for new workspaces)"
                : "Workspace settings")
            .disabled(vm.activeWorkspaceId == nil)

            if let stats = vm.wikiContextStats {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("\(stats.pageCount)/\(WikiStore.maxPinCount) pinned · ~\(formattedTokens(stats.approximateTokens)) tok every turn")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help("Pinned pages always inject. The rest of the wiki is searchable via RAG (when the embedding model is downloaded).")
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Compact token formatter — "8.2k" instead of "8200" so the
    /// footer fits in a 240pt sidebar without truncation.
    private func formattedTokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        return String(format: "%.1fk", Double(n) / 1000.0)
    }
}

/// Unified style for the wiki tree-toolbar glyph buttons (new page,
/// new folder, sort, collapse-all). All four — including the sort
/// `Menu` rendered via `.menuStyle(.button)` — share this so they read
/// identically: a dim (`.secondary`) glyph with a rounded background
/// tint on hover and a slightly stronger one while pressed. Replaces
/// the prior mix of `.borderless` (which brightened the *foreground*
/// on press) and `.borderlessButton` menu styling, whose differing
/// treatments made the row look inconsistent.
private struct WikiToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconLabel(configuration: configuration)
    }

    private struct IconLabel: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(glyph)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(background)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: hovering)
        }

        /// Glyph color: dim at rest, fully opaque (primary) while
        /// pressed so the press reads on the icon itself rather than
        /// leaning on the background tint.
        private var glyph: Color {
            configuration.isPressed ? .primary : .secondary
        }

        private var background: Color {
            if configuration.isPressed { return Color.secondary.opacity(0.18) }
            if hovering { return Color.secondary.opacity(0.08) }
            return .clear
        }
    }
}

/// Per-depth indent step in points. 17pt mirrors Obsidian's tree
/// indent — wide enough that the vertical guide line for nested
/// content sits clearly under the parent's chevron, narrow enough
/// that 4-deep paths don't push titles off-screen in a 240pt sidebar.
private let wikiTreeIndentStep: CGFloat = 17

/// Vertical guide rails drawn at every ancestor depth so the user
/// can trace a row up to its parent folder, the way Obsidian does.
/// Each rail is a hairline `Rectangle` 1pt wide centered in its
/// indent column; the row's leading padding is built up from these
/// rails plus a small base inset.
///
/// Rails draw on the parent's chevron column, NOT the row's own
/// indent column — that's why the loop runs `0..<depth` (drawing
/// `depth` rails), and the actual row content starts at
/// `depth * step + baseInset`.
private struct WikiTreeIndentGuides: View {
    let depth: Int
    private let baseInset: CGFloat = 6

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<depth, id: \.self) { _ in
                Rectangle()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(width: 1)
                    .padding(.leading, wikiTreeIndentStep / 2)
                    .padding(.trailing, (wikiTreeIndentStep / 2) - 1)
            }
        }
        .padding(.leading, baseInset)
    }
}

/// Recursive row that switches on `WikiTreeNode`. Folders render a
/// chevron + name (no icon — Obsidian-style); pages render a plain
/// title row. Folder open/closed state persists per-folder via
/// @AppStorage so the user's collapse layout survives relaunch.
struct WikiTreeRow: View {
    let node: WikiTreeNode
    let depth: Int
    let vm: ChatViewModel

    var body: some View {
        switch node {
        case .folder(let id, let name, let children):
            WikiFolderRow(
                folderId: id,
                name: name,
                children: children,
                depth: depth,
                vm: vm
            )
        case .page(let page):
            WikiPageRow(
                page: page,
                pinned: vm.wikiPins.contains(page.id),
                isActive: vm.activeTab == .page(id: page.id),
                depth: depth,
                onOpen: { vm.openWikiPage(page.id) },
                onTogglePin: { vm.toggleWikiPin(page.id) },
                onRename: { newBasename in
                    // Rename = move to the same parent under the new
                    // basename. Cross-folder moves go through drag.
                    let parent = (page.id as NSString).deletingLastPathComponent
                    let newId = parent.isEmpty ? newBasename : parent + "/" + newBasename
                    vm.moveWikiPage(from: page.id, to: newId)
                },
                onDelete: { vm.deleteWikiPage(page.id) }
            )
        }
    }
}

/// A page row in the flat search-results list. Wraps `WikiPageRow`
/// with the same open / pin / rename / delete wiring as the tree's
/// `.page` case (see `WikiTreeRow`), at depth 0 so there's no tree
/// indent. Kept as its own view so the search list and the tree share
/// one row implementation rather than duplicating the action closures.
struct WikiSearchResultRow: View {
    let page: WikiPage
    let vm: ChatViewModel

    var body: some View {
        WikiPageRow(
            page: page,
            pinned: vm.wikiPins.contains(page.id),
            isActive: vm.activeTab == .page(id: page.id),
            depth: 0,
            onOpen: { vm.openWikiPage(page.id) },
            onTogglePin: { vm.toggleWikiPin(page.id) },
            onRename: { newBasename in
                let parent = (page.id as NSString).deletingLastPathComponent
                let newId = parent.isEmpty ? newBasename : parent + "/" + newBasename
                vm.moveWikiPage(from: page.id, to: newId)
            },
            onDelete: { vm.deleteWikiPage(page.id) }
        )
    }
}

/// Folder row — leading chevron (rotates on expand), folder icon,
/// folder name. Click anywhere on the row toggles open/closed. Right-
/// click context menu exposes "New page in folder" + "Delete folder".
struct WikiFolderRow: View {
    let folderId: String
    let name: String
    let children: [WikiTreeNode]
    let depth: Int
    let vm: ChatViewModel

    @AppStorage private var open: Bool
    @State private var hovering = false
    @State private var dropTargeted = false
    @State private var promptingNewPage = false
    @State private var newPageName = ""
    @State private var promptingNewSubfolder = false
    @State private var newSubfolderName = ""
    @State private var promptingRename = false
    @State private var renameInput = ""
    @State private var confirmingDelete = false

    /// `UserDefaults` key for a folder's open/closed state, keyed by
    /// full folder path so nested folders with identical basenames
    /// don't share fold state. Shared with the toolbar's collapse-all
    /// action so the two can't drift.
    static func foldStateKey(_ folderId: String) -> String {
        "infer.wiki.foldOpen.\(folderId)"
    }

    init(folderId: String, name: String, children: [WikiTreeNode], depth: Int, vm: ChatViewModel) {
        self.folderId = folderId
        self.name = name
        self.children = children
        self.depth = depth
        self.vm = vm
        self._open = AppStorage(wrappedValue: true, Self.foldStateKey(folderId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                WikiTreeIndentGuides(depth: depth)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .animation(.easeInOut(duration: 0.12), value: open)
                    .frame(width: wikiTreeIndentStep, alignment: .center)
                Text(name)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(folderRowBackground)
            .overlay(alignment: .leading) {
                if dropTargeted {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 2)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // `.draggable` registers a press-and-hold gesture that
            // on macOS would otherwise swallow the tap, breaking the
            // expand/collapse toggle. `.simultaneousGesture` runs
            // alongside the drag gesture so a click still fires
            // `open.toggle()` while a press-and-drag still initiates
            // a folder move.
            .simultaneousGesture(TapGesture().onEnded { open.toggle() })
            .draggable(WikiFolderDragPayload(folderId: folderId))
            .dropDestination(for: WikiPageDragPayload.self) { drops, _ in
                handleDrop(drops)
                return !drops.isEmpty
            } isTargeted: { dropTargeted = $0 }
            .dropDestination(for: WikiFolderDragPayload.self) { drops, _ in
                handleFolderDrop(drops)
                return !drops.isEmpty
            } isTargeted: { dropTargeted = dropTargeted || $0 }
            .contextMenu {
                Button("New page in “\(name)”") { promptingNewPage = true }
                Button("New folder in “\(name)”") { promptingNewSubfolder = true }
                Button("Rename folder") {
                    renameInput = name
                    promptingRename = true
                }
                Divider()
                Button("Delete folder", role: .destructive) { confirmingDelete = true }
            }
            .alert("Rename folder", isPresented: $promptingRename) {
                TextField("folder name", text: $renameInput)
                Button("Rename") {
                    let trimmed = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed != name else { return }
                    let parent = (folderId as NSString).deletingLastPathComponent
                    let newPath = parent.isEmpty ? trimmed : parent + "/" + trimmed
                    vm.moveWikiFolder(from: folderId, to: newPath)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a new name (basename only — to move into a different parent folder, drag the folder).")
            }
            .alert("New page in “\(name)”", isPresented: $promptingNewPage) {
                TextField("page name", text: $newPageName)
                Button("Create") {
                    let trimmed = newPageName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        // Save an empty page at folder/<name>; the
                        // VM rewrites the active tab to the new id.
                        vm.saveWikiPage(
                            originalId: ChatViewModel.newWikiPageSentinel,
                            newId: folderId + "/" + trimmed,
                            content: ""
                        )
                        vm.openWikiPage(folderId + "/" + trimmed)
                    }
                    newPageName = ""
                }
                Button("Cancel", role: .cancel) { newPageName = "" }
            }
            .alert("New folder in “\(name)”", isPresented: $promptingNewSubfolder) {
                TextField("folder name", text: $newSubfolderName)
                Button("Create") {
                    let trimmed = newSubfolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        vm.createWikiFolder(folderId + "/" + trimmed)
                        // Auto-open the parent so the user sees the
                        // new subfolder appear without having to
                        // expand manually.
                        open = true
                    }
                    newSubfolderName = ""
                }
                Button("Cancel", role: .cancel) { newSubfolderName = "" }
            }
            .alert("Delete folder “\(name)” and all pages inside?",
                   isPresented: $confirmingDelete,
                   actions: {
                       Button("Delete", role: .destructive) {
                           vm.deleteWikiFolder(folderId)
                       }
                       Button("Cancel", role: .cancel) {}
                   },
                   message: {
                       Text("This permanently removes every page nested under this folder. Inbound wikilinks resolve as unresolved until updated.")
                   })

            if open {
                ForEach(children) { child in
                    WikiTreeRow(node: child, depth: depth + 1, vm: vm)
                }
            }
        }
    }

    /// Folder header background. Drop-targeted is the only place we
    /// keep an accent tint — it's a transient interaction state where
    /// the user needs unambiguous "here's where it lands" feedback.
    /// Hover stays as the same gray as page rows for visual coherence.
    private var folderRowBackground: Color {
        if dropTargeted { return Color.accentColor.opacity(0.12) }
        if hovering { return Color.secondary.opacity(0.08) }
        return Color.clear
    }

    /// Move every dropped page into this folder, preserving its
    /// basename. A page already inside this folder is a no-op (same
    /// new id as old). Pages already nested at deeper paths under
    /// this folder also stay put — moving `Folder/Sub/Page` "into"
    /// `Folder` would silently flatten the structure, which the user
    /// almost never wants. We treat such drops as no-ops; flattening
    /// requires an explicit drag onto a deeper target.
    private func handleDrop(_ drops: [WikiPageDragPayload]) {
        for drop in drops {
            let basename = (drop.pageId as NSString).lastPathComponent
            let newId = folderId + "/" + basename
            // Skip self-drops and skip drops where the source is
            // already directly under this folder (prevents the
            // flattening case).
            if drop.pageId.lowercased() == newId.lowercased() { continue }
            vm.moveWikiPage(from: drop.pageId, to: newId)
        }
    }

    /// Nest a dropped folder under this folder. Cycle / collision
    /// guards live in `WikiStore.moveFolder`; here we just compute
    /// the new path and call the VM. Self-drops are no-ops.
    private func handleFolderDrop(_ drops: [WikiFolderDragPayload]) {
        for drop in drops {
            if drop.folderId.lowercased() == folderId.lowercased() { continue }
            let basename = (drop.folderId as NSString).lastPathComponent
            let newPath = folderId + "/" + basename
            vm.moveWikiFolder(from: drop.folderId, to: newPath)
        }
    }
}

/// Page leaf row. No file icon — Obsidian renders pages as plain
/// titles indented under the parent folder, with the indent guides
/// providing the structural cue. Pinned status is shown via a small
/// trailing dot (always visible when pinned, hover-affordance for
/// toggling otherwise).
private struct WikiPageRow: View {
    let page: WikiPage
    let pinned: Bool
    let isActive: Bool
    let depth: Int
    let onOpen: () -> Void
    let onTogglePin: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var promptingRename = false
    @State private var renameInput = ""

    var body: some View {
        HStack(spacing: 0) {
            WikiTreeIndentGuides(depth: depth)
            // Skip the chevron column so the title aligns under
            // sibling folder names rather than under the chevron's
            // text. Obsidian's leaf rows pad equivalent to the
            // chevron width so the structure reads as a real tree.
            Spacer()
                .frame(width: wikiTreeIndentStep)
            Text(displayName)
                .font(.system(size: 13))
                .fontWeight(isActive ? .medium : .regular)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if pinned || hovering {
                Button(action: onTogglePin) {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(pinned ? .orange : .secondary)
                }
                .buttonStyle(.borderless)
                .help(pinned ? "Unpin" : "Pin (always inject)")
            }
        }
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Same `.draggable`-vs-tap conflict as folder rows: use a
        // simultaneous gesture so click-to-open still fires while
        // press-and-drag initiates a page move.
        .simultaneousGesture(TapGesture().onEnded { onOpen() })
        .contextMenu {
            Button("Open", action: onOpen)
            Button(pinned ? "Unpin" : "Pin", action: onTogglePin)
            Button("Rename") {
                renameInput = displayName
                promptingRename = true
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .alert("Rename page", isPresented: $promptingRename) {
            TextField("page name", text: $renameInput)
            Button("Rename") {
                let trimmed = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != displayName else { return }
                onRename(trimmed)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new name (basename only — to move between folders, drag the page).")
        }
        // Drag the page id; folder rows + the trailing root drop
        // target handle the move via `vm.moveWikiPage`.
        .draggable(WikiPageDragPayload(pageId: page.id))
    }

    /// Render the basename only — folder context is conveyed by the
    /// row's depth indent, mirroring Obsidian. Falls back to the
    /// full id for root-level pages.
    private var displayName: String {
        (page.id as NSString).lastPathComponent
    }

    /// Obsidian-style: subtle gray for selection (not accent blue),
    /// even subtler gray on hover. Active state wins over hover.
    private var rowBackground: Color {
        if isActive { return Color.secondary.opacity(0.18) }
        if hovering { return Color.secondary.opacity(0.08) }
        return Color.clear
    }
}
