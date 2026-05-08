import SwiftUI
import AppKit
import InferCore

/// Renders chat messages with `[[Page]]` mentions styled as clickable
/// links. Each mention navigates to the linked page in the wiki tab
/// area, closing the loop on the chat-message wiki injection
/// feature: when a user types `[[Brief]]` the page content injects
/// for that turn (handled in `Generation.swift`), and the rendered
/// transcript turns the same token into a navigable link so past
/// mentions stay reachable from the chat history.
///
/// Two paths:
///
/// - User / system messages render plain text via an `AttributedString`
///   built incrementally — `[[span]]` ranges get a `wiki://` link
///   plus accent-colored styling, everything else stays as plain
///   text. Newlines and whitespace are preserved verbatim.
///
/// - Assistant messages still render through `swift-markdown-ui`
///   (so headings / code blocks / etc. keep their formatting). We
///   pre-process the markdown source to rewrite `[[...]]` tokens
///   into standard `[label](wiki://target)` markdown links; the
///   markdown renderer then handles them natively.
///
/// Both paths route clicks through the same `OpenURLAction` handler
/// — `wiki://...` URLs resolve case-insensitively (with basename
/// fallback) and call `vm.openWikiPage`. Other schemes fall through
/// to `NSWorkspace.shared.open` so external links keep working.
enum MessageWikilinkRenderer {
    /// URL scheme reserved for chat-transcript wikilink clicks.
    private static let scheme = "wiki"

    // MARK: - Plain-text path

    /// Build an `AttributedString` for a user/system message,
    /// styling every `[[mention]]` span as an accent-colored link.
    static func attributedUserMessage(_ text: String) -> AttributedString {
        var out = AttributedString()
        let ns = text as NSString
        var cursor = 0
        while cursor < ns.length {
            let searchRange = NSRange(location: cursor, length: ns.length - cursor)
            let openRange = ns.range(of: "[[", range: searchRange)
            guard openRange.location != NSNotFound else {
                out.append(AttributedString(ns.substring(with: searchRange)))
                break
            }
            if openRange.location > cursor {
                let pre = ns.substring(with: NSRange(
                    location: cursor, length: openRange.location - cursor
                ))
                out.append(AttributedString(pre))
            }
            let innerStart = openRange.upperBound
            let afterRange = NSRange(
                location: innerStart, length: ns.length - innerStart
            )
            let closeRange = ns.range(of: "]]", range: afterRange)
            guard closeRange.location != NSNotFound else {
                // Unclosed `[[` — render the rest as plain text and stop.
                out.append(AttributedString(ns.substring(from: openRange.location)))
                break
            }
            let span = ns.substring(with: NSRange(
                location: openRange.location,
                length: closeRange.upperBound - openRange.location
            ))
            let inner = ns.substring(with: NSRange(
                location: innerStart, length: closeRange.location - innerStart
            ))
            if let url = wikiURL(forInner: inner) {
                var linked = AttributedString(span)
                linked.link = url
                linked.foregroundColor = .accentColor
                out.append(linked)
            } else {
                out.append(AttributedString(span))
            }
            cursor = closeRange.upperBound
        }
        return out
    }

    // MARK: - Markdown path

