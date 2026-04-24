import SwiftUI

extension ChatView {
    var header: some View {
        HStack(spacing: 12) {
            statusView
            WorkspacePickerMenu(vm: vm)
            AgentPickerMenu(vm: vm, sidebarOpen: $sidebarOpen)
            tokenIndicator
            generationRateView

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

    @ViewBuilder
    var tokenIndicator: some View {
        if let usage = vm.tokenUsage {
            if let total = usage.total, total > 0 {
                let ratio = min(1.0, Double(usage.used) / Double(total))
                let tint: SwiftUI.Color = ratio > 0.95 ? .red : (ratio > 0.80 ? .orange : .accentColor)
                HStack(spacing: 6) {
                    ProgressView(value: ratio)
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .frame(width: 80)
                    Text("\(usage.used) / \(total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .help("Context window: \(usage.used) of \(total) tokens used")
            } else {
                Text("~\(usage.used) tok")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Approximate token count (backend does not expose context size)")
            }
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
