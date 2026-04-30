import SwiftUI
import AppKit

/// Filter for the gallery window's main grid. Persists per-launch via
/// the window's own `@State`; not part of `InferSettings` because the
/// filter is a transient UI preference, not a configuration value.
enum GalleryFilter: String, CaseIterable, Identifiable {
    case all
    case kept
    case unkept

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .kept: return "Kept"
        case .unkept: return "Unkept"
        }
    }
}

/// Dedicated window for browsing + curating the SD/cloud-image gallery.
/// Lives in its own `Window` scene so the user can leave it open
/// alongside the chat. Larger thumbnails than the sidebar's recents
/// strip; supports multi-select, bulk keep/delete, and a kept-flag
/// filter. Deletion routes through `NSWorkspace.recycle` (Trash) so
/// every action is recoverable from Finder.
///
/// Multi-select model: tap toggles, ⌘-click toggles (additive), ⇧-click
/// extends from the last anchor in the visible grid. Plain selection
/// (no modifier) replaces the set with the single tapped item — same
/// idiom as Finder.
struct GalleryView: View {
    @Bindable var vm: ChatViewModel

    @State private var filter: GalleryFilter = .all
    @State private var selection: Set<URL> = []
    @State private var lastAnchor: URL? = nil
    @State private var detailEntry: SDGalleryEntry? = nil

    private var filtered: [SDGalleryEntry] {
        switch filter {
        case .all: return vm.sdGallery
        case .kept: return vm.sdGallery.filter { $0.metadata.kept }
        case .unkept: return vm.sdGallery.filter { !$0.metadata.kept }
        }
    }

    private var selectedEntries: [SDGalleryEntry] {
        let s = selection
        return vm.sdGallery.filter { s.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 180), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(filtered) { entry in
                            GalleryCell(
                                entry: entry,
                                isSelected: selection.contains(entry.id),
                                onTap: { handleTap(entry) },
                                onDoubleTap: { detailEntry = entry },
                                onContextAction: { action in
                                    handleContextAction(action, on: entry)
                                }
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear { vm.refreshGallery() }
        .sheet(item: $detailEntry) { entry in
            GalleryDetailSheet(vm: vm, entry: entry) { detailEntry = nil }
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Filter", selection: $filter) {
                ForEach(GalleryFilter.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            // Bulk actions — disabled when nothing is selected so users
            // don't accidentally hit the empty-set Delete.
            Button {
                vm.bulkSetKept(selectedEntries, kept: true)
            } label: {
                Label("Keep", systemImage: "heart.fill")
            }
            .disabled(selection.isEmpty)
            .help("Mark the selected images as Kept.")

            Button {
                vm.bulkSetKept(selectedEntries, kept: false)
            } label: {
                Label("Unkeep", systemImage: "heart.slash")
            }
            .disabled(selection.isEmpty)
            .help("Clear the Kept flag on the selected images.")

            Button(role: .destructive) {
                let entries = selectedEntries
                vm.bulkDelete(entries)
                selection.subtract(entries.map { $0.id })
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selection.isEmpty)
            .keyboardShortcut(.delete, modifiers: [])
            .help("Move the selected images to Trash. Recoverable via Finder's Put Back.")

            Divider().frame(height: 18)

            Button {
                NSWorkspace.shared.open(vm.sdOutputDirectory)
            } label: {
                Label("Reveal", systemImage: "folder")
            }
            .help("Open the output folder in Finder.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var countLabel: String {
        let total = vm.sdGallery.count
        let shown = filtered.count
        let sel = selection.count
        if sel > 0 {
            return "\(sel) selected · \(shown)/\(total) shown"
        }
        return "\(shown)/\(total)"
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(filter == .all ? "No generated images yet" : "No \(filter.label.lowercased()) images")
                .font(.headline)
                .foregroundStyle(.secondary)
            if filter != .all {
                Button("Show all") { filter = .all }
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Selection

    private func handleTap(_ entry: SDGalleryEntry) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            // ⌘-click toggles membership without clearing.
            if selection.contains(entry.id) {
                selection.remove(entry.id)
            } else {
                selection.insert(entry.id)
            }
            lastAnchor = entry.id
        } else if mods.contains(.shift), let anchor = lastAnchor,
                  let a = filtered.firstIndex(where: { $0.id == anchor }),
                  let b = filtered.firstIndex(where: { $0.id == entry.id }) {
            // ⇧-click extends from anchor across the visible (filtered)
            // grid order — same shape Finder uses.
            let lo = min(a, b), hi = max(a, b)
            for i in lo...hi {
                selection.insert(filtered[i].id)
            }
        } else {
            // Plain click: replace with single selection.
            selection = [entry.id]
            lastAnchor = entry.id
        }
    }

    private func handleContextAction(_ action: GalleryCellAction, on entry: SDGalleryEntry) {
        switch action {
        case .toggleKept:
            vm.setKept(entry, kept: !entry.metadata.kept)
        case .delete:
            vm.deleteGalleryEntry(entry)
            selection.remove(entry.id)
        case .reuseSettings:
            vm.reuseGalleryEntrySettings(entry)
        case .useInChat:
            vm.useGalleryEntryInChat(entry)
        case .reveal:
            vm.revealGalleryEntryInFinder(entry)
        case .showDetail:
            detailEntry = entry
        }
    }
}

enum GalleryCellAction {
    case toggleKept
    case delete
    case reuseSettings
    case useInChat
    case reveal
    case showDetail
}

/// One cell in the gallery grid. ~180px square thumbnail with a kept-
/// flag indicator overlay and a selection ring. Image is loaded
/// lazily by `NSImage(contentsOf:)` — `LazyVGrid` only realises the
/// visible cells, so memory stays bounded for large galleries.
struct GalleryCell: View {
    let entry: SDGalleryEntry
    let isSelected: Bool
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onContextAction: (GalleryCellAction) -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = NSImage(contentsOf: entry.imageURL) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 180, height: 180)
                            .clipped()
                            .cornerRadius(8)
                    } else {
                        Color.gray.opacity(0.2)
                            .frame(width: 180, height: 180)
                            .cornerRadius(8)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                )

                if entry.metadata.kept {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onDoubleTap() }
        )
        .contextMenu {
            Button(entry.metadata.kept ? "Unkeep" : "Keep") {
                onContextAction(.toggleKept)
            }
            Divider()
            Button("Show details") { onContextAction(.showDetail) }
            Button("Reuse settings") { onContextAction(.reuseSettings) }
            Button("Use in chat") { onContextAction(.useInChat) }
            Button("Reveal in Finder") { onContextAction(.reveal) }
            Divider()
            Button("Move to Trash", role: .destructive) {
                onContextAction(.delete)
            }
        }
        .help(entry.metadata.prompt)
    }
}

/// Sheet shown when the user double-clicks (or chooses "Show details")
/// a gallery cell. Bigger preview + sidecar metadata + the same actions
/// as the context menu, plus a Close button.
struct GalleryDetailSheet: View {
    let vm: ChatViewModel
    let entry: SDGalleryEntry
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Image details").font(.headline)
                Spacer()
                if entry.metadata.kept {
                    Label("Kept", systemImage: "heart.fill").foregroundStyle(.red)
                }
            }

