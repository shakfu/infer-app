import Foundation

/// One markdown page in a workspace's wiki. The page id is the filename
/// stem ("My Page.md" → "My Page"); content is the full markdown body
/// loaded on read. Wikilinks (`[[Other Page]]`) are resolved by stem
/// match, case-insensitively, so casing tweaks don't break links.
public struct WikiPage: Equatable, Sendable, Identifiable {
    public let id: String
    public let url: URL
    public let content: String

    public init(id: String, url: URL, content: String) {
        self.id = id
        self.url = url
        self.content = content
    }
}

/// Result of building the always-inject context for a chat turn:
/// the concatenated body, the page ids that contributed, the count of
/// pages that were dropped because the budget cap fired, and the
/// (string) approximation of token use the cap was checking.
public struct WikiContext: Equatable, Sendable {
    public let text: String
    public let pageIds: [String]
    public let droppedPageIds: [String]
    public let approximateTokens: Int

    public static let empty = WikiContext(
        text: "",
        pageIds: [],
        droppedPageIds: [],
        approximateTokens: 0
    )
}

/// Per-workspace markdown wiki. Pages live as `.md` files under
/// `~/Library/Application Support/Infer/workspaces/<id>/wiki/` (the
/// trailing dir is created lazily on first write). Pin state lives in
/// a sibling `.pins.json` index — Set<page id> — so toggling a pin
/// doesn't have to rewrite the page.
///
/// The wiki composes with RAG, not against it: RAG retrieves chunks
/// per-query from `data_folder`; the wiki is the user's curated,
/// always-injected note set. They share a workspace but address
/// different needs (curated vs. searchable bulk).
///
/// Phase 1 scope: list / load / save / pin / build always-inject
/// context. Editor UI (left sidebar) is Phase 2.
public actor WikiStore {
    /// Root directory holding per-workspace wiki subdirs. Override for
    /// tests via the initializer's `rootURL` parameter; production uses
    /// `defaultRootURL()`.
    public static func defaultRootURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Infer", isDirectory: true)
            .appendingPathComponent("workspaces", isDirectory: true)
    }

    private let rootURL: URL

    public init(rootURL: URL = WikiStore.defaultRootURL()) {
        self.rootURL = rootURL
    }

    /// Wiki directory for a workspace. Created on demand by writers;
    /// readers handle missing dirs as "empty wiki".
    public func wikiDirectory(for workspaceId: Int64) -> URL {
        rootURL
            .appendingPathComponent(String(workspaceId), isDirectory: true)
            .appendingPathComponent("wiki", isDirectory: true)
    }

    private func pinsURL(for workspaceId: Int64) -> URL {
        wikiDirectory(for: workspaceId).appendingPathComponent(".pins.json")
    }

    // MARK: - Pages

    /// List every `.md` page in the workspace recursively. Page id
    /// is the path stem relative to the wiki root, using `/` as the
    /// separator regardless of host-platform conventions, so a file
    /// at `wiki/Notes/Daily/2026-05-07.md` has id `Notes/Daily/2026-05-07`.
    /// Sorted by id (case-insensitive).
    ///
    /// Hidden files (leading `.`) and directories starting with `.`
    /// are skipped so the pin index file (`.pins.json`) and macOS
    /// metadata dirs don't pollute the listing.
    public func listPages(workspaceId: Int64) throws -> [WikiPage] {
        let dir = wikiDirectory(for: workspaceId)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }
        // `subpaths(atPath:)` recursively enumerates every entry below
        // the given directory and returns each as a relative path
        // string — much simpler than building relative paths from
        // enumerator URLs (which need symlink-aware standardisation
        // on every platform we ship to). The trade-off is a slight
        // performance hit for very large wikis (~thousands of pages),
        // which we don't expect for the personal-notes use case.
        guard let subpaths = fm.subpaths(atPath: dir.path) else { return [] }
        var pages: [WikiPage] = []
        for subpath in subpaths {
            guard subpath.hasSuffix(".md") else { continue }
            // Skip files under hidden directories so the pin index
            // file (`.pins.json` and any `.foo/` macOS metadata) and
            // their contents don't leak into the page list.
            let comps = subpath.split(separator: "/")
            if comps.contains(where: { $0.hasPrefix(".") }) { continue }
            let stem = String(subpath.dropLast(3))
            guard !stem.isEmpty else { continue }
            let url = dir.appendingPathComponent(subpath)
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            pages.append(WikiPage(id: stem, url: url, content: content))
        }
        pages.sort { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
        return pages
    }

    /// Every folder under the wiki root, recursive. Returned as
    /// relative path strings (e.g. `Notes`, `Notes/Daily`,
    /// `Notes/Daily/Drafts`), sorted case-insensitively. The sidebar
    /// merges these with folders inferable from page paths so empty
    /// folders (which have no pages and thus would otherwise be
    /// invisible) still render in the tree. Hidden directories
    /// (leading `.`) are filtered so `.git`-style folders inside a
    /// wiki dir don't pollute the tree.
    public func listAllFolders(workspaceId: Int64) throws -> [String] {
        let dir = wikiDirectory(for: workspaceId)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }
        guard let subpaths = fm.subpaths(atPath: dir.path) else { return [] }
        var folders: [String] = []
        for subpath in subpaths {
            let comps = subpath.split(separator: "/")
            if comps.contains(where: { $0.hasPrefix(".") }) { continue }
            let url = dir.appendingPathComponent(subpath)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                folders.append(subpath)
            }
        }
        folders.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return folders
    }

    /// List immediate child directories of `parent` (or root when
    /// `parent` is nil). Returns folder ids relative to the wiki
    /// root (e.g. `Notes/Daily` for a folder two levels deep). Used
    /// by the sidebar tree renderer to enumerate folders that are
    /// otherwise inferable only from the pages within them.
    public func listFolders(workspaceId: Int64, under parent: String? = nil) throws -> [String] {
        let dir = wikiDirectory(for: workspaceId)
        let fm = FileManager.default
        let scanRoot: URL
        if let parent, !parent.isEmpty {
            scanRoot = dir.appendingPathComponent(parent, isDirectory: true)
        } else {
            scanRoot = dir
        }
        guard fm.fileExists(atPath: scanRoot.path) else { return [] }
        let urls = try fm.contentsOfDirectory(
            at: scanRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let rootPath = dir.standardizedFileURL.path
        var folders: [String] = []
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let abs = url.standardizedFileURL.path
            guard abs.hasPrefix(rootPath) else { continue }
            var rel = String(abs.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            if !rel.isEmpty { folders.append(rel) }
        }
        folders.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return folders
    }

    /// Move a page from one path to another. Used by sidebar drag-
    /// to-move (page → folder). Carries the pin from `oldId` to
    /// `newId` if pinned, and rewrites every inbound wikilink across
    /// sibling pages so links stay live. Refuses to overwrite an
    /// existing target — the caller picks a unique name.
    @discardableResult
    public func movePage(
        workspaceId: Int64,
        from oldId: String,
        to newId: String
    ) throws -> WikiPage {
        let trimmedOld = oldId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = newId.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validatePath(trimmedOld)
        try Self.validatePath(trimmedNew)
        // Same-target move is a no-op — return the existing page so
        // callers can treat the API uniformly.
        if trimmedOld.lowercased() == trimmedNew.lowercased() {
            guard let page = try loadPage(workspaceId: workspaceId, id: trimmedOld) else {
                throw WikiError.invalidPageId(trimmedOld)
            }
            return page
        }
        let dir = wikiDirectory(for: workspaceId)
        let src = dir.appendingPathComponent(trimmedOld + ".md")
        let dst = dir.appendingPathComponent(trimmedNew + ".md")
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            throw WikiError.invalidPageId(trimmedOld)
        }
        if fm.fileExists(atPath: dst.path) {
            // Collisions need explicit handling at the UI layer (the
            // user has to pick a different name); throwing here keeps
            // the move atomic from the caller's perspective.
            throw WikiError.invalidPageId(trimmedNew)
        }
        try fm.createDirectory(
            at: dst.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.moveItem(at: src, to: dst)

        // Carry pin if pinned. Rewrite happens before we resolve the
        // returned WikiPage so the on-disk content matches what the
        // sidebar will show.
        var pins = (try? loadPins(workspaceId: workspaceId)) ?? []
        if pins.remove(trimmedOld) != nil {
            pins.insert(trimmedNew)
            try savePins(workspaceId: workspaceId, pins: pins)
        }
        _ = try rewriteWikilinks(
            workspaceId: workspaceId,
            from: trimmedOld,
            to: trimmedNew
        )
        let content = (try? String(contentsOf: dst, encoding: .utf8)) ?? ""
        return WikiPage(id: trimmedNew, url: dst, content: content)
    }

    /// Move a folder (and every page beneath it) to a new path.
    /// Used by sidebar drag-to-nest a folder under another folder.
    /// Refuses to:
    ///   - overwrite an existing target,
    ///   - move a folder into itself or a descendant (would produce
    ///     a cycle on disk),
    ///   - leave the workspace root via `..` traversal (caught by
    ///     `validatePath`).
    /// Per-page operations: pin entries keyed by the old id are
    /// re-keyed to the new id; inbound wikilinks across every other
    /// page in the workspace are rewritten in one pass at the end.
    /// Returns the count of pages relocated.
    @discardableResult
    public func moveFolder(
        workspaceId: Int64,
        from oldPath: String,
        to newPath: String
    ) throws -> Int {
        let trimmedOld = oldPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNew = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validatePath(trimmedOld)
        try Self.validatePath(trimmedNew)
        if trimmedOld.lowercased() == trimmedNew.lowercased() { return 0 }
        // Cycle guard: refuse moves where the destination is the
        // source itself or a descendant of it. Lowercased prefix
        // match is correct because both paths are canonicalised by
        // `validatePath` and use `/` as the separator.
        let oldKey = trimmedOld.lowercased() + "/"
        if (trimmedNew.lowercased() + "/").hasPrefix(oldKey) {
            throw WikiError.invalidPageId(trimmedNew)
        }

        let dir = wikiDirectory(for: workspaceId)
        let src = dir.appendingPathComponent(trimmedOld, isDirectory: true)
        let dst = dir.appendingPathComponent(trimmedNew, isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return 0 }
        if fm.fileExists(atPath: dst.path) {
            throw WikiError.invalidPageId(trimmedNew)
        }

        // Snapshot the pages under the source before moving so we
        // know which old ids → new ids to remap on pins / wikilinks.
        let srcPrefix = trimmedOld + "/"
        let pagesUnderSrc = try listPages(workspaceId: workspaceId)
            .filter { $0.id.hasPrefix(srcPrefix) }

        try fm.createDirectory(
            at: dst.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.moveItem(at: src, to: dst)

        // Build (oldId, newId) pairs and apply pin + wikilink updates.
        // Per-page rewriteWikilinks is O(N pages) per page-moved, so a
        // 100-page folder rename touches O(N²) page reads. That's
        // acceptable at the personal-notes scale; if it ever bites we
        // can batch all rewrites into a single pass over each page
        // body (apply N replaces in one read/write).
        var pins = (try? loadPins(workspaceId: workspaceId)) ?? []
        let pinsBefore = pins
        var pinsChanged = false
        for page in pagesUnderSrc {
            let suffix = String(page.id.dropFirst(srcPrefix.count))
            let newId = trimmedNew + "/" + suffix
            if pinsBefore.contains(page.id) {
                pins.remove(page.id)
                pins.insert(newId)
                pinsChanged = true
            }
            _ = try rewriteWikilinks(
                workspaceId: workspaceId,
                from: page.id,
                to: newId
            )
        }
        if pinsChanged {
            try savePins(workspaceId: workspaceId, pins: pins)
        }
        return pagesUnderSrc.count
    }

    /// Create an empty folder under the wiki root. Idempotent: a
    /// re-create on an existing folder is a no-op.
    public func createFolder(workspaceId: Int64, path: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validatePath(trimmed)
        let url = wikiDirectory(for: workspaceId)
            .appendingPathComponent(trimmed, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Delete a folder and every page beneath it. Pin entries for
    /// pages under the deleted folder are scrubbed in the same pass
    /// so a re-create of the folder doesn't resurrect stale pins.
    public func deleteFolder(workspaceId: Int64, path: String) throws {
        try Self.validatePath(path)
        let dir = wikiDirectory(for: workspaceId)
        let url = dir.appendingPathComponent(path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Scrub pins for any descendant pages first so the pins file
        // is consistent if the rmtree partially fails.
        let prefix = path.hasSuffix("/") ? path : path + "/"
        var pins = (try? loadPins(workspaceId: workspaceId)) ?? []
        let toRemove = pins.filter { $0.hasPrefix(prefix) }
        if !toRemove.isEmpty {
            for id in toRemove { pins.remove(id) }
            try savePins(workspaceId: workspaceId, pins: pins)
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Reject path components that would let a caller escape the
    /// wiki root (`..`), produce absolute paths (`/foo`), or end up
    /// with empty segments (`folder//page`). Visible to tests.
    static func validatePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              path != ".", path != ".." else {
            throw WikiError.invalidPageId(path)
        }
        let comps = path.split(separator: "/", omittingEmptySubsequences: false)
        for c in comps {
            let s = String(c)
            if s.isEmpty || s == "." || s == ".." || s.hasPrefix(".") {
                throw WikiError.invalidPageId(path)
            }
        }
    }

    /// Read one page. Returns nil if the file doesn't exist; throws
    /// only on read errors (permissions, decoding).
    public func loadPage(workspaceId: Int64, id: String) throws -> WikiPage? {
        let url = wikiDirectory(for: workspaceId)
            .appendingPathComponent("\(id).md")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let content = try String(contentsOf: url, encoding: .utf8)
        return WikiPage(id: id, url: url, content: content)
    }

    /// Create or overwrite a page. The id is the relative path stem
    /// (e.g. `Notes/Daily/2026-05-07`); intermediate folders are
    /// created on demand so a save into a not-yet-existing folder
    /// doesn't require a separate `createFolder` call. Empty,
    /// absolute, or `..`-containing ids are rejected.
    @discardableResult
    public func savePage(workspaceId: Int64, id: String, content: String) throws -> WikiPage {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validatePath(trimmed)
        let dir = wikiDirectory(for: workspaceId)
        let url = dir.appendingPathComponent("\(trimmed).md")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.data(using: .utf8)?.write(to: url, options: .atomic)
        return WikiPage(id: trimmed, url: url, content: content)
    }

    /// Delete a page and remove it from the pin set if pinned. Idempotent:
    /// no-op when the file doesn't exist.
    public func deletePage(workspaceId: Int64, id: String) throws {
        let url = wikiDirectory(for: workspaceId)
            .appendingPathComponent("\(id).md")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        var pins = (try? loadPins(workspaceId: workspaceId)) ?? []
        if pins.remove(id) != nil {
            try savePins(workspaceId: workspaceId, pins: pins)
        }
    }

    /// Rewrite every wikilink to `oldId` across every other page in
    /// the workspace so renaming a page doesn't orphan inbound links.
    /// Returns the count of pages whose body changed (for logging /
    /// toast confirmation).
    ///
    /// Match semantics mirror `WikiLinkResolver`: case-insensitive on
    /// the target, alias and section-fragment preserved (`[[Old|x]]`
    /// becomes `[[New|x]]`, `[[Old#h]]` becomes `[[New#h]]`). The page
    /// being renamed is excluded from the scan; the caller handles
    /// its own filename move via `savePage(newId)` + `deletePage(oldId)`.
    @discardableResult
    public func rewriteWikilinks(
        workspaceId: Int64,
        from oldId: String,
        to newId: String
    ) throws -> Int {
        let oldKey = oldId.lowercased()
        var changed = 0
        for page in try listPages(workspaceId: workspaceId) {
            if page.id.lowercased() == oldKey { continue }
            let rewritten = Self.rewriteBody(page.content, from: oldId, to: newId)
            if rewritten != page.content {
                _ = try savePage(workspaceId: workspaceId, id: page.id, content: rewritten)
                changed += 1
            }
        }
        return changed
    }

    /// Pure body-rewrite — exposed for tests so the link-replacement
    /// logic can be exercised without filesystem I/O. Same fenced-
    /// code-aware caveat as `WikiLinkResolver.extractLinks`: links
    /// inside fenced code blocks *will* be rewritten, which is benign
    /// for the typical case (renames of named pages don't show up
    /// inside code samples).
    public static func rewriteBody(_ body: String, from oldId: String, to newId: String) -> String {
        let oldKey = oldId.lowercased()
        var result = ""
        result.reserveCapacity(body.count)
        var i = body.startIndex
        while i < body.endIndex {
            if body[i] == "[",
               body.index(after: i) < body.endIndex,
               body[body.index(after: i)] == "[" {
                let openEnd = body.index(i, offsetBy: 2)
                if let closeStart = body.range(of: "]]", range: openEnd..<body.endIndex)?.lowerBound {
                    let inner = String(body[openEnd..<closeStart])
                    var target = inner
                    var trailing = ""
                    if let pipe = target.firstIndex(of: "|") {
                        trailing = String(target[pipe...])
                        target = String(target[target.startIndex..<pipe])
                    }
                    var fragment = ""
                    if let hash = target.firstIndex(of: "#") {
                        fragment = String(target[hash...])
                        target = String(target[target.startIndex..<hash])
                    }
                    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.lowercased() == oldKey {
                        result += "[[" + newId + fragment + trailing + "]]"
                    } else {
                        result += "[[" + inner + "]]"
                    }
                    i = body.index(closeStart, offsetBy: 2)
                    continue
                }
            }
            result.append(body[i])
            i = body.index(after: i)
        }
        return result
    }

    // MARK: - Pins

    /// Pin set for a workspace — page ids the user has marked as
    /// always-inject roots. Returns empty set if no pins file exists.
    public func loadPins(workspaceId: Int64) throws -> Set<String> {
        let url = pinsURL(for: workspaceId)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let list = try JSONDecoder().decode([String].self, from: data)
        return Set(list)
    }

    public func savePins(workspaceId: Int64, pins: Set<String>) throws {
        let dir = wikiDirectory(for: workspaceId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = pinsURL(for: workspaceId)
        let data = try JSONEncoder().encode(Array(pins).sorted())
        try data.write(to: url, options: .atomic)
    }

    public func setPin(workspaceId: Int64, id: String, pinned: Bool) throws {
        var pins = (try? loadPins(workspaceId: workspaceId)) ?? []
        if pinned { pins.insert(id) } else { pins.remove(id) }
        try savePins(workspaceId: workspaceId, pins: pins)
    }

    // MARK: - Context build

    /// Build the always-inject context for one chat turn.
    ///
    /// Phase 5 split: pins now mean "always inject *this exact page*"
    /// — no transitive `[[wikilink]]` closure is performed here. The
    /// rest of the wiki (and the workspace's `data_folder`, when set)
    /// is reachable through RAG retrieval, which composes alongside
    /// this channel at `Generation.swift:127`. This makes the inject
    /// cost predictable: it scales linearly with the pin count, never
    /// silently truncates wikilinks the user didn't directly pin, and
    /// pairs cleanly with the vector index for everything else.
    ///
    /// `budgetTokens` is informational here (used to drive the
    /// sidebar readout) — pages are not dropped to fit. The hard cap
    /// is enforced on the pin set itself, not at injection time
    /// (see `WikiStore.maxPinCount`).
    public func buildContext(
        workspaceId: Int64,
        budgetTokens: Int = 8000
    ) throws -> WikiContext {
        let pins = try loadPins(workspaceId: workspaceId)
        guard !pins.isEmpty else { return .empty }

        // Load only the pinned pages — no full corpus listing.
        var pinnedPages: [WikiPage] = []
        for id in pins.sorted(by: {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }) {
            if let page = try? loadPage(workspaceId: workspaceId, id: id) {
                pinnedPages.append(page)
            }
            // Missing pinned pages (deleted out from under the pin
            // set, or moved without the pin index being updated)
            // are silently skipped — the next pin-set sync will
            // notice them.
        }

        let total = pinnedPages.reduce(0) { $0 + WikiContext.estimateTokens(for: $1) }
        return WikiContext(
            text: WikiContext.format(pinnedPages),
            pageIds: pinnedPages.map { $0.id },
            droppedPageIds: [],
            approximateTokens: total
        )
    }

    /// Hard cap on the pin set size. Inject cost grows linearly with
    /// pinned pages; this cap prevents users from accidentally
    /// pinning hundreds and silently bloating every chat turn. The
    /// number is conservative — pinned pages are meant for
    /// "must-have-in-every-prompt" docs (project briefs, persona,
    /// glossary), not bulk reference. Bulk goes through RAG.
    public static let maxPinCount = 20
}

extension WikiContext {
    /// Cheap token estimate — chars / 4 is the GPT rule-of-thumb that
    /// holds within ~10% for English markdown. Real token counts run
    /// inside the runner; this is just for the budget cap.
    public static func estimateTokens(for page: WikiPage) -> Int {
        // Add a small overhead for the wrapping header so the budget
        // accounts for it.
        let headerOverhead = 8
        return page.content.count / 4 + headerOverhead
    }

    /// Concatenate pages with markdown headers so the model sees a
    /// clean, attributable block. The wrapping `<wiki_context>` tags
    /// give the model a hint that this is curated authored context
    /// (vs. retrieved RAG chunks, which use a different framing).
    static func format(_ pages: [WikiPage]) -> String {
        guard !pages.isEmpty else { return "" }
        var body = "<wiki_context>\nThe following pages are curated context the user has pinned for this workspace. Treat them as authoritative.\n\n"
        for page in pages {
            body += "## \(page.id)\n\n"
            body += page.content.trimmingCharacters(in: .whitespacesAndNewlines)
            body += "\n\n"
        }
        body += "</wiki_context>\n"
        return body
    }
}

public enum WikiError: Error, CustomStringConvertible {
    case invalidPageId(String)

    public var description: String {
        switch self {
        case .invalidPageId(let id):
            return "invalid wiki page id: '\(id)' (no slashes, dots-only, or empty)"
        }
    }
}
