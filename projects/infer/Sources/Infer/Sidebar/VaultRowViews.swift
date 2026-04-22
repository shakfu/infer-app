import SwiftUI

struct VaultConversationRow: View {
    let conv: VaultConversationSummary
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(conv.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                    HStack(spacing: 4) {
                        Text(conv.backend)
                        Text("·")
                        Text(Self.relativeDate(conv.updatedAt))
                        Text("·")
                        Text("\(conv.messageCount) msg")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open", action: onOpen)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func relativeDate(_ d: Date) -> String {
        relFormatter.localizedString(for: d, relativeTo: Date())
    }
}

struct VaultHitRow: View {
    let hit: VaultSearchHit
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(hit.conversationTitle)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(hit.role)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(Self.attributed(from: hit.snippet))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    /// Parse FTS5 snippet output (`...<mark>term</mark>...`) into an
    /// AttributedString with highlighted runs. Unknown `<mark>` HTML is the
    /// only markup our snippet() call emits, so this parser is intentionally
    /// trivial rather than going through NSAttributedString's HTML import.
    static func attributed(from snippet: String) -> AttributedString {
        var out = AttributedString()
        var remaining = Substring(snippet)
        while let openRange = remaining.range(of: "<mark>") {
            let before = remaining[..<openRange.lowerBound]
            if !before.isEmpty {
                out.append(AttributedString(String(before)))
            }
            let afterOpen = remaining[openRange.upperBound...]
            guard let closeRange = afterOpen.range(of: "</mark>") else {
                out.append(AttributedString(String(afterOpen)))
                return out
            }
            let marked = afterOpen[..<closeRange.lowerBound]
            var run = AttributedString(String(marked))
            run.backgroundColor = .yellow.opacity(0.4)
            run.foregroundColor = .primary
            out.append(run)
            remaining = afterOpen[closeRange.upperBound...]
        }
        if !remaining.isEmpty {
            out.append(AttributedString(String(remaining)))
        }
        return out
    }
}