            if let img = NSImage(contentsOf: entry.imageURL) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 540, maxHeight: 420)
                    .cornerRadius(8)
            }

            metadataGrid

            HStack {
                Button(entry.metadata.kept ? "Unkeep" : "Keep") {
                    vm.setKept(entry, kept: !entry.metadata.kept)
                    onClose()
                }
                Button("Reuse settings") {
                    vm.reuseGalleryEntrySettings(entry)
                    onClose()
                }
                Button("Use in chat") {
                    vm.useGalleryEntryInChat(entry)
                    onClose()
                }
                Button("Reveal") { vm.revealGalleryEntryInFinder(entry) }
                Spacer()
                Button("Move to Trash", role: .destructive) {
                    vm.deleteGalleryEntry(entry)
                    onClose()
                }
                Button("Close") { onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    @ViewBuilder
    private var metadataGrid: some View {
        let m = entry.metadata
        VStack(alignment: .leading, spacing: 4) {
            row("Prompt", m.prompt)
            if !m.negativePrompt.isEmpty {
                row("Negative", m.negativePrompt)
            }
            if m.width > 0 {
                row("Size", "\(m.width) × \(m.height)")
            }
            if m.steps > 0 {
                row("Steps / CFG", "\(m.steps) · \(String(format: "%.1f", m.cfgScale))")
            }
            if !m.sampler.isEmpty {
                row("Sampler / Seed", "\(m.sampler) · \(m.seed)")
            }
            if !m.modelPath.isEmpty {
                row("Model", (m.modelPath as NSString).lastPathComponent)
            }
        }
        .font(.caption.monospaced())
    }

    @ViewBuilder
    private func row(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.tail)
            Spacer()
        }
    }
}

/// Scene wrapper. Registered alongside the main `WindowGroup` in
/// `InferApp.body`; opened by `openWindow(id: "gallery")`. The window
/// id is referenced by string in `InferApp.swift` — keep `galleryWindowID`
/// the only source of truth.
let galleryWindowID = "gallery"

/// Menu item for "Window > Show Gallery" — needs to live in a `View`
/// because `@Environment(\.openWindow)` only resolves inside the view
/// hierarchy. `CommandGroup` accepts views via its result builder, so
/// inserting `GalleryMenuItem()` into `.commands` works the same as
/// any inline `Button`.
struct GalleryMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Gallery") {
            openWindow(id: galleryWindowID)
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])
    }
}

extension SDGalleryEntry {
    // SDGalleryEntry already has `id: URL` from Identifiable. Re-stating
    // here is redundant; sheet(item:) needs Identifiable conformance,
    // which it already has.
}
