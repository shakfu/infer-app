import SwiftUI

/// Sidebar subsection that the user can collapse, with state persisted
/// across launches via `@AppStorage`. Visually identical to a plain
/// `SectionHeader` plus a leading disclosure chevron rendered by
/// `DisclosureGroup`. Use this for *secondary* sections users may want
/// to hide once configured (Voice's file-transcription panel, the Image
/// tab's recent gallery, etc.). Keep the *primary* control of a tab as
/// a plain `SectionHeader` — folding the model picker on the Model tab
/// would hide the main control and leave the tab pointless when
/// collapsed.
///
/// Convention for `storageKey`: `sidebar.fold.<tab>.<section>` so a
/// future audit can `defaults read com.example.infer | grep sidebar.fold`
/// to see what's collapsed where. Keys are stable strings (not derived
/// from the title) so renaming the section header doesn't reset the
/// user's collapsed state.
struct FoldableSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var content: () -> Content
    @AppStorage var expanded: Bool

    init(
        icon: String,
        title: String,
        storageKey: String,
        defaultExpanded: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.content = content
        self._expanded = AppStorage(wrappedValue: defaultExpanded, storageKey)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            content()
                .padding(.top, 4)
        } label: {
            SectionHeader(icon: icon, title: title)
        }
    }
}

struct SectionHeader: View {
    let icon: String
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
        }
    }
}

struct ParamRow<Control: View>: View {
    let label: String
    let value: String
    /// Optional badge / accessory rendered between the label and the
    /// value text — used by the per-workspace overrides feature to
    /// surface a "↺ Default" button when the active workspace is
    /// overriding this field. Defaults to nothing so the existing
    /// call sites compose unchanged.
    var accessory: AnyView? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                if let accessory {
                    accessory
                }
                Spacer()
                Text(value)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            control()
        }
    }
}

/// "↺ Default" button rendered next to a Parameters field when the
/// active workspace is overriding that field. Clearing the override
/// fires `vm.clearWorkspaceParamOverride(field)` which recomposes
/// effective settings from Default's row; the sidebar's
/// `.onChange(of: vm.settings)` handler then snaps the local draft
/// back into sync.
///
/// Renders nothing — and takes no space — when (a) no workspace is
/// active yet (boot-time edge case before `refreshWorkspaces`
/// finishes), (b) the active workspace IS the Default workspace
/// (Default's row IS the global floor; there is nothing to fall back
/// to), or (c) the active workspace's column for `field` is `NULL`
/// (already inheriting). Keeps the chrome out of the user's way
/// 99% of the time.
struct WorkspaceOverrideClearButton: View {
    let field: ChatViewModel.WorkspaceParamField
    var vm: ChatViewModel

    var body: some View {
        if shouldRender {
            Button {
                vm.clearWorkspaceParamOverride(field)
            } label: {
                Label("Default", systemImage: "arrow.uturn.backward")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .foregroundStyle(.secondary)
            .help("Clear this workspace's override for this field; falls back to the Default workspace's value.")
        }
    }

    private var shouldRender: Bool {
        guard let activeId = vm.activeWorkspaceId else { return false }
        if vm.isDefaultWorkspace(activeId) { return false }
        return vm.activeWorkspaceOverrides(field)
    }
}
