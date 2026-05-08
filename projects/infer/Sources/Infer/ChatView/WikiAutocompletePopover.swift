import SwiftUI

/// Floating list of wikilink suggestions rendered just below the
/// cursor when the user types `[[`. Anchored via `.offset` from the
/// editor's coordinate origin (the `MarkdownTextViewController`
/// reports the cursor rect in NSTextView coordinates which matches
/// the SwiftUI overlay's coordinate space).
///
/// Selection lives in the controller so the NSTextView coordinator
/// can resolve Tab / Enter / Up / Down to the right page id without
/// the SwiftUI side having to forward keystrokes back through the
/// responder chain.
struct WikiAutocompletePopover: View {
    let query: String
    let candidates: [String]
    @ObservedObject var controller: MarkdownTextViewController

    var body: some View {
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(candidates.enumerated()), id: \.element) { idx, id in
                    Button {
                        controller.acceptSuggestion(id)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            // Basename as primary, folder path as
                            // secondary — same visual model as the
                            // sidebar tree leaves and the Cmd+O
                            // quick switcher. The full id is still
                            // what gets inserted on accept (so links
                            // round-trip through the resolver
                            // unambiguously); the popover just
                            // renders the human-readable shape.
                            Text((id as NSString).lastPathComponent)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            let folder = (id as NSString).deletingLastPathComponent
                            if !folder.isEmpty {
                                Text(folder)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 6)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            idx == controller.highlightedIndex
                                ? Color.accentColor.opacity(0.18)
                                : Color.clear
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { controller.highlightedIndex = idx }
                    }
                }
                if !query.isEmpty {
                    Divider()
                    HStack(spacing: 4) {
                        Image(systemName: "return")
                            .font(.caption2)
                        Text("insert · esc cancels · ↑↓ select")
                            .font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                }
            }
            .frame(width: 240)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.secondary.opacity(0.25), lineWidth: 1)
            )
            .shadow(radius: 6, y: 2)
        }
    }
}
