import SwiftUI
import AppKit
import InferAgents

/// MCP server management UI rendered inside the Agents tab. The
/// rest of the agent / persona library lives in
/// `AgentsLibrarySection.swift`; this section handles everything
/// MCP-shaped (server status, approve / revoke, advertised roots,
/// discovered tools).
///
/// Read-only with respect to the config files themselves — users
/// still author `*.json` configs in `~/Library/Application Support/
/// Infer/mcp/` directly, the same way personas / agents work
/// elsewhere in this tab. The UI's job is to (a) make the consent
/// gate usable without dropping to `defaults write`, and (b) surface
/// what each server is doing once it's running.
struct MCPServersSection: View {
    @Bindable var vm: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(icon: "network", title: "MCP servers")

            HStack(spacing: 8) {
                Button { vm.revealMCPFolder() } label: {
                    Label("Reveal folder", systemImage: "folder")
                }
                .controlSize(.small)
                .help("Open the MCP config folder. Drop a *.json file here per server.")

                Button {
                    Task { await vm.reloadMCPServers() }
                } label: {
                    if vm.mcpReloading {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("Reloading…")
                        }
                    } else {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                }
                .controlSize(.small)
                .disabled(vm.mcpReloading)
                .help("Re-scan the MCP folder, restart approved servers, refresh the tool catalog.")

                Spacer()
            }

            if !vm.mcpDiagnostics.isEmpty {
                MCPDiagnosticsBanner(diagnostics: vm.mcpDiagnostics)
            }

            if vm.mcpServers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No MCP servers configured. Drop a `<id>.json` file in the MCP folder describing a server (id, command, args). Servers must be approved before they launch — see the Reveal-folder button above.")
                    Text("Examples ready to copy: `docs/examples/mcp/{filesystem,github,sqlite}.json`. Schema reference: `docs/dev/mcp-config.md`.")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(vm.mcpServers) { server in
                    MCPServerRow(vm: vm, server: server)
                }
            }
        }
    }
}

private struct MCPServerRow: View {
    let vm: ChatViewModel
    let server: MCPServerSummary
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.body)
                    .foregroundStyle(statusColor)
                    .help(statusTooltip)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(server.displayName)
                            .font(.callout.weight(.medium))
                        Text(server.id)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Text(statusLabel)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                actionButton
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide details" : "Show details")
            }
            if expanded {
                detail
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.15))
        )
    }

    @ViewBuilder
    private var actionButton: some View {
        switch server.status {
        case .denied:
            Button {
                vm.approveMCPServer(id: server.id)
            } label: {
                Label("Approve", systemImage: "checkmark.shield")
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .help("Allow this server to launch and register its tools. Persists across restarts.")
        case .running:
            Button(role: .destructive) {
                vm.revokeMCPServer(id: server.id)
            } label: {
                Label("Revoke", systemImage: "xmark.shield")
            }
            .controlSize(.small)
            .help("Shut this server down and remove its tools from the catalog. The config file stays.")
        case .failed:
            Button {
                Task { await vm.reloadMCPServers() }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Re-attempt launch. Useful after fixing the config or installing a missing binary.")
        case .disabled:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 4) {
            DetailRow(label: "Command", value: server.command, monospaced: true)
            if server.autoApprove {
                DetailRow(
                    label: "Trust",
                    value: "autoApprove (config bypasses consent gate)"
                )
            }
            if !server.configRoots.isEmpty {
                DetailRow(
                    label: "Roots (config)",
                    value: server.configRoots.joined(separator: ", "),
                    monospaced: true
                )
            }
            if !server.advertisedRoots.isEmpty {
                DetailRow(
                    label: "Roots (sent)",
                    value: server.advertisedRoots.map(\.uri).joined(separator: ", "),
                    monospaced: true
                )
            }
            if case .failed(let message) = server.status {
                DetailRow(label: "Error", value: message)
            }
            if !server.tools.isEmpty {
                Text("Tools (\(server.tools.count))")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(server.tools, id: \.name) { tool in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("mcp.\(server.id).\(tool.name)")
                            .font(.caption.monospaced())
                        if let desc = tool.description, !desc.isEmpty {
                            Text(desc)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 8)
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Status presentation

    private var statusIcon: String {
        switch server.status {
        case .running: return "circle.fill"
        case .denied: return "lock.fill"
        case .disabled: return "pause.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .running: return .green
        case .denied: return .orange
        case .disabled: return .secondary
        case .failed: return .red
        }
    }

    private var statusLabel: String {
        switch server.status {
        case .running:
            let n = server.tools.count
            return "running · \(n) tool\(n == 1 ? "" : "s")"
        case .denied:
            return server.autoApprove
                ? "denied (autoApprove set but launch not retried)"
                : "needs approval"
        case .disabled:
            return "disabled in config"
        case .failed:
            return "failed"
        }
    }

    private var statusTooltip: String {
        switch server.status {
        case .running:
            return "Subprocess running and tools are registered as mcp.\(server.id).*"
        case .denied:
            return "Server config exists but has not been approved. Click Approve to launch."
        case .disabled:
            return "enabled:false in the config file. Edit the JSON and reload to enable."
        case .failed(let message):
            return message
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .trailing)
            Text(value)
                .font(monospaced ? .caption2.monospaced() : .caption2)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MCPDiagnosticsBanner: View {
    let diagnostics: [MCPLoadDiagnostic]
    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(diagnostics, id: \.serverID) { diag in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: severityIcon(diag.severity))
                            .font(.caption2)
                            .foregroundStyle(severityColor(diag.severity))
                        Text(diag.serverID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(diag.message)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("\(diagnostics.count) diagnostic\(diagnostics.count == 1 ? "" : "s") from MCP bootstrap")
                    .font(.caption)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.25))
        )
    }

    private func severityIcon(_ severity: MCPLoadDiagnostic.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon"
        case .warning: return "exclamationmark.triangle"
        case .skipped: return "minus.circle"
        }
    }

    private func severityColor(_ severity: MCPLoadDiagnostic.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .skipped: return .secondary
        }
    }
}
