import SwiftUI
import InferCore

/// Trailing-`[[` autocomplete for the chat composer. Detects an
/// unclosed `[[query` at the end of `vm.input`, fuzzy-matches page
/// ids, and inserts `[[Page]]` on selection. Lighter-weight than
/// the full `MarkdownTextView` autocomplete: SwiftUI's
/// `TextField` / `TextEditor` don't expose cursor position, so we
/// only handle the trailing-position case (which covers ~95% of
/// linear-typing flows in a chat composer).
///
/// Mid-edit insertions (the cursor mid-message, user types `[[`)
/// don't trigger the popover. Users in that case would either
/// finish typing the page name manually or use Cmd+O to look it up.
struct ChatComposerMentionsBar: View {
    @Bindable var vm: ChatViewModel

    var body: some View {
        if let trigger = trailingTrigger {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches(for: trigger.query), id: \.self) { id in
                    Button {
                        insertMention(id, replacing: trigger)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(basename(of: id))
                                .font(.callout)
                                .foregroundStyle(.primary)
                            if folderPath(of: id) != "" {
                                Text(folderPath(of: id))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 6)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.secondary.opacity(0.25), lineWidth: 1)
            )
        }
    }

    // MARK: - Trigger detection

    /// The trailing-`[[query` state, if the input ends with one.
    /// Returns nil if there's no open `[[`, the brackets are closed,
    /// or the query contains a newline / tab (= probably not a
    /// link the user is mid-typing).
    private var trailingTrigger: TrailingTrigger? {
        let input = vm.input
        guard let openRange = input.range(of: "[[", options: .backwards) else {
            return nil
        }
        let after = input[openRange.upperBound...]
        // If `]]` appears after the most recent `[[`, the user has
        // already closed the link — nothing to autocomplete.
        if after.contains("]]") { return nil }
        if after.contains("\n") || after.contains("\t") { return nil }
        let query = String(after)
        // Don't trigger for queries with closing brackets — could be
        // pathological input.
        if query.contains("]") || query.contains("[") { return nil }
        return TrailingTrigger(
            query: query,
            replaceFromIndex: openRange.upperBound
        )
    }

    private struct TrailingTrigger {
        let query: String
        let replaceFromIndex: String.Index
    }

    // MARK: - Match logic

    private func matches(for query: String) -> [String] {
        let q = query.lowercased()
        let allIds = vm.wikiPages.map(\.id)
        guard !q.isEmpty else {
            return Array(allIds.prefix(5))
        }
        let prefix = allIds.filter {
            basename(of: $0).lowercased().hasPrefix(q)
        }
        let contains = allIds.filter {
            let b = basename(of: $0).lowercased()
            return !b.hasPrefix(q) && b.contains(q)
        }
        return Array((prefix + contains).prefix(5))
    }

    private func basename(of id: String) -> String {
        (id as NSString).lastPathComponent
    }

    private func folderPath(of id: String) -> String {
        (id as NSString).deletingLastPathComponent
    }

    // MARK: - Insert

    /// Replace the trailing `[[query` with `[[<chosenId>]]`. The
    /// existing `[[` stays in place (so `replaceFromIndex` points
    /// just *past* it); we replace from there to end-of-string.
    /// SwiftUI's text bindings don't let us position the cursor —
    /// the user types past the inserted closing `]]` naturally.
    private func insertMention(_ id: String, replacing trigger: TrailingTrigger) {
        let prefix = vm.input[vm.input.startIndex..<trigger.replaceFromIndex]
        vm.input = String(prefix) + id + "]] "
    }
}
