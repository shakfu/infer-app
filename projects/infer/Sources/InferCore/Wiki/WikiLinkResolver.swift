import Foundation

/// Pure-function wikilink parser + transitive-closure resolver. Lives
/// outside `WikiStore` so the parsing logic can be tested without
/// touching the filesystem.
///
/// Syntax handled:
///   `[[Page Name]]`         — simple link, target = "Page Name"
///   `[[Page Name|alias]]`   — aliased link, target = "Page Name"
///                              (the alias is for the human reading the
///                              rendered output; the resolver only needs
///                              the target)
///   `[[Page Name#section]]` — section anchor; resolver strips the
///                              fragment and treats it as a page link
///
/// Out of scope:
///   - Markdown links (`[text](url)`) — those are normal links, not
///     wiki references.
///   - Embeds (`![[Page]]`) — same target resolution as `[[Page]]`,
///     but render differently in the editor; treated identically here.
///   - Folder paths in wikilinks (`[[folder/Page]]`) — the v1 wiki is
///     flat, so we just match by stem; nested wikis are a Phase 2+
///     concern.
public enum WikiLinkResolver {
    /// Result of one transitive walk: the included pages (deduped) and
    /// any link targets that didn't resolve to an existing page.
    public struct Traversal: Equatable {
        public let included: [WikiPage]
        public let unresolved: [String]
    }

    /// Extract wikilink targets from a single page body. Returns the
    /// raw target strings (no aliases, no section fragments) in
    /// document order, deduplicated by case-folded form.
    ///
    /// Implemented as a state machine rather than a regex so a `[[`
    /// inside a fenced code block doesn't get matched. The escape
    /// hatches that matter most (fenced code, inline code) are
    /// honored; HTML comments and frontmatter are not, but those are
    /// rare in authored wikis and the failure mode (a stray link
    /// pulled from a comment) is benign.
    public static func extractLinks(from body: String) -> [String] {
        var targets: [String] = []
        var seen: Set<String> = []
        var i = body.startIndex
        var inFence = false   // ``` ... ```
        var inInlineCode = false  // ` ... `

        while i < body.endIndex {
            let c = body[i]

            // Fenced code block toggle: three backticks at line start
            // (or here — we don't insist on line-start because that
            // requires lookback; benign edge case).
            if c == "`" {
                let next = body.index(after: i)
                let nextNext = next < body.endIndex ? body.index(after: next) : body.endIndex
                if next < body.endIndex, nextNext < body.endIndex,
                   body[next] == "`", body[nextNext] == "`" {
                    inFence.toggle()
                    i = body.index(after: nextNext)
                    continue
                }
                if !inFence {
                    inInlineCode.toggle()
                }
                i = body.index(after: i)
                continue
            }

            if inFence || inInlineCode {
                i = body.index(after: i)
                continue
            }

            if c == "[",
               body.index(after: i) < body.endIndex,
               body[body.index(after: i)] == "[" {
                let openEnd = body.index(i, offsetBy: 2)
                if let closeStart = body.range(of: "]]", range: openEnd..<body.endIndex)?.lowerBound {
                    let inner = String(body[openEnd..<closeStart])
                    // Strip alias (after `|`) and section fragment
                    // (after `#`); take whichever delimiter comes
                    // first.
                    var target = inner
                    if let pipe = target.firstIndex(of: "|") {
                        target = String(target[target.startIndex..<pipe])
                    }
                    if let hash = target.firstIndex(of: "#") {
                        target = String(target[target.startIndex..<hash])
                    }
                    let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let key = trimmed.lowercased()
                        if !seen.contains(key) {
                            seen.insert(key)
                            targets.append(trimmed)
                        }
                    }
                    i = body.index(closeStart, offsetBy: 2)
                    continue
                }
            }

            i = body.index(after: i)
        }

        return targets
    }

    /// BFS from the given root page ids, following `[[wikilinks]]` in
    /// every visited page. Pages already in the visited set are
    /// skipped so cycles don't loop. Roots that don't resolve to
    /// existing pages are silently dropped (they show up in
    /// `unresolved` of the final traversal).
    ///
    /// `index` keys are lowercased *full* page ids (e.g.
    /// `notes/daily/2026-05-07`); values are the canonical `WikiPage`
    /// with original casing. Targets without a `/` fall back to
    /// basename match across the index — so `[[Page]]` finds a page
    /// at any folder depth as long as the basename matches; an
    /// explicit `[[folder/Page]]` is path-qualified.
    ///
    /// Basename collisions (two pages with the same basename in
    /// different folders) resolve to the alphabetically-first full
    /// id — predictable, even if not always what the author meant.
    /// Authors who care about disambiguation should use the
    /// path-qualified form.
    public static func transitiveClosure(
        roots: [String],
        index: [String: WikiPage]
    ) -> Traversal {
        // Pre-build basename → fullId map for fallback resolution.
        // Multiple pages can share a basename; pick alphabetically
        // first so the choice is deterministic.
        var basenameIndex: [String: String] = [:]
        for fullKey in index.keys.sorted() {
            let base = (fullKey as NSString).lastPathComponent
            if basenameIndex[base] == nil { basenameIndex[base] = fullKey }
        }

        var visited: Set<String> = []
        var unresolvedSet: Set<String> = []
        var unresolvedOrdered: [String] = []
        var ordered: [WikiPage] = []
        var queue: [String] = roots

        while !queue.isEmpty {
            let raw = queue.removeFirst()
            if let key = resolveKey(raw, fullIndex: index, basenameIndex: basenameIndex),
               let page = index[key] {
                if visited.contains(key) { continue }
                visited.insert(key)
                ordered.append(page)
                for link in extractLinks(from: page.content) {
                    queue.append(link)
                }
            } else {
                let normalised = raw.lowercased()
                if !unresolvedSet.contains(normalised) {
                    unresolvedSet.insert(normalised)
                    unresolvedOrdered.append(raw)
                }
            }
        }

        return Traversal(included: ordered, unresolved: unresolvedOrdered)
    }

    /// Resolve a link target case-insensitively to a key in
    /// `fullIndex`. Path-qualified targets (`folder/Page`) require
    /// an exact match; bare names (`Page`) try exact first, then
    /// fall back to basename lookup via `basenameIndex`.
    public static func resolveKey(
        _ raw: String,
        fullIndex: [String: WikiPage],
        basenameIndex: [String: String]
    ) -> String? {
        let lower = raw.lowercased()
        if fullIndex[lower] != nil { return lower }
        if raw.contains("/") { return nil }  // explicit path missed → don't fall back
        return basenameIndex[lower]
    }
}
