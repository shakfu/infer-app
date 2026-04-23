import SwiftUI
import AppKit
import InferAgents

extension SidebarView {
    /// Agents tab: read-only library of all known agents, grouped by
    /// source, with per-row actions to activate, and global actions to
    /// reload from disk and reveal the user agents folder. Not a form
    /// editor — authoring happens in JSON files in the user folder.
    var agentsLibrarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(icon: "person.crop.circle", title: "Agents")

            HStack(spacing: 8) {
                Button { vm.revealUserAgentsFolder() } label: {
                    Label("Reveal folder", systemImage: "folder")
                }
                .controlSize(.small)

                Button { vm.reloadAgents() } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Re-scan the user agents folder and rebuild the listings.")

                Spacer()
            }

            let defaultAgent = vm.availableAgents.first { $0.isDefault }
            let userAgents = vm.availableAgents.filter {
                $0.source == .user && !$0.isDefault
            }
            let pluginAgents = vm.availableAgents.filter {
                $0.source == .plugin && !$0.isDefault
            }
            let firstPartyAgents = vm.availableAgents.filter {
                $0.source == .firstParty && !$0.isDefault
            }

            if let defaultAgent {
                LibraryGroup(title: "Built-in") {
                    LibraryRow(
                        vm: vm,
                        listing: defaultAgent,
                        canDuplicate: true
                    )
                }
            }

            if !firstPartyAgents.isEmpty {
                LibraryGroup(title: "First-party personas") {
                    ForEach(firstPartyAgents) { listing in
                        LibraryRow(vm: vm, listing: listing, canDuplicate: true)
                    }
                }
            }

            if !pluginAgents.isEmpty {
                LibraryGroup(title: "Plugin-shipped") {
                    ForEach(pluginAgents) { listing in
                        LibraryRow(vm: vm, listing: listing, canDuplicate: true)
                    }
                }
            }

            if userAgents.isEmpty {
                LibraryGroup(title: "User") {
                    Text("No user agents yet. Duplicate any built-in above, or drop a JSON file in the user folder.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                LibraryGroup(title: "User") {
                    ForEach(userAgents) { listing in
                        LibraryRow(vm: vm, listing: listing, canDuplicate: false)
                    }
                }
            }
        }
    }
}

private struct LibraryGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct LibraryRow: View {
    let vm: ChatViewModel
    let listing: AgentListing
    /// True for rows with a duplicatable backing (Default — synthesised
    /// from settings; first-party and plugin personas — copied from
    /// their JSON). User rows are already user rows; duplicating them
    /// makes less sense, so we hide the button.
    let canDuplicate: Bool

    var isActive: Bool { listing.id == vm.activeAgentId }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(listing.name)
                    .font(.callout)
                if isActive {
                    Text("active")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.12))
                        )
                }
                Spacer()
                Menu {
                    Button("Set as active") {
                        vm.switchAgent(to: listing)
                    }
                    .disabled(isActive || !vm.isCompatible(listing))

                    if canDuplicate {
                        Button("Duplicate as user agent") {
                            Task { await vm.duplicatePersona(listing) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if !listing.description.isEmpty {
                Text(listing.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                MetaLabel(key: "backend", value: listing.backend.rawValue)
                if let fam = listing.templateFamily {
                    MetaLabel(key: "template", value: fam.rawValue)
                }
                if !vm.isCompatible(listing) {
                    Text(vm.incompatibilityReason(listing))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(isActive ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isActive
                        ? Color.accentColor.opacity(0.3)
                        : Color.secondary.opacity(0.15)
                )
        )
    }
}

private struct MetaLabel: View {
    let key: String
    let value: String

    var body: some View {
        Text("\(key): \(value)")
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
    }
}
