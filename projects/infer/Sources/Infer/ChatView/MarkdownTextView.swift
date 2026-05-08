import SwiftUI
import AppKit
import Combine
import Splash
import Highlightr
import STTextView
import STTextKitPlus

/// `NSTextView`-backed plain-text editor used by `WikiPageEditorSheet`
/// so we can: (a) detect when the cursor is inside an unclosed
/// `[[...` wikilink (SwiftUI's `TextEditor` exposes no cursor APIs);
/// (b) programmatically insert chosen suggestions at the cursor;
/// (c) report the on-screen rect of the cursor for popover anchoring.
///
/// Conservative defaults: undo on, smart quotes / dashes / autocorrect
/// / autocompletion off (markdown shouldn't transform `--` into an em
/// dash silently); rich-text off (one font, plain string round-trips
/// through the bound `String` cleanly).
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    @ObservedObject var controller: MarkdownTextViewController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // STTextView's `scrollableTextView()` returns an NSScrollView
        // already wired up with a TextKit-2-backed STTextView. We
        // need a subclass for Cmd-click on wikilinks, so we build
        // the scroll view + WikiTextView manually but mirror what
        // `scrollableTextView()` does internally.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        let tv = WikiTextView()
        tv.textDelegate = context.coordinator
        tv.isEditable = true
        tv.isSelectable = true
        // STTextView defaults to `isHorizontallyResizable = true`,
        // which means long lines extend the view rather than wrap.
        // For a markdown wiki editor the user wants word wrap to
        // the content width — flip the flag.
        tv.isHorizontallyResizable = false
        // Body in proportional system font; the styling pass
        // re-applies monospaced font + dimmed background to code
        // spans + fenced code blocks so they contrast visually.
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.textColor = NSColor.textColor
        tv.text = text
        // STTextView exposes content insets through its scroll
        // view rather than the text container directly — mirror
        // the previous editor's 8pt feel by setting the scroll
        // view's content insets.
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        // Cmd-click anywhere inside a [[...]] span fires this — the
        // controller routes it to the SwiftUI side, which resolves
        // the target id and opens the page as a tab.
        tv.onWikilinkClick = { [weak controller] target in
            controller?.fireWikilinkClick(target)
        }
        controller.textView = tv

        scroll.documentView = tv
        // Initial styling sweep so existing pages render with the
        // wikilink + markdown-inline styling on first appearance.
        // The delegate's `textViewDidChangeText(_:)` only fires on
        // user edits; the initial `tv.text = ...` doesn't.
        context.coordinator.storageDelegate.applyStyling(to: tv)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? WikiTextView else { return }
        // External update from the binding — only force-reload when
        // the strings actually diverge so we don't blow away the
        // user's typing on every keystroke (textViewDidChangeText
        // fires the binding, which fires updateNSView, which would
        // otherwise reset the cursor).
        if tv.text != text {
            tv.text = text
            // Re-sweep styling after the assignment — STTextView's
            // delegate doesn't fire on programmatic `text =` writes.
            context.coordinator.storageDelegate.applyStyling(to: tv)
        }
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency STTextViewDelegate {
        var parent: MarkdownTextView
        /// Owned by the coordinator so its strong reference outlives
        /// the SwiftUI render cycle and the storage delegate's
        /// weak coupling to the underlying NSTextStorage.
        let storageDelegate = WikiTextStorageDelegate()
        init(_ parent: MarkdownTextView) { self.parent = parent }

        // MARK: STTextViewDelegate

        /// Fired after every user-initiated text mutation. Mirrors
        /// the old `NSTextViewDelegate.textDidChange(_:)`. Pushes
        /// the string up to the SwiftUI binding, recomputes the
        /// `[[` autocomplete trigger, and re-applies markdown +
        /// wikilink styling to the storage.
        func textViewDidChangeText(_ notification: Notification) {
            guard let tv = notification.object as? WikiTextView else { return }
            parent.text = tv.text ?? ""
            parent.controller.recomputeTrigger(in: tv)
            storageDelegate.applyStyling(to: tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? WikiTextView else { return }
            parent.controller.recomputeTrigger(in: tv)
        }

        /// Intercept Return / Tab / Escape / arrows while the
        /// autocomplete popover is active so the popover can
        /// capture them as accept / cancel / nav. Other commands
        /// fall through to STTextView's defaults.
        func textView(_ textView: STTextView, doCommandBy selector: Selector) -> Bool {
            guard parent.controller.trigger != nil else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):
                if parent.controller.acceptHighlightedSuggestion() { return true }
                return false
            case #selector(NSResponder.cancelOperation(_:)):
                parent.controller.dismissTrigger()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.controller.moveSuggestionSelection(by: +1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                parent.controller.moveSuggestionSelection(by: -1)
                return true
            default:
                return false
            }
        }
    }
}

