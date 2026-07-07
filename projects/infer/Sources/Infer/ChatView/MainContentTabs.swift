import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Payload for dragging a tab chip to reorder. Chat is fixed-position
/// (the VM rejects reorders that involve `.chat`), so this only ever
/// flows on `.page(id:)` tabs in practice — but the payload encodes
/// the full enum so the receiving drop handler doesn't have to make
/// that assumption.
struct WikiTabDragPayload: Codable, Transferable {
    let tab: WikiTab

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .wikiTabDrag)
    }
}

extension UTType {
    static let wikiTabDrag = UTType(exportedAs: "com.infer.wiki.tab.drag")
}

/// Tab bar that sits at the very top of the main content area —
/// chat is always tab 0, wiki pages opened from the sidebar appear
/// as additional tabs on the right. Closing a tab returns focus to
/// chat; chat itself can't be closed.
///
/// Visual model intentionally mirrors browser / Obsidian tabs: a
/// single horizontal strip, scrollable when many pages are open,
/// active tab inset slightly so the divider beneath aligns with
/// the bottom of the strip.
struct MainContentTabBar: View {
    @Bindable var vm: ChatViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(vm.openTabs, id: \.self) { tab in
                    TabChip(
                        tab: tab,
                        title: title(for: tab),
                        active: tab == vm.activeTab,
                        canClose: tab != .chat,
                        onSelect: { vm.switchTab(tab) },
                        onClose: { vm.closeTab(tab) },
                        onReorderDrop: { source in
                            vm.reorderTab(source, before: tab)
                        }
                    )
                }
                Button {
                    vm.openNewWikiPage()
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .help("New page")
                Spacer(minLength: 0)
            }
        }
        .frame(height: 30)
        .background(Color(.windowBackgroundColor))
    }

    private func title(for tab: WikiTab) -> String {
        switch tab {
        case .chat: return "Chat"
        case .page(let id): return id.isEmpty ? "Untitled" : id
        case .terminal: return "Terminal"
        }
    }
}

private struct TabChip: View {
    let tab: WikiTab
    let title: String
    let active: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onReorderDrop: (WikiTab) -> Void

    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.caption2)
                .foregroundStyle(active ? .primary : .secondary)
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(active ? .primary : .secondary)
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                        .background(
                            Circle().fill(
                                hovering
                                    ? Color.secondary.opacity(0.18)
                                    : Color.clear
                            )
                        )
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: 220)
        .background(
            active
                ? Color(.textBackgroundColor)
                : (hovering ? Color.secondary.opacity(0.06) : Color.clear)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.separator)
                .frame(width: 1)
        }
        .overlay(alignment: .bottom) {
            // Active-tab indicator: bottom strip uses the accent
            // colour. Inactive tabs share the strip's bottom border.
            Rectangle()
                .fill(active ? Color.accentColor : .clear)
                .frame(height: 2)
        }
        .overlay(alignment: .leading) {
            // Drop indicator while another tab is being reordered
            // onto this one. 2pt accent stripe on the leading edge
            // shows the user "this is where the dragged tab will
            // land", same idiom as folder drop targets.
            if dropTargeted {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .draggable(WikiTabDragPayload(tab: tab)) {
            // Custom drag preview — a compact pill that reads as the
            // tab being dragged rather than a snapshot of the chip
            // (which is wide + has a close button that's awkward
            // mid-drag).
            HStack(spacing: 4) {
                Image(systemName: iconName).font(.caption2)
                Text(title).font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
        }
        .dropDestination(for: WikiTabDragPayload.self) { drops, _ in
            for drop in drops { onReorderDrop(drop.tab) }
            return !drops.isEmpty
        } isTargeted: { dropTargeted = $0 }
    }

    private var iconName: String {
        switch tab {
        case .chat: return "bubble.left.and.bubble.right"
        case .page: return "doc.text"
        case .terminal: return "terminal"
        }
    }
}
