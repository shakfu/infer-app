import SwiftUI
import AppKit
import Combine

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
        // Manual NSScrollView + WikiTextView setup (rather than the
        // `NSTextView.scrollableTextView()` convenience) so we can
        // use a custom NSTextView subclass that handles Cmd-click on
        // wikilinks. Boilerplate matches what the convenience would
        // build, just with the subclass slotted in.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true

        let bigDimension: CGFloat = 1_000_000
        let container = NSTextContainer(containerSize: NSSize(
            width: 0, height: bigDimension
        ))
        container.widthTracksTextView = true
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let tv = WikiTextView(frame: .zero, textContainer: container)
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: bigDimension, height: bigDimension)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.delegate = context.coordinator
        tv.allowsUndo = true
        tv.isRichText = false
        tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = NSColor.textColor
        tv.string = text
        tv.textContainerInset = NSSize(width: 8, height: 8)
        // Hook the storage delegate so `[[wikilink]]` spans get
        // accent-colored, underlined styling on every edit. The
        // initial sweep fires after the `string =` assignment above
        // because we run it manually below — `setAttributes` doesn't
        // trigger the delegate, but the initial string assign did
        // process characters, which already invoked our delegate
        // once if we'd attached it earlier. Doing it here keeps the
        // ordering predictable.
        if let storage = tv.textStorage {
            storage.delegate = context.coordinator.storageDelegate
            // Force one sweep so existing pages render with link
            // styling on first appearance — the assign above ran
            // before the delegate was attached.
            storage.edited(.editedCharacters,
                           range: NSRange(location: 0, length: storage.length),
                           changeInLength: 0)
        }
        // Cmd-click anywhere inside a [[...]] span fires this — the
        // controller routes it to the SwiftUI side, which resolves
        // the target id and opens the page as a tab.
        tv.onWikilinkClick = { [weak controller] target in
            controller?.fireWikilinkClick(target)
        }
        controller.textView = tv

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        // External update from the binding — only force-reload when
        // the strings actually diverge so we don't blow away the
        // user's typing on every keystroke (textDidChange fires the
        // binding, which fires updateNSView, which would otherwise
        // reset the cursor).
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            let nsLen = (text as NSString).length
            let safeLoc = min(sel.location, nsLen)
            tv.setSelectedRange(NSRange(location: safeLoc, length: 0))
            // Re-sweep wikilink styling — `string = ...` resets the
            // storage to plain text (no per-char attributes), so the
            // delegate needs another pass.
            if let storage = tv.textStorage {
                storage.edited(.editedCharacters,
                               range: NSRange(location: 0, length: storage.length),
                               changeInLength: 0)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextView
        /// Owned by the coordinator so the strong reference outlives
        /// the textStorage's weak `delegate` slot.
        let storageDelegate = WikiTextStorageDelegate()
        init(_ parent: MarkdownTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.controller.recomputeTrigger(in: tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.controller.recomputeTrigger(in: tv)
        }

        /// Intercept Return / Tab / Escape when the autocomplete is
        /// active so the popover can capture them as accept / cancel
        /// without the text view inserting a literal newline / tab.
        /// Other commands fall through (Down / Up arrow are also
        /// handled by the popover via NotificationCenter; commenting
        /// out for now to keep this scope tight).
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
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

/// `NSTextStorageDelegate` that styles `[[wikilink]]` spans as
/// accent-colored, underlined text — matches the link styling of
/// the chat transcript so the same visual idiom carries across both
/// surfaces. Triggers on every edit; the scan is O(N) over the full
/// storage which is fine at personal-notes scale (~10k chars).
///
/// Applies attributes via `setAttributes` (not `replaceCharacters`)
/// inside `didProcessEditing`, which is documented as safe — only
/// character mutations would re-entrantly fire the delegate.
final class WikiTextStorageDelegate: NSObject, NSTextStorageDelegate {
    private let baseFont: NSFont
    private let baseColor: NSColor
    private let linkColor: NSColor

    init(
        font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
        textColor: NSColor = .textColor,
        linkColor: NSColor = .controlAccentColor
    ) {
        self.baseFont = font
        self.baseColor = textColor
        self.linkColor = linkColor
    }

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // `editedAttributes`-only edits are us re-applying styling
        // and should NOT trigger another sweep. Only character
        // mutations matter.
        guard editedMask.contains(.editedCharacters) else { return }
        let str = textStorage.string as NSString
        let full = NSRange(location: 0, length: str.length)

        // Reset everything to plain. Cheaper than diffing — full
        // sweep handles delete-of-a-link, paste, undo, etc.
        textStorage.setAttributes([
            .font: baseFont,
            .foregroundColor: baseColor,
        ], range: full)

        // Apply wikilink styling to every `[[...]]` span. State-
        // machine version of `extractLinks`'s scan, but applying
        // attributes instead of harvesting targets. Doesn't honour
        // code fences for now — `[[example]]` inside a fenced
        // sample will render styled. Acceptable in an authoring
        // context where code samples with wikilinks are rare; if
        // it bites we can promote to the full state-machine logic.
        var searchStart = 0
        while searchStart < str.length {
            let openRange = str.range(
                of: "[[",
                range: NSRange(location: searchStart, length: str.length - searchStart)
            )
            guard openRange.location != NSNotFound else { break }
            let innerStart = openRange.upperBound
            guard innerStart <= str.length else { break }
            let closeRange = str.range(
                of: "]]",
                range: NSRange(location: innerStart, length: str.length - innerStart)
            )
            guard closeRange.location != NSNotFound else { break }
            let span = NSRange(
                location: openRange.location,
                length: closeRange.upperBound - openRange.location
            )
            textStorage.addAttributes([
                .foregroundColor: linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: span)
            searchStart = closeRange.upperBound
        }
    }
}

/// `NSTextView` subclass that surfaces Cmd-click on `[[wikilinks]]`
/// as a callback. Plain clicks fall through to standard text-view
/// behaviour (cursor positioning, selection, IME) — only the Cmd
/// modifier triggers the link-follow path so editing inside a
/// wikilink isn't disrupted.
final class WikiTextView: NSTextView {
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
    /// span contains the click. Returns `nil` when the click is
    /// outside any span, the span is unclosed, or the inner text is
    /// empty after stripping alias / section fragment.
    private func wikilinkTarget(at event: NSEvent) -> String? {
        guard let layoutManager = self.layoutManager,
              let container = self.textContainer,
              let storage = self.textStorage else { return nil }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(
            x: viewPoint.x - textContainerOrigin.x,
            y: viewPoint.y - textContainerOrigin.y
        )
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: container)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let nsStr = storage.string as NSString
        guard charIndex < nsStr.length else { return nil }

        // Look back from the click for the most recent `[[`.
        let beforeRange = NSRange(location: 0, length: charIndex)
        let openRange = nsStr.range(
            of: "[[", options: .backwards, range: beforeRange
        )
        // If `[[` isn't found before the click but the click sits
        // exactly on `[[`, we still want to handle it — extend the
        // search to include charIndex itself.
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

        // Find the matching `]]`. Bail if the span runs past EOF.
        let afterRange = NSRange(
            location: innerStart, length: nsStr.length - innerStart
        )
        let closeRange = nsStr.range(of: "]]", options: [], range: afterRange)
        guard closeRange.location != NSNotFound else { return nil }

        // Click must land inside the `[[...]]` span (between the
        // opening and the start of the closing). Allow the click at
        // the closing markers too — feels natural.
        guard charIndex >= innerStart, charIndex <= closeRange.location + 1 else {
            return nil
        }

        let inner = nsStr.substring(with: NSRange(
            location: innerStart, length: closeRange.location - innerStart
        ))
        // Strip alias (`|...`) and section fragment (`#...`) — same
        // as the resolver does for inbound link extraction.
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

    weak var textView: NSTextView?

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
    func recomputeTrigger(in tv: NSTextView) {
        let nsString = tv.string as NSString
        let cursor = tv.selectedRange().location
        guard cursor <= nsString.length else {
            trigger = nil
            return
        }
        // Look back at most 128 characters for an unclosed `[[`.
        // Wikilinks longer than that are nonsensical; capping the
        // window keeps the search O(constant).
        let lookbackStart = max(0, cursor - 128)
        let window = nsString.substring(with: NSRange(location: lookbackStart, length: cursor - lookbackStart))
        guard let openIdx = window.range(of: "[[", options: .backwards)?.upperBound else {
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
        let storage = tv.textStorage
        // Insert basename when the resolver hook says it's unique;
        // full id on collision. Falls back to verbatim id when no
        // hook is set (used in contexts where collision matters
        // less, e.g. tests).
        let insertText = resolveInsertText?(pageId) ?? pageId
        let replacement = "\(insertText)]]"
        let replacementNS = replacement as NSString
        storage?.beginEditing()
        // Replace the query characters; `[[` already exists immediately
        // before `replaceRange.location` so the final string reads as
        // `[[<pageId>]]`.
        storage?.replaceCharacters(
            in: trigger.replaceRange,
            with: NSAttributedString(
                string: replacement,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor.textColor,
                ]
            )
        )
        storage?.endEditing()
        let cursorLoc = trigger.replaceRange.location + replacementNS.length
        tv.setSelectedRange(NSRange(location: cursorLoc, length: 0))
        // Manually fire the binding update — programmatic mutations
        // through `textStorage` don't trigger `textDidChange`.
        if let cb = tv.delegate as? MarkdownTextView.Coordinator {
            cb.parent.text = tv.string
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

    /// Compute the cursor rect in window coordinates. NSTextView's
    /// layout manager gives the rect in text-container coordinates,
    /// which we convert through the text container origin and the
    /// view's coordinate system.
    private static func cursorRect(in tv: NSTextView, atCharacter loc: Int) -> CGRect {
        guard let layoutManager = tv.layoutManager,
              let textContainer = tv.textContainer else { return .zero }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: loc, length: 0),
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        // Translate text-container coords to view coords.
        rect.origin.x += tv.textContainerOrigin.x
        rect.origin.y += tv.textContainerOrigin.y
        // View coords → window coords (callers may convert further to
        // screen if they need).
        return tv.convert(rect, to: nil)
    }
}
