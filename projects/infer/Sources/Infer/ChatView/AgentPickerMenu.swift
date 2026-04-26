import SwiftUI
import InferAgents
import InferCore

/// Header affordance that shows the active agent and offers a one-click
/// switch to any compatible agent. Incompatible agents appear greyed out
/// with a subtitle explaining why. A "Manage agents…" entry at the
/// bottom opens the sidebar on the Agents tab for full inspection /
/// duplication.
///
/// Intentionally lightweight: no sheets, no popovers. macOS renders it
/// as a native menu button so the picker is dismissible with `Esc` and
/// navigable with the keyboard without extra code.
struct AgentPickerMenu: View {
    let vm: ChatViewModel
    /// Sidebar-open binding owned by `ChatView`. Tapping "Manage agents…"
    /// flips it true so the sidebar is visible when we switch tabs.
    @Binding var sidebarOpen: Bool
    /// Persisted sidebar tab selection. Written to route into the Agents
    /// tab from the "Manage agents…" menu item.
    @AppStorage(PersistKey.sidebarTab) private var tabRaw: String = SidebarTab.model.rawValue

    var body: some View {
        Menu {
            let listings = vm.availableAgents
            let compatible = listings.filter { vm.isCompatible($0) }
            let incompatible = listings.filter { !vm.isCompatible($0) }
            // Default row is a persona-shaped synthetic; pin it to the
            // top of the Personas section.
            let personas = compatible.filter { $0.kind == .persona }
            let agents = compatible.filter { $0.kind == .agent }

            if !personas.isEmpty {
                Section("Personas") {
                    ForEach(personas) { listing in
                        menuItem(for: listing, compatible: true)
                    }
                }
            }

            if !agents.isEmpty {
                Section("Agents") {
                    ForEach(agents) { listing in
                        menuItem(for: listing, compatible: true)
                    }
                }
            }

            if !incompatible.isEmpty {
                Section("Incompatible") {
                    ForEach(incompatible) { listing in
                        menuItem(for: listing, compatible: false)
                    }
                }
            }

            Divider()
            Button("Manage agents…") {
                tabRaw = SidebarTab.agents.rawValue
                sidebarOpen = true
            }
        } label: {
            label
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(tooltip)
    }

    // MARK: - Label

    @ViewBuilder
    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(activeName)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if vm.activeToolCount > 0 {
                Text("tools: \(vm.activeToolCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.12))
                    )
            }
        }
    }

    // MARK: - Menu item

    @ViewBuilder
    private func menuItem(for listing: AgentListing, compatible: Bool) -> some View {
        let isActive = listing.id == vm.activeAgentId
        Button {
            guard compatible, !isActive else { return }
            vm.switchAgent(to: listing)
        } label: {
            if isActive {
                Label(listing.name, systemImage: "checkmark")
            } else if !compatible {
                let reason = vm.incompatibilityReason(listing)
                Text(reason.isEmpty ? listing.name : "\(listing.name) — \(reason)")
            } else {
                Text(listing.name)
            }
        }
        .disabled(!compatible || isActive)
    }

    // MARK: - Helpers

    private var activeName: String {
        if let listing = vm.activeAgentListing { return listing.name }
        return "Default"
    }

    private var tooltip: String {
        let name = activeName
        let count = vm.activeToolCount
        if count == 0 { return "Active agent: \(name)" }
        return "Active agent: \(name) · \(count) tool\(count == 1 ? "" : "s")"
    }
}
