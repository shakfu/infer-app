import SwiftUI
import AppKit
import InferAgents

extension SidebarView {
    /// Agents tab: read-only library of all known agents, grouped by
    /// source, with per-row actions to activate, and global actions to
    /// reload from disk and reveal the user agents folder. Not a form
    /// editor — authoring happens in JSON files in the user folder.
    var agentsLibrarySection: some View {
        AgentsLibraryBody(vm: vm)
    }
}

private struct AgentsLibraryBody: View {
    let vm: ChatViewModel
    @State private var search: String = ""

    var body: some View {
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

            if !vm.libraryDiagnostics.isEmpty {
                DiagnosticsBanner(diagnostics: vm.libraryDiagnostics)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Filter agents", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
            }

            let defaultAgent = vm.availableAgents.first { $0.isDefault }
            let userAgents = filter(
                vm.availableAgents.filter { $0.source == .user && !$0.isDefault }
            )
            let pluginAgents = filter(
                vm.availableAgents.filter { $0.source == .plugin && !$0.isDefault }
            )
            let firstPartyAgents = filter(
                vm.availableAgents.filter { $0.source == .firstParty && !$0.isDefault }
            )
            let defaultMatches = defaultAgent.map(matches) ?? false

            if let defaultAgent, defaultMatches {
                LibraryGroup(title: "Built-in") {
                    LibraryRow(
                        vm: vm,
                        listing: defaultAgent,
                        canDuplicate: true,
                        onInspect: { vm.inspectorListing = $0 }
                    )
                }
            }

            if !firstPartyAgents.isEmpty {
                LibraryGroup(title: "First-party personas") {
                    ForEach(firstPartyAgents) { listing in
                        LibraryRow(
                            vm: vm,
                            listing: listing,
                            canDuplicate: true,
                            onInspect: { vm.inspectorListing = $0 }
                        )
                    }
                }
            }

            if !pluginAgents.isEmpty {
                LibraryGroup(title: "Plugin-shipped") {
                    ForEach(pluginAgents) { listing in
                        LibraryRow(
                            vm: vm,
                            listing: listing,
                            canDuplicate: true,
                            onInspect: { vm.inspectorListing = $0 }
                        )
                    }
                }
            }

            let userGroupVisible = !userAgents.isEmpty || search.isEmpty
            if userGroupVisible {
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
                            LibraryRow(
                            vm: vm,
                            listing: listing,
                            canDuplicate: false,
                            onInspect: { vm.inspectorListing = $0 }
                        )
                        }
                    }
                }
            }

            if !search.isEmpty,
               !defaultMatches,
               firstPartyAgents.isEmpty,
               pluginAgents.isEmpty,
               userAgents.isEmpty {
                Text("No agents match \"\(search)\".")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Case-insensitive substring match across name, description, and
    /// source tag. Empty search returns the full list.
    private func filter(_ listings: [AgentListing]) -> [AgentListing] {
        listings.filter(matches)
    }

    private func matches(_ listing: AgentListing) -> Bool {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let haystack = [
            listing.name,
            listing.description,
            sourceTag(listing.source),
        ].joined(separator: " ")
        return haystack.range(of: q, options: .caseInsensitive) != nil
    }

    private func sourceTag(_ source: AgentSource) -> String {
        switch source {
        case .user: return "user"
        case .plugin: return "plugin"
        case .firstParty: return "first-party"
        }
    }
}

/// Dismissible disclosure at the top of the Agents tab listing persona
/// files that failed to load. Without this, malformed JSON is silently
/// skipped and the user has no way to know a file they edited is not
/// being picked up. The banner stays collapsed by default (per-file
/// reasons can be long) but shows the count in the header so it's not
/// easy to ignore.
private struct DiagnosticsBanner: View {
    let diagnostics: [AgentRegistry.PersonaLoadError]
    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(diagnostics, id: \.url) { diag in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(diag.url.lastPathComponent)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                            Spacer()
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([diag.url])
                            } label: {
                                Image(systemName: "folder")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .help("Reveal in Finder")
                        }
                        Text(diag.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("\(diagnostics.count) persona file\(diagnostics.count == 1 ? "" : "s") skipped")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.3))
        )
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
    /// Invoked with `listing` to open the inspector sheet. Owned by the
    /// library body so sheet presentation can live in one place.
    let onInspect: (AgentListing) -> Void

    @State private var confirmDelete: Bool = false
    @State private var hovering: Bool = false

    var isActive: Bool { listing.id == vm.activeAgentId }
    var isUserPersona: Bool {
        listing.source == .user && !listing.isDefault
    }
    var canActivate: Bool {
        !isActive && vm.isCompatible(listing)
    }

    /// Tooltip for the activation menu item. Surfaces the
    /// incompatibility reason so keyboard users and anyone hovering a
    /// disabled row understands *why* the action is unavailable, not
    /// just that it is.
    var activationHelp: String {
        if isActive { return "This agent is already active." }
        if !vm.isCompatible(listing) {
            let reason = vm.incompatibilityReason(listing)
            return reason.isEmpty ? "Not compatible with the current backend." : reason
        }
        return "Switch the current conversation to this agent."
    }

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
                    Button("View details…") {
                        onInspect(listing)
                    }
                    Divider()
                    Button("Set as active") {
                        vm.switchAgent(to: listing)
                    }
                    .disabled(!canActivate)
                    .help(activationHelp)

                    if canDuplicate {
                        Button("Duplicate as user agent") {
                            Task { await vm.duplicatePersona(listing) }
                        }
                    }

                    if isUserPersona {
                        if let url = vm.userPersonaURL(for: listing.id) {
                            Button("Reveal JSON in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                            Button("Edit JSON…") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Text("Move to Trash…")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(activationHelp)
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
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isActive
                        ? Color.accentColor.opacity(0.3)
                        : Color.secondary.opacity(0.15)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if canActivate {
                vm.switchAgent(to: listing)
            } else if !isActive {
                // Incompatible or otherwise un-activatable — open the
                // inspector so the user can see *why* instead of the
                // click silently no-oping.
                onInspect(listing)
            }
        }
        .onHover { hovering = $0 }
        .help(activationHelp)
        .alert(
            "Move \"\(listing.name)\" to Trash?",
            isPresented: $confirmDelete,
            actions: {
                Button("Move to Trash", role: .destructive) {
                    vm.deleteUserPersona(listing)
                }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("The JSON file will be moved to the system Trash. You can restore it from there.")
            }
        )
    }

    /// Row background. Subtle hover tint so users discover the click-to-
    /// activate affordance, without turning the row into a loud button.
    private var rowFill: Color {
        if isActive { return Color.secondary.opacity(0.08) }
        if hovering && canActivate { return Color.accentColor.opacity(0.08) }
        return Color.secondary.opacity(0.04)
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
