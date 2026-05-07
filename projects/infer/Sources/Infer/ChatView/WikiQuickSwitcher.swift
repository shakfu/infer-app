import SwiftUI
import AppKit
import InferCore

/// Cmd+O fuzzy page picker. Modal sheet with a single text field
/// and a filtered list of every page in the active workspace.
/// Up/Down move the highlight, Enter opens the highlighted page as
/// a tab, Esc dismisses. Click on a row also opens.
///
/// Ranking is cheap: case-folded prefix matches on basename rank
/// first, then case-folded contains matches on basename, then
/// matches on the full path. Capped at 50 hits so the list never
/// dominates the sheet — wikis above that scale need a real
/// indexed search, which is what RAG already provides.
struct WikiQuickSwitcher: View {
    @Bindable var vm: ChatViewModel

    @State private var query: String = ""
    @State private var highlightedIndex: Int = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Find or open page…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($fieldFocused)
                    .onSubmit { acceptHighlight() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if matches.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { idx, page in
                            row(for: page, index: idx)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .background(keyboardHandlers)
        .onAppear {
            // Focus the field on present so the user can start
            // typing immediately. Has to fire after the sheet has
            // rendered, hence the async hop.
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(vm.wikiPages.isEmpty
                 ? "No pages in this workspace yet."
                 : "No matches for “\(query)”.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func row(for page: WikiPage, index idx: Int) -> some View {
        let isActive = idx == highlightedIndex
        Button {
            highlightedIndex = idx
            open(page)
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(basename(of: page.id))
                        .font(.system(size: 13, weight: isActive ? .medium : .regular))
                        .foregroundStyle(.primary)
                    if folderPath(of: page.id) != "" {
                        Text(folderPath(of: page.id))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
                if isActive {
                    Image(systemName: "return")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isActive
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { highlightedIndex = idx }
        }
    }

    /// Hidden Up / Down / Enter / Esc shortcuts. Esc dismisses by
    /// flipping `vm.showQuickSwitcher` — the sheet binding listens
    /// to that and tears the view down.
    private var keyboardHandlers: some View {
        Group {
            Button("") { moveHighlight(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") { moveHighlight(+1) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("") { acceptHighlight() }
                .keyboardShortcut(.defaultAction)
            Button("") { vm.showQuickSwitcher = false }
                .keyboardShortcut(.cancelAction)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: - Match logic

    private var matches: [WikiPage] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            return Array(vm.wikiPages.prefix(50))
        }
        let prefix = vm.wikiPages.filter {
            basename(of: $0.id).lowercased().hasPrefix(q)
        }
        let contains = vm.wikiPages.filter {
            let base = basename(of: $0.id).lowercased()
            return !base.hasPrefix(q) && base.contains(q)
        }
        let inPath = vm.wikiPages.filter {
            let id = $0.id.lowercased()
            let base = basename(of: $0.id).lowercased()
            return !base.contains(q) && id.contains(q)
        }
        return Array((prefix + contains + inPath).prefix(50))
    }

    private func basename(of id: String) -> String {
        (id as NSString).lastPathComponent
    }

    private func folderPath(of id: String) -> String {
        let parent = (id as NSString).deletingLastPathComponent
        return parent
    }

    // MARK: - Actions

    private func moveHighlight(_ delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        let next = (highlightedIndex + delta + count) % count
        highlightedIndex = next
    }

    private func acceptHighlight() {
        guard matches.indices.contains(highlightedIndex) else { return }
        open(matches[highlightedIndex])
    }

    private func open(_ page: WikiPage) {
        vm.openWikiPage(page.id)
        vm.showQuickSwitcher = false
    }
}