/// `NSTextStorageDelegate` that applies markdown inline styling to
/// the editor's text storage on every edit. Headings render larger
/// and bolder, fenced + inline code in monospaced + dimmed
/// background, `**bold**` bold, `*italic*` italic, `[[wikilinks]]`
/// and `[md links](url)` accent-colored + underlined.
///
/// Single-pass approach: walk the document line-by-line, tracking
/// fenced-code state across lines; per non-fenced line apply inline
/// styling for headings + emphasis + code spans + links. Full sweep
/// on every character edit (O(N) over storage) — fine at personal-
/// notes scale; promote to incremental edit-range scanning later if
/// it bites on long documents.
///
/// Attribute mutations inside `didProcessEditing` are safe because
/// they don't change characters — only `replaceCharacters` would
/// re-entrantly fire the delegate.
final class WikiTextStorageDelegate: NSObject, NSTextStorageDelegate {
    private let baseFont: NSFont
    private let baseSize: CGFloat
    private let baseColor: NSColor
    private let linkColor: NSColor
    private let codeBackgroundColor: NSColor
    private let mutedColor: NSColor

    init(
        size: CGFloat = 13,
        textColor: NSColor = .textColor,
        linkColor: NSColor = .controlAccentColor
    ) {
        self.baseSize = size
        self.baseFont = NSFont.systemFont(ofSize: size)
        self.baseColor = textColor
        self.linkColor = linkColor
        self.codeBackgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.10)
        self.mutedColor = NSColor.secondaryLabelColor
    }

    private var monospacedFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
    }

    /// Heading sizes scale down as level increases, mirroring how
    /// `swift-markdown-ui`'s GitHub theme renders the chat
    /// transcript so wiki + chat surfaces feel consistent.
    private func headingFont(level: Int) -> NSFont {
        let size: CGFloat
        switch level {
        case 1: size = baseSize + 9
        case 2: size = baseSize + 6
        case 3: size = baseSize + 4
        case 4: size = baseSize + 2
        case 5: size = baseSize + 1
        default: size = baseSize
        }
        return NSFont.boldSystemFont(ofSize: size)
    }

    private func emphasisFont(bold: Bool, italic: Bool, monospaced: Bool = false) -> NSFont {
        if monospaced { return monospacedFont }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: baseSize) ?? baseFont
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        applyStyling(to: textStorage)
    }

    /// Apply the full styling pass to a WikiTextView. Reaches the
    /// underlying `NSTextStorage` via TextKit 2's content manager;
    /// `STTextView` keeps the storage as the canonical attribute
    /// store (TextKit 2 layouts on top of it), so attribute writes
    /// are reflected in rendering immediately.
    func applyStyling(to tv: WikiTextView) {
        guard let contentStorage = tv.textLayoutManager.textContentManager
                as? NSTextContentStorage,
              let textStorage = contentStorage.textStorage else { return }
        applyStyling(to: textStorage)
    }

    /// Hand-rolled markdown styling. Walks the text line-by-line,
    /// tracks fenced-code state, applies heading sizes / bold /
    /// italic / inline + fenced code styling, and finally layers
    /// wikilink accent + underline. `swift`-tagged code blocks get
    /// per-token coloring via Splash; other languages stay plain
    /// monospaced + dimmed background.
    private func applyStyling(to textStorage: NSTextStorage) {
        let str = textStorage.string as NSString
        let full = NSRange(location: 0, length: str.length)

        textStorage.setAttributes([
            .font: baseFont,
            .foregroundColor: baseColor,
        ], range: full)

        var lineLocation = 0
        var inFence = false
        var currentFenceLang: String?
        var currentFenceContentStart: Int = 0
        var pendingHighlights: [(language: String, range: NSRange)] = []
        while lineLocation < str.length {
            var lineEndContent: Int = 0
            var lineEndIncludingTerminator: Int = 0
            str.getLineStart(
                nil,
                end: &lineEndIncludingTerminator,
                contentsEnd: &lineEndContent,
                for: NSRange(location: lineLocation, length: 0)
            )
            let lineRange = NSRange(
                location: lineLocation,
                length: lineEndContent - lineLocation
            )
            let lineText = str.substring(with: lineRange)

            let trimmed = lineText.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    // Fence close — capture the content range we've
                    // accumulated for syntax highlighting if it's a
                    // language we know.
                    if let lang = currentFenceLang {
                        let contentLen = lineRange.location - currentFenceContentStart
                        if contentLen > 0 {
                            pendingHighlights.append((
                                language: lang,
                                range: NSRange(
                                    location: currentFenceContentStart,
                                    length: contentLen
                                )
                            ))
                        }
                    }
                    inFence = false
                    currentFenceLang = nil
                } else {
                    // Fence open — extract the language tag (text
                    // immediately after the ``` markers, before any
                    // newline). The content begins on the next line.
                    let afterBackticks = String(trimmed.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    currentFenceLang = afterBackticks.isEmpty ? nil : afterBackticks
                    currentFenceContentStart = lineEndIncludingTerminator
                    inFence = true
                }
                applyCodeBlock(line: lineRange, in: textStorage)
                lineLocation = lineEndIncludingTerminator
                continue
            }
            if inFence {
                applyCodeBlock(line: lineRange, in: textStorage)
                lineLocation = lineEndIncludingTerminator
                continue
            }

            // Heading? Match `^#{1,6}\s+...$`. The leading hashes
            // get muted color so the heading text reads as the
            // primary content; the heading font applies to the
            // whole line so layout reflows correctly.
            if let parsed = parseHeading(lineText) {
                let level = parsed.level
                let lineLen = lineRange.length
                textStorage.addAttributes([
                    .font: headingFont(level: level),
                ], range: lineRange)
                let hashesRange = NSRange(
                    location: lineRange.location,
                    length: min(parsed.markerLength, lineLen)
                )
                textStorage.addAttributes([
                    .foregroundColor: mutedColor,
                ], range: hashesRange)
                // Inline patterns (bold/italic/code/links) inside
                // headings are styled too — but only if they don't
                // collide with the heading font (the emphasis path
                // overrides `.font` so bold-inside-heading still
                // shows; size from the heading font is preserved
                // because we re-derive size from the bold trait).
                applyInlineSpans(in: lineRange, lineText: lineText, on: textStorage,
                                 baseFontOverride: headingFont(level: level))
                lineLocation = lineEndIncludingTerminator
                continue
            }

            // Regular line — apply inline emphasis / code spans /
            // wikilinks / markdown links.
            applyInlineSpans(in: lineRange, lineText: lineText, on: textStorage,
                             baseFontOverride: nil)
            lineLocation = lineEndIncludingTerminator
        }

        // Splash for Swift (richer Swift-specific tokenization);
        // Highlightr (highlight.js via JavaScriptCore) for everything
        // else. Both passes only add `.foregroundColor`; the
        // monospaced font + dimmed background written by
        // `applyCodeBlock` during the walk above remain.
        for hl in pendingHighlights {
            if hl.language == "swift" {
                applySplashHighlights(in: hl.range, on: textStorage)
            } else {
                applyHighlightrHighlights(
                    in: hl.range, language: hl.language, on: textStorage
                )
            }
        }
    }

    /// Cached `Highlightr` instance — boots a JSContext + loads
    /// highlight.js, so we don't want to rebuild it on every styling
    /// pass. Lazy so unit tests that never hit a fenced code block
    /// don't pay the cost.
    nonisolated(unsafe) private static let sharedHighlightr: Highlightr? = {
        let hl = Highlightr()
        hl?.setTheme(to: "xcode")
        return hl
    }()

    /// Run Highlightr (highlight.js) over `range` and copy each run's
    /// foreground color onto `storage`. Unknown languages produce no
    /// output from highlight.js, in which case we leave the plain
    /// monospaced styling in place. Font is intentionally untouched
    /// — `applyCodeBlock` already wrote the monospaced font and the
    /// code-block background.
    private func applyHighlightrHighlights(
        in range: NSRange, language: String, on storage: NSTextStorage
    ) {
        guard range.length > 0,
              range.location + range.length <= storage.length,
              let highlighter = Self.sharedHighlightr else { return }
        let source = (storage.string as NSString).substring(with: range)
        guard let attributed = highlighter.highlight(
            source, as: language, fastRender: true
        ) else { return }
        let attrFull = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.foregroundColor, in: attrFull, options: []) { value, sub, _ in
            guard let color = value as? NSColor else { return }
            let abs = NSRange(
                location: range.location + sub.location,
                length: sub.length
            )
            guard abs.location + abs.length <= storage.length else { return }
            storage.addAttributes([.foregroundColor: color], range: abs)
        }
    }

    /// Run Splash over the swift source in `range` and apply its
    /// per-token color attributes onto `storage`. The monospaced
    /// font + background that `applyCodeBlock` already wrote stay;
    /// Splash only adds foreground colors.
    private func applySplashHighlights(in range: NSRange, on storage: NSTextStorage) {
        guard range.length > 0,
              range.location + range.length <= storage.length else { return }
        let source = (storage.string as NSString).substring(with: range)
        let highlighter = SyntaxHighlighter(
            format: AttributedStringOutputFormat(
                theme: .sundellsColors(withFont: .init(size: 13))
            )
        )
        let attributed = highlighter.highlight(source)
        attributed.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, subrange, _ in
            guard let color = value as? NSColor else { return }
            let abs = NSRange(
                location: range.location + subrange.location,
                length: subrange.length
            )
            storage.addAttributes([.foregroundColor: color], range: abs)
        }
    }

    // MARK: - Heading

    private struct HeadingMatch {
        let level: Int
        let markerLength: Int  // # count + the following space
    }

    private func parseHeading(_ line: String) -> HeadingMatch? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level >= 1, idx < line.endIndex, line[idx] == " " else { return nil }
        // marker = `#`s + the single mandatory space
        return HeadingMatch(level: level, markerLength: level + 1)
    }

    // MARK: - Code block

    private func applyCodeBlock(line: NSRange, in storage: NSTextStorage) {
        storage.addAttributes([
            .font: monospacedFont,
            .foregroundColor: baseColor,
        ], range: line)
    }

    // MARK: - Inline spans

    /// Apply inline styling within a single line: inline code first
    /// (highest precedence — content inside `` ` `` is verbatim and
    /// shouldn't get further parsed), then markdown links + wiki
    /// links, then emphasis (bold + italic). Each pass searches
    /// only the line range, so cross-line patterns don't accumulate.
    private func applyInlineSpans(
        in lineRange: NSRange,
        lineText: String,
        on storage: NSTextStorage,
        baseFontOverride: NSFont?
    ) {
        let lineNS = lineText as NSString
        // Track regions already claimed by inline code so emphasis
        // / link passes skip them. Stored as half-open intervals in
        // line-local indices.
        var consumed: [NSRange] = []

        // Inline code: ` ... ` (single backticks; no escape
        // handling for now). Simplest scan.
        var i = 0
        while i < lineNS.length {
            let openRange = lineNS.range(
                of: "`",
                range: NSRange(location: i, length: lineNS.length - i)
            )
            guard openRange.location != NSNotFound else { break }
            let innerStart = openRange.upperBound
            let closeRange = lineNS.range(
                of: "`",
                range: NSRange(location: innerStart, length: lineNS.length - innerStart)
            )
            guard closeRange.location != NSNotFound else { break }
            let absRange = NSRange(
                location: lineRange.location + openRange.location,
                length: closeRange.upperBound - openRange.location
            )
            storage.addAttributes([
                .font: monospacedFont,
            ], range: absRange)
            consumed.append(NSRange(
                location: openRange.location,
                length: closeRange.upperBound - openRange.location
            ))
            i = closeRange.upperBound
        }

        // Markdown link: `[text](url)`.  Apply accent color +
        // underline to the entire span.
        applyRegex(
            "\\[[^\\]\\n]*\\]\\([^)\\n]+\\)",
            in: lineRange, lineNS: lineNS, consumed: &consumed,
            attributes: [
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ],
            on: storage
        )

        // Wikilinks `[[Page]]` (and aliased / fragmented variants).
        applyRegex(
            "\\[\\[[^\\]\\n]+\\]\\]",
            in: lineRange, lineNS: lineNS, consumed: &consumed,
            attributes: [
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ],
            on: storage
        )

        // Bold: `**text**`. Use the regex to find the span; apply
        // bold trait. Stars themselves stay normal (rendered as
        // muted markers would require a second attribute pass —
        // skipped for v1; keeps the markup readable when editing).
        applyEmphasisRegex(
            "\\*\\*[^*\\n]+\\*\\*",
            in: lineRange, lineNS: lineNS, consumed: &consumed,
            traits: (bold: true, italic: false),
            baseFontOverride: baseFontOverride,
            on: storage
        )

        // Italic: `*text*` (single asterisk) and `_text_`. Match
        // patterns that aren't immediately preceded/followed by
        // another `*` so we don't double-trigger on bold (regex
        // negative lookbehind via `(?<!\\*)` handles it).
        applyEmphasisRegex(
            "(?<!\\*)\\*(?!\\s)[^*\\n]+?(?<!\\s)\\*(?!\\*)",
            in: lineRange, lineNS: lineNS, consumed: &consumed,
            traits: (bold: false, italic: true),
            baseFontOverride: baseFontOverride,
            on: storage
        )
        applyEmphasisRegex(
            "(?<![\\w_])_[^_\\n]+_(?![\\w_])",
            in: lineRange, lineNS: lineNS, consumed: &consumed,
            traits: (bold: false, italic: true),
            baseFontOverride: baseFontOverride,
            on: storage
        )
    }

    /// Apply attributes to every regex match in the line that
    /// doesn't overlap a previously-consumed range. Records each
    /// match's local range in `consumed` so subsequent passes skip
    /// nested patterns.
    private func applyRegex(
        _ pattern: String,
        in lineRange: NSRange,
        lineNS: NSString,
        consumed: inout [NSRange],
        attributes: [NSAttributedString.Key: Any],
        on storage: NSTextStorage
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let lineLocal = NSRange(location: 0, length: lineNS.length)
        regex.enumerateMatches(in: lineNS as String, range: lineLocal) { match, _, _ in
            guard let m = match else { return }
            if Self.overlaps(m.range, consumed: consumed) { return }
            let abs = NSRange(
                location: lineRange.location + m.range.location,
                length: m.range.length
            )
            storage.addAttributes(attributes, range: abs)
            consumed.append(m.range)
        }
    }

    /// Like `applyRegex` but for bold/italic — derives the right
    /// font from `baseFontOverride` (or the storage's current font
    /// at that range, which after the headings pass is the heading
    /// font) so emphasis composes with headings rather than reverting
    /// to body size.
    private func applyEmphasisRegex(
        _ pattern: String,
        in lineRange: NSRange,
        lineNS: NSString,
        consumed: inout [NSRange],
        traits: (bold: Bool, italic: Bool),
        baseFontOverride: NSFont?,
        on storage: NSTextStorage
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let lineLocal = NSRange(location: 0, length: lineNS.length)
        regex.enumerateMatches(in: lineNS as String, range: lineLocal) { match, _, _ in
            guard let m = match else { return }
            if Self.overlaps(m.range, consumed: consumed) { return }
            let abs = NSRange(
                location: lineRange.location + m.range.location,
                length: m.range.length
            )
            // Derive the font from the existing attributes at this
            // position so we compose with the heading font (if any)
            // — heading + bold, heading + italic, etc.
            let existing = (storage.attribute(.font, at: abs.location, effectiveRange: nil) as? NSFont)
                ?? baseFontOverride ?? baseFont
            var symbolic = existing.fontDescriptor.symbolicTraits
            if traits.bold { symbolic.insert(.bold) }
            if traits.italic { symbolic.insert(.italic) }
            let descriptor = existing.fontDescriptor.withSymbolicTraits(symbolic)
            let combined = NSFont(descriptor: descriptor, size: existing.pointSize) ?? existing
            storage.addAttributes([.font: combined], range: abs)
            consumed.append(m.range)
        }
    }

    private static func overlaps(_ candidate: NSRange, consumed: [NSRange]) -> Bool {
        for c in consumed {
            if NSIntersectionRange(candidate, c).length > 0 { return true }
        }
        return false
    }
}

