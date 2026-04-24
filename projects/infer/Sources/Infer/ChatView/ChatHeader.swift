import SwiftUI

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
            Text("\(stats.tokens) tok · \(String(format: "%.1f", stats.tps)) tok/s")
                .font(.caption.monospacedDigit())
                .foregroundStyle(vm.isGenerating ? SwiftUI.Color.accentColor : SwiftUI.Color.secondary)
                .help(vm.isGenerating ? "Generation in progress" : "Last generation stats")
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