    /// Rewrite `[[Page]]`, `[[Page|alias]]`, `[[Page#section]]`
    /// tokens in markdown source into `[label](wiki://Page)` links
    /// so the markdown renderer can handle them natively. Code
    /// fences and inline code are skipped so `[[foo]]` inside a
    /// fenced sample stays verbatim — typing `[[bar]]` inside a
    /// triple-backtick block is the only way to demonstrate wiki
    /// syntax in the assistant's reply, and we'd rather it stay
    /// readable than become a stray link.
    static func markdownifyWikilinks(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var i = text.startIndex
        var inFence = false
        var inInline = false
        while i < text.endIndex {
            let c = text[i]
            // Fenced code: track ``` toggles. Inline code: track `
            // toggles (only when not in a fence).
            if c == "`" {
                let next = text.index(after: i)
                let nextNext = next < text.endIndex ? text.index(after: next) : text.endIndex
                if next < text.endIndex, nextNext < text.endIndex,
                   text[next] == "`", text[nextNext] == "`" {
                    inFence.toggle()
                    out.append("```")
                    i = text.index(after: nextNext)
                    continue
                }
                if !inFence {
                    inInline.toggle()
                }
                out.append(c)
                i = text.index(after: i)
                continue
            }
            if inFence || inInline {
                out.append(c)
                i = text.index(after: i)
                continue
            }
            // Detect `[[`. Must NOT be preceded by `!` for an embed
            // — for now embeds (`![[Page]]`) get the same treatment
            // as a plain link (the markdown renderer doesn't render
            // them as embeds either).
            if c == "[",
               text.index(after: i) < text.endIndex,
               text[text.index(after: i)] == "[" {
                let openEnd = text.index(i, offsetBy: 2)
                if let closeStart = text.range(
                    of: "]]", range: openEnd..<text.endIndex
                )?.lowerBound {
                    let inner = String(text[openEnd..<closeStart])
                    if let url = wikiURL(forInner: inner) {
                        let label = labelForInner(inner)
                        out += "[\(label)](\(url.absoluteString))"
                    } else {
                        // Unparseable target — leave the original
                        // bracket span verbatim.
                        out += String(text[i..<text.index(closeStart, offsetBy: 2)])
                    }
                    i = text.index(closeStart, offsetBy: 2)
                    continue
                }
            }
            out.append(c)
            i = text.index(after: i)
        }
        return out
    }

    // MARK: - Click handling

    /// Routes an `OpenURLAction` URL: `wiki://...` schemes resolve
    /// to a page and open it as a tab; everything else falls through
    /// to the system handler. `@MainActor` because resolution
    /// touches `ChatViewModel`'s main-actor state.
    @MainActor
    static func handle(url: URL, vm: ChatViewModel) -> OpenURLAction.Result {
        guard url.scheme == scheme else {
            NSWorkspace.shared.open(url)
            return .handled
        }
        // Recover the raw target from the URL. The host carries the
        // first path component when the target is "Page"; for
        // "Folder/Page" the host is "Folder" and the path is
        // "/Page". Reconstruct the original `Folder/Page` form.
        var raw = url.host ?? ""
        if !url.path.isEmpty {
            raw += url.path
        }
        let decoded = raw.removingPercentEncoding ?? raw
        let target = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !target.isEmpty else { return .handled }

        let pages = vm.wikiPages
        let fullIndex = Dictionary(
            uniqueKeysWithValues: pages.map { ($0.id.lowercased(), $0) }
        )
        var basenameIndex: [String: String] = [:]
        for fullKey in fullIndex.keys.sorted() {
            let base = (fullKey as NSString).lastPathComponent
            if basenameIndex[base] == nil { basenameIndex[base] = fullKey }
        }
        if let key = WikiLinkResolver.resolveKey(
            target, fullIndex: fullIndex, basenameIndex: basenameIndex
        ),
           let page = fullIndex[key] {
            vm.openWikiPage(page.id)
        } else {
            vm.toasts.show("No page named “\(target)” in this workspace.")
        }
        return .handled
    }

    // MARK: - Helpers

    /// Parse a `[[...]]` inner string into a `wiki://target` URL,
    /// stripping alias (after `|`) and section fragment (after `#`).
    /// Returns nil for empty / whitespace-only targets.
    private static func wikiURL(forInner inner: String) -> URL? {
        var target = inner
        if let pipe = target.firstIndex(of: "|") {
            target = String(target[target.startIndex..<pipe])
        }
        if let hash = target.firstIndex(of: "#") {
            target = String(target[target.startIndex..<hash])
        }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Encode the path. Slashes inside the target stay literal so
        // `Folder/Page` round-trips through URL.host + URL.path.
        let allowed = CharacterSet.urlPathAllowed
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "\(scheme)://\(encoded)")
    }

    /// Display label for a markdown link rewrite — alias if present,
    /// else the target with the section fragment preserved (so
    /// `[[Page#h]]` renders as `Page#h` in the visible link text).
    private static func labelForInner(_ inner: String) -> String {
        if let pipe = inner.firstIndex(of: "|") {
            return String(inner[inner.index(after: pipe)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