/// `STTextView` subclass that surfaces Cmd-click on `[[wikilinks]]`
/// as a callback. Plain clicks fall through to standard text-view
/// behaviour (cursor positioning, selection, IME) — only the Cmd
/// modifier triggers the link-follow path so editing inside a
/// wikilink isn't disrupted.
final class WikiTextView: STTextView {
    /// Invoked with the raw link target (alias and section fragment
    /// stripped) when the user Cmd-clicks inside a `[[...]]` span.
    /// Resolution from raw target → actual page id happens on the
    /// SwiftUI side via `WikiLinkResolver.resolveKey`.
    var onWikilinkClick: ((String) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.mouseDown(with: event)
            return
        }
        if let target = wikilinkTarget(at: event) {
            onWikilinkClick?(target)
            return
        }
        super.mouseDown(with: event)
    }

    /// Pretty cursor when Cmd is held over a wikilink — communicates
    /// "click here to follow." Without this the text I-beam stays,
    /// which works but isn't as discoverable.
    override func cursorUpdate(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           wikilinkTarget(at: event) != nil {
            NSCursor.pointingHand.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    /// Resolve a click event to the wikilink target whose `[[...]]`
    /// span contains the click. Uses STTextView's TextKit 2 layout
    /// manager to map the click point to a character offset in the
    /// underlying string, then scans for the surrounding `[[...]]`
    /// boundaries. Returns nil when the click is outside any span,
    /// the span is unclosed, or the inner text is empty.
    private func wikilinkTarget(at event: NSEvent) -> String? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        // STTextView gives us the text location directly under a
        // point via its layout manager. `interactingAt:` is the
        // hit-test variant that snaps to insertion-point boundaries
        // — exactly what we want for "what character did the user
        // click on".
        guard let textLocation = textLayoutManager.location(
            interactingAt: viewPoint,
            inContainerAt: textLayoutManager.documentRange.location
        ) else { return nil }
        let charIndex = textLayoutManager.offset(
            from: textLayoutManager.documentRange.location,
            to: textLocation
        )
        let nsStr = (text ?? "") as NSString
        guard charIndex >= 0, charIndex < nsStr.length else { return nil }

        // Look back from the click for the most recent `[[`.
        let beforeRange = NSRange(location: 0, length: charIndex)
        let openRange = nsStr.range(
            of: "[[", options: NSString.CompareOptions.backwards, range: beforeRange
        )
        let openLoc: Int
        if openRange.location != NSNotFound {
            openLoc = openRange.location
        } else if charIndex + 2 <= nsStr.length,
                  nsStr.substring(with: NSRange(location: charIndex, length: 2)) == "[[" {
            openLoc = charIndex
        } else {
            return nil
        }
        let innerStart = openLoc + 2
        guard innerStart < nsStr.length else { return nil }

        let afterRange = NSRange(
            location: innerStart, length: nsStr.length - innerStart
        )
        let closeRange = nsStr.range(of: "]]", options: [], range: afterRange)
        guard closeRange.location != NSNotFound else { return nil }
        guard charIndex >= innerStart, charIndex <= closeRange.location + 1 else {
            return nil
        }

        let inner = nsStr.substring(with: NSRange(
            location: innerStart, length: closeRange.location - innerStart
        ))
        var target = inner
        if let pipe = target.firstIndex(of: "|") {
            target = String(target[target.startIndex..<pipe])
        }
        if let hash = target.firstIndex(of: "#") {
            target = String(target[target.startIndex..<hash])
        }
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Bridge between the SwiftUI side (autocomplete popover, suggestion
/// list) and the underlying `NSTextView`. SwiftUI observes `trigger`
/// to render the popover; the `NSTextView` calls `recomputeTrigger`
/// after every text/selection change.
@MainActor
final class MarkdownTextViewController: ObservableObject {
    /// Active autocomplete trigger — `nil` when the cursor isn't in
    /// an unclosed `[[...` context.
    @Published var trigger: Trigger? = nil
    /// Index into the SwiftUI-supplied suggestion list that's
    /// currently highlighted. The popover view renders this; the
    /// editor uses it on Tab / Enter via `acceptHighlightedSuggestion`.
    @Published var highlightedIndex: Int = 0
    /// SwiftUI publishes its current suggestion list here so the
    /// coordinator can resolve the highlighted index back to a page
    /// id without circular bindings.
    @Published var suggestions: [String] = []

    weak var textView: WikiTextView?

    /// Combine-style passthrough for "user Cmd-clicked a wikilink in
    /// the editor." SwiftUI observers (the page view) react to each
    /// emission by resolving the target and opening it as a tab. A
    /// passthrough rather than a `@Published` value because we want
    /// repeated clicks on the same target to fire each time, not
    /// dedup against equality.
    let wikilinkClickSubject = PassthroughSubject<String, Never>()

    /// Optional hook that resolves a chosen page id into the actual
    /// text to insert (typically basename when unique, full path on
    /// basename collision — Obsidian-style). The SwiftUI side wires
    /// this with the workspace's full page list. Falls back to the
    /// id verbatim when nil so the controller stays usable in
    /// contexts where collision resolution isn't relevant.
    var resolveInsertText: ((String) -> String)?

    func fireWikilinkClick(_ target: String) {
        wikilinkClickSubject.send(target)
    }

    struct Trigger: Equatable {
        /// Text the user has typed after the most recent `[[`. Used
        /// as the fuzzy-match query.
        let query: String
        /// Character range (in the NSTextView's NSString) of `query`
        /// — i.e. *just* the query characters, not the leading `[[`.
        /// `replaceRange.location` sits one char after `[[`.
        let replaceRange: NSRange
        /// On-screen rect of the cursor at the time the trigger was
        /// detected (in window coordinates), used for popover anchor.
        let cursorRect: CGRect
    }

    /// Recompute the autocomplete trigger from the text view's
    /// current state. Called from the coordinator on text + selection
    /// changes. Cheap enough to run on every keystroke (one
    /// substring + one `range(of:options:)` over a 64-char window).
    func recomputeTrigger(in tv: WikiTextView) {
        let nsString = (tv.text ?? "") as NSString
        let cursor = Self.cursorOffset(in: tv)
        guard cursor <= nsString.length else {
            trigger = nil
            return
        }
        // Look back at most 128 characters for an unclosed `[[`.
        // Wikilinks longer than that are nonsensical; capping the
        // window keeps the search O(constant).
        let lookbackStart = max(0, cursor - 128)
        let window = nsString.substring(with: NSRange(location: lookbackStart, length: cursor - lookbackStart))
        guard let openIdx = window.range(of: "[[", options: String.CompareOptions.backwards)?.upperBound else {
            trigger = nil
            return
        }
        let query = String(window[openIdx...])
        // Reject obviously-not-a-trigger queries: closed brackets,
        // newline (page names don't span lines), tab, leading whitespace
        // (`[[ foo` doesn't autocomplete).
        if query.contains("]") || query.contains("\n") || query.contains("\t") {
            trigger = nil
            return
        }
        // Cursor rect — convert from text container space to window
        // coordinates so the SwiftUI popover can position itself.
        let queryStart = lookbackStart + window.distance(from: window.startIndex, to: openIdx)
        let replaceRange = NSRange(location: queryStart, length: cursor - queryStart)
        let cursorRect = Self.cursorRect(in: tv, atCharacter: cursor)
        let candidate = Trigger(
            query: query,
            replaceRange: replaceRange,
            cursorRect: cursorRect
        )
        if trigger != candidate {
            trigger = candidate
            highlightedIndex = 0
        }
    }

    func dismissTrigger() {
        trigger = nil
        highlightedIndex = 0
    }

    func moveSuggestionSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        let next = (highlightedIndex + delta + suggestions.count) % suggestions.count
        highlightedIndex = next
    }

    /// Replace `[[query` with `[[pageId]]` and move the cursor past
    /// the `]]` so the user can keep typing without manually closing
    /// the brackets. Returns true on successful insert.
    @discardableResult
    func acceptSuggestion(_ pageId: String) -> Bool {
        guard let trigger, let tv = textView else { return false }
        // Insert basename when the resolver hook says it's unique;
        // full id on collision. Falls back to verbatim id when no
        // hook is set (used in contexts where collision matters
        // less, e.g. tests).
        let insertText = resolveInsertText?(pageId) ?? pageId
        let replacement = "\(insertText)]]"
        let replacementNS = replacement as NSString
        tv.replaceCharacters(in: trigger.replaceRange, with: replacement)
        let cursorLoc = trigger.replaceRange.location + replacementNS.length
        // Move the caret past the closing `]]`. STTextView's
        // public selection API goes through the layout manager:
        // build an `NSTextLocation` at the cursor's UTF-16 offset
        // and assign a single zero-length `NSTextSelection`.
        if let target = tv.textLayoutManager.location(
            tv.textLayoutManager.documentRange.location,
            offsetBy: cursorLoc
        ) {
            let range = NSTextRange(location: target)
            tv.textLayoutManager.textSelections = [
                NSTextSelection(range: range, affinity: .downstream, granularity: .character)
            ]
        }
        // STTextView's `replaceCharacters` does fire its delegate
        // callback in our experience, but we still push the binding
        // explicitly so the SwiftUI side reflects the change in case
        // the delegate path is gated by user-vs-programmatic origin.
        if let cb = tv.textDelegate as? MarkdownTextView.Coordinator {
            cb.parent.text = tv.text ?? ""
            cb.storageDelegate.applyStyling(to: tv)
        }
        dismissTrigger()
        return true
    }

    /// Convenience — accept whatever suggestion the SwiftUI popover
    /// has currently highlighted. Returns true if there was something
    /// to insert (caller intercepts the keystroke), false otherwise
    /// (caller lets the keystroke fall through as a literal Tab/Enter).
    @discardableResult
    func acceptHighlightedSuggestion() -> Bool {
        guard !suggestions.isEmpty,
              suggestions.indices.contains(highlightedIndex) else { return false }
        return acceptSuggestion(suggestions[highlightedIndex])
    }

    /// Read the caret position as a UTF-16 offset from the document
    /// start. STTextView's selection is exposed as an `NSTextRange`;
    /// we convert it to a numeric offset using the layout manager.
    private static func cursorOffset(in tv: WikiTextView) -> Int {
        guard let selection = tv.textLayoutManager.textSelections.first?.textRanges.first else {
            return 0
        }
        return tv.textLayoutManager.offset(
            from: tv.textLayoutManager.documentRange.location,
            to: selection.location
        )
    }

    /// Compute the caret rect in the WikiTextView's coordinate space.
    /// The popover anchors to this rect (after applying the editor's
    /// own `.offset` in SwiftUI), so we want a rect relative to the
    /// view, not the window.
    private static func cursorRect(in tv: WikiTextView, atCharacter loc: Int) -> CGRect {
        guard let location = tv.textLayoutManager.location(
            tv.textLayoutManager.documentRange.location,
            offsetBy: loc
        ),
              let frame = tv.textLayoutManager.textSegmentFrame(
                  at: location, type: .standard
              )
        else { return .zero }
        // STTextView's segment frame is already in the view's
        // coordinate space; no further conversion needed for the
        // popover's `.offset` anchor.
        return frame
    }
}
