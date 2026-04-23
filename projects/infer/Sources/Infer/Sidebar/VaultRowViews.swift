import SwiftUI

struct VaultConversationRow: View {
    let conv: VaultConversationSummary
    let onOpen: () -> Void
    let onDelete: () -> Void
    /// Invoked when the user adds a tag via the inline `+` affordance.
    /// Separate from `onOpen` so the row's primary click doesn't
    /// accidentally trigger tag input.
    var onAddTag: ((String) -> Void)? = nil
    var onRemoveTag: ((String) -> Void)? = nil
    var onToggleTagFilter: ((String) -> Void)? = nil

    @State private var showingAddTag: Bool = false
    @State private var draftTag: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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

            tagRow
        }
        .contextMenu {
            Button("Open", action: onOpen)
            if onAddTag != nil {
                Button("Add tag…") { showingAddTag = true }
            }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .popover(isPresented: $showingAddTag, arrowEdge: .top) {
            addTagPopover
        }
    }

    /// Horizontal strip of tag chips plus a `+` affordance. Clicking a
    /// chip toggles that tag in the history filter; long-pressing (via
    /// the `x` icon on hover) removes the tag from the conversation.
    @ViewBuilder
    private var tagRow: some View {
        if !conv.tags.isEmpty || onAddTag != nil {
            HStack(spacing: 3) {
                ForEach(conv.tags, id: \.self) { tag in
                    TagChip(
                        tag: tag,
                        onToggleFilter: onToggleTagFilter.map { f in { f(tag) } },
                        onRemove: onRemoveTag.map { f in { f(tag) } }
                    )
                }
                if onAddTag != nil {
                    Button {
                        draftTag = ""
                        showingAddTag = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.secondary.opacity(0.08))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Add a tag to this conversation.")
                }
            }
        }
    }

    private var addTagPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Add tag").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                TextField("tag", text: $draftTag)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { commitTag() }
                Button("Add") { commitTag() }
                    .controlSize(.small)
                    .disabled(draftTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(minWidth: 180)
        }
        .padding(10)
    }

    private func commitTag() {
        let trimmed = draftTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onAddTag?(trimmed)
        draftTag = ""
        showingAddTag = false
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

/// One tag chip. Click to toggle the history filter; hovering reveals
/// an `x` to remove the tag from this conversation.
private struct TagChip: View {
    let tag: String
    let onToggleFilter: (() -> Void)?
    let onRemove: (() -> Void)?
    @State private var hovering: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                onToggleFilter?()
            } label: {
                Text("#\(tag)")
                    .font(.caption2)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Filter history by #\(tag)")

            if hovering, onRemove != nil {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove this tag")
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(Color.secondary.opacity(0.1))
        )
        .overlay(
            Capsule().stroke(Color.secondary.opacity(0.25))
        )
        .onHover { hovering = $0 }
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
