import SwiftUI
import AppKit

extension ChatView {
    var header: some View {
        HStack(spacing: 12) {
            statusView
            WorkspacePickerMenu(vm: vm)
            AgentPickerMenu(vm: vm, sidebarOpen: $sidebarOpen)
            generationRateView
            contextPercentView

            Spacer()

            Button("Reset") { vm.reset() }
                .disabled(vm.messages.isEmpty && !vm.isGenerating)

            Button {
                // Same Settings window the menu's "Settings…" item
                // (Cmd-,) opens — see the `Settings { SettingsView ... }`
                // scene in `InferApp.swift`. The `\.openSettings`
                // environment action is the macOS-14+ canonical entry
                // point; sending `showSettingsWindow:` via the
                // responder chain was unreliable in practice (the
                // Settings scene's window controller isn't on the
                // chain until first use).
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings… (⌘,)")

            Button {
                sidebarOpen.toggle()
            } label: {
                Image(systemName: sidebarOpen ? "sidebar.right" : "sidebar.squares.right")
            }
            .help(sidebarOpen ? "Hide sidebar" : "Show sidebar")
        }
        .padding(10)
    }

    @ViewBuilder
    var generationRateView: some View {
        if let stats = vm.generationStats {
            // Reasoning models inflate `tokens` (total decoded) above
            // `net` (what landed in the rendered reply). When they
            // differ — which happens whenever a model emitted
            // <think>…</think> blocks — the header shows both so the
            // discrepancy between "felt like a short reply" and
            // "took 30 seconds" is legible. Otherwise the compact
            // single-count format stays.
            let showSplit = stats.net > 0 && stats.net < stats.tokens
            let body: String = showSplit
                ? "\(stats.net) net · \(stats.tokens) gen · \(String(format: "%.1f", stats.tps)) tok/s"
                : "\(stats.tokens) tok · \(String(format: "%.1f", stats.tps)) tok/s"
            let tip: String = showSplit
                ? "\(stats.net) net tokens (rendered reply) · \(stats.tokens) total tokens decoded · \(String(format: "%.1f", stats.tps)) tok/s. Reasoning models emit `<think>…</think>` blocks that count against decode time and the context window but are hidden from the reply."
                : (vm.isGenerating ? "Generation in progress" : "Last generation stats")
            Text(body)
                .font(.caption.monospacedDigit())
                .foregroundStyle(vm.isGenerating ? SwiftUI.Color.accentColor : SwiftUI.Color.secondary)
                .help(tip)
        }
    }

    /// Context-window usage as a percentage. Sits to the right of
    /// the per-generation tok/s readout. Compact on purpose — the
    /// tooltip carries the raw used/total numbers for users who
    /// want them. Only renders when the backend exposes a real
    /// context size: llama has it via `llama_n_ctx`; MLX doesn't,
    /// so this stays absent there (consistent with the rest of the
    /// MLX header). Tinted orange at >80% and red at >95% to
    /// telegraph "you're approaching context exhaustion" without
    /// the user having to read the number.
    @ViewBuilder
    var contextPercentView: some View {
        if let usage = vm.tokenUsage, let total = usage.total, total > 0 {
            let ratio = min(1.0, Double(usage.used) / Double(total))
            let pct = Int((ratio * 100).rounded())
            let tint: SwiftUI.Color = ratio > 0.95
                ? .red
                : (ratio > 0.80 ? .orange : .secondary)
            Text("\(pct)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(tint)
                .help("Context: \(usage.used) / \(total) tokens used")
        }
    }

    @ViewBuilder
    var statusView: some View {
        if vm.isLoadingModel {
            HStack(spacing: 6) {
                if let p = vm.downloadProgress {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                    Text("\(Int(p * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(vm.modelStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            Text(vm.modelStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
