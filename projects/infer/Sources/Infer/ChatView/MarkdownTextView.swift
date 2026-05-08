import SwiftUI
import AppKit
import Combine
import Highlightr
import STTextView
import STTextKitPlus
import SwiftTreeSitter
import TreeSitterMarkdown

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
        // Arrow / Tab / Enter / Esc routing for the autocomplete popover.
        // STTextViewDelegate has no `doCommand(by:)` callback, so we
        // intercept directly on the NSTextView subclass.
        tv.doCommandHandler = { [weak controller] selector in
            guard let controller, controller.trigger != nil else { return false }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertTab(_:)):
                return controller.acceptHighlightedSuggestion()
            case #selector(NSResponder.cancelOperation(_:)):
                controller.dismissTrigger()
                return true
            case #selector(NSResponder.moveDown(_:)):
                controller.moveSuggestionSelection(by: +1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                controller.moveSuggestionSelection(by: -1)
                return true
            default:
                return false
            }
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

        // Tree-sitter pass — authoritative source for both block
        // structure (headings, fenced code, pandoc code) and inline
        // spans (emphasis / strong / code_span / inline_link). The
        // inline grammar is run as a second stage and pre-filtered to
        // only spans inside `inline` block-nodes, so emphasis-looking
        // text inside fenced code (`**args` in Python, etc.) doesn't
        // get bolded.
        let parsed = treeSitterParser.parse(text: str as String)
        var fenceContentRanges: [(language: String, range: NSRange)] = []

        for block in parsed.blocks {
            switch block.kind {
            case .heading(let level):
                // Apply heading font ONLY to the inline-content portion
                // (heading text minus marker) so the marker stays at
                // body size — looks more like a comment / label than a
                // big-font symbol that competes with the heading text.
                let textRange = block.innerRange ?? block.outerRange
                textStorage.addAttributes([
                    .font: headingFont(level: level),
                ], range: textRange)
                if let marker = block.markerRange {
                    textStorage.addAttributes([
                        .foregroundColor: mutedColor,
                    ], range: marker)
                }
            case .fencedCode(let language):
                applyCodeBlock(line: block.outerRange, in: textStorage)
                if let info = block.markerRange {
                    textStorage.addAttributes(
                        [.foregroundColor: mutedColor], range: info
                    )
                }
                if let inner = block.innerRange,
                   let lang = language, !lang.isEmpty {
                    fenceContentRanges.append((language: lang, range: inner))
                }
            }
        }

        // Inline span attributes from the tree-sitter inline pass.
        // For each span we read the existing font (which may already
        // be a heading font) and combine traits, so emphasis inside a
        // heading composes correctly (heading-size + italic, etc.).
        for span in parsed.inlines {
            applyInlineSpan(span, on: textStorage)
        }

        // Wikilinks `[[...]]` — not part of either tree-sitter
        // grammar; layered as a regex pass after the tree-sitter
        // styling. Skipped over fenced code regions so the brackets
        // don't get accent-colored inside code blocks.
        applyWikilinks(in: textStorage, fenceRanges: fenceContentRanges.map(\.range))

        // Per-language fence coloring. Python goes through
        // tree-sitter-python + the upstream highlights.scm (high-
        // fidelity, native). Everything else routes to Highlightr
        // (highlight.js via JavaScriptCore) which gives ~190
        // grammars for free. Highlightr is already in the dep graph
        // for the chat transcript, so wiring it back into the wiki
        // path costs nothing extra.
        for hl in fenceContentRanges {
            if hl.language == "python" {
                applyPythonHighlights(in: hl.range, on: textStorage)
            } else {
                applyHighlightrHighlights(
                    in: hl.range, language: hl.language, on: textStorage
                )
            }
        }
    }

    /// Pull the Python fence content out, run it through
    /// `WikiPythonHighlighter`, and paint each emitted color span
    /// onto the storage. The highlighter caches by source string so
    /// edits elsewhere in the document don't re-run the Python parse.
    private func applyPythonHighlights(in range: NSRange, on storage: NSTextStorage) {
        guard range.length > 0,
              range.location + range.length <= storage.length else { return }
        let source = (storage.string as NSString).substring(with: range)
        let spans = pythonHighlighter.highlights(for: source, baseOffset: range.location)
        for span in spans {
            guard span.range.location + span.range.length <= storage.length else { continue }
            storage.addAttributes([.foregroundColor: span.color], range: span.range)
        }
    }

    /// Highlightr fallback for non-Python fenced code. Boots a single
    /// JSContext + highlight.js once per app session (lazy static)
    /// and reuses it across every wiki edit. Highlightr only adds
    /// `.foregroundColor`; the monospaced font from `applyCodeBlock`
    /// remains.
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

    /// Lazy app-wide Highlightr instance. Construction loads
    /// highlight.js + the active stylesheet, so we share one across
    /// all open wiki editors.
    nonisolated(unsafe) private static let sharedHighlightr: Highlightr? = {
        let hl = Highlightr()
        hl?.setTheme(to: "xcode")
        return hl
    }()

    /// Apply attributes for a single inline span produced by the
    /// inline tree-sitter pass. Reads the existing font at the span's
    /// start so traits compose with whatever heading/body font was
    /// already painted.
    private func applyInlineSpan(_ span: ParsedInlineSpan, on storage: NSTextStorage) {
        guard span.range.location + span.range.length <= storage.length else { return }
        switch span.kind {
        case .emphasis:
            applyTrait(.italic, range: span.range, on: storage)
        case .strongEmphasis:
            applyTrait(.bold, range: span.range, on: storage)
        case .codeSpan:
            storage.addAttributes([.font: monospacedFont], range: span.range)
        case .inlineLink:
            storage.addAttributes([
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: span.range)
        }
    }

    private func applyTrait(_ trait: NSFontDescriptor.SymbolicTraits, range: NSRange, on storage: NSTextStorage) {
        let existing = (storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) ?? baseFont
        var symbolic = existing.fontDescriptor.symbolicTraits
        symbolic.insert(trait)
        let descriptor = existing.fontDescriptor.withSymbolicTraits(symbolic)
        let combined = NSFont(descriptor: descriptor, size: existing.pointSize) ?? existing
        storage.addAttributes([.font: combined], range: range)
    }

    /// Pass over the document for `[[wikilinks]]`. Tree-sitter doesn't
    /// know about them; the regex is cheap and runs after all
    /// tree-sitter attribute writes so it overrides the heading /
    /// emphasis foreground when a wikilink sits inside one.
    private func applyWikilinks(in storage: NSTextStorage, fenceRanges: [NSRange]) {
        guard let regex = try? NSRegularExpression(pattern: "\\[\\[[^\\]\\n]+\\]\\]") else { return }
        let str = storage.string as NSString
        let full = NSRange(location: 0, length: str.length)
        regex.enumerateMatches(in: str as String, range: full) { match, _, _ in
            guard let m = match else { return }
            // Skip wikilinks inside fenced code regions — the brackets
            // are literal in code, not a link.
            for fence in fenceRanges {
                if NSIntersectionRange(m.range, fence).length > 0 { return }
            }
            storage.addAttributes([
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: m.range)
        }
    }

    /// Per-delegate tree-sitter parser. Each `WikiTextStorageDelegate`
    /// owns one `WikiTreeSitterParser` so the cached parse tree
    /// belongs to a single document — sharing across editors would
    /// invalidate the incremental cache on every page switch.
    private let treeSitterParser = WikiTreeSitterParser()
    /// Python in-fence highlighter. Holds its own `tree-sitter-python`
    /// parser + the upstream `highlights.scm` query. Activated for
    /// fences whose info string is `python` (or pandoc `{python}`).
    private let pythonHighlighter = WikiPythonHighlighter()

    // MARK: - Code block

    private func applyCodeBlock(line: NSRange, in storage: NSTextStorage) {
        storage.addAttributes([
            .font: monospacedFont,
            .foregroundColor: baseColor,
        ], range: line)
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

    /// Selector intercept hook used by the autocomplete popover to
    /// capture arrow keys / Tab / Enter / Esc when its trigger is
    /// active. Returns `true` if the selector was handled (in which
    /// case `super.doCommand(by:)` is skipped). Set by `MarkdownTextView`
    /// from the coordinator so SwiftUI can route into
    /// `MarkdownTextViewController`.
    ///
    /// Why this isn't an `STTextViewDelegate` method: STTextView's
    /// delegate protocol doesn't expose `doCommand(by:)`. We could
    /// implement an `STPlugin` for the same effect, but a direct
    /// override on the NSTextView subclass is the smallest hook that
    /// works — `STTextView` inherits NSResponder's command routing
    /// unchanged.
    var doCommandHandler: ((Selector) -> Bool)?

    override func doCommand(by selector: Selector) {
        if doCommandHandler?(selector) == true { return }
        super.doCommand(by: selector)
    }

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
