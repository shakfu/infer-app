import SwiftUI
import InferCore

/// Sampling and prompt knobs that drive the next decode. Migrated
/// from the sidebar's Model tab in P3 — the sidebar's Model tab
/// keeps the *picker* (backend, model selection, GGUF directory) but
/// loses the parameters card. Same draft + Apply pattern as the
/// remaining sidebar settings: editing a slider doesn't take effect
/// until you click Apply, since `vm.applySettings` is what propagates
/// the new sampling config to the runners.
struct ModelParametersSettingsView: View {
    @Bindable var vm: ChatViewModel
    @State private var draft: InferSettings = .defaults
    @State private var didSeed = false
    @State private var showSystemPrompt = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()

                ParamRow(label: "Temperature",
                         value: String(format: "%.2f", draft.temperature)) {
                    Slider(value: $draft.temperature, in: 0...2, step: 0.05)
                }

                ParamRow(label: "Top P",
                         value: String(format: "%.2f", draft.topP)) {
                    Slider(value: $draft.topP, in: 0...1, step: 0.01)
                }

                ParamRow(label: "Max tokens",
                         value: "\(draft.maxTokens)") {
                    Slider(
                        value: Binding(
                            get: { Double(draft.maxTokens) },
                            set: { draft.maxTokens = Int($0) }
                        ),
                        in: 64...8192,
                        step: 64
                    )
                }

                ParamRow(label: "Thinking budget",
                         value: "\(draft.thinkingBudget)") {
                    Slider(
                        value: Binding(
                            get: { Double(draft.thinkingBudget) },
                            set: { draft.thinkingBudget = Int($0) }
                        ),
                        in: 0...16384,
                        step: 256
                    )
                }
                .help("Extra tokens allowed for `<think>…</think>` reasoning on top of Max tokens. Reasoning models (Qwen-3, DeepSeek-R1) need headroom here; non-reasoning models ignore it. 0 disables the allowance — thinking then counts against Max tokens.")

                seedRow

                DisclosureGroup(isExpanded: $showSystemPrompt) {
                    TextEditor(text: $draft.systemPrompt)
                        .font(.body)
                        .frame(minHeight: 70, maxHeight: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.3))
                        )
                    Text("Applying a change resets the conversation.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } label: {
                    Text("System prompt").font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Reset") { draft = .defaults }
                        .controlSize(.small)
                    Spacer()
                    Button("Apply") { vm.applySettings(draft) }
                        .controlSize(.small)
                        .disabled(draftMatchesCurrent)
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
        .onAppear {
            if !didSeed {
                draft = vm.settings
                didSeed = true
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Model parameters")
                .font(.title3.weight(.semibold))
            Text("Sampling and prompt knobs that drive the next decode. Changes take effect when you click Apply.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var seedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Seed").font(.caption)
                Spacer()
                if draft.seed == nil {
                    Text("random").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 6) {
                TextField("random", text: Binding(
                    get: { draft.seed.map(String.init) ?? "" },
                    set: { s in
                        let trimmed = s.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            draft.seed = nil
                        } else if let v = UInt64(trimmed) {
                            draft.seed = v
                        }
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .font(.caption.monospacedDigit())

                Button("Random") { draft.seed = UInt64.random(in: 0...UInt64.max) }
                    .controlSize(.small)
                    .help("Generate a new fixed seed")
                Button("Clear") { draft.seed = nil }
                    .controlSize(.small)
                    .disabled(draft.seed == nil)
                    .help("Use a fresh random seed for each generation")
            }
            Text("Set a seed to get identical output for the same prompt + params.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var draftMatchesCurrent: Bool {
        let s = vm.settings
        return s.systemPrompt == draft.systemPrompt
            && s.temperature == draft.temperature
            && s.topP == draft.topP
            && s.maxTokens == draft.maxTokens
            && s.thinkingBudget == draft.thinkingBudget
            && s.seed == draft.seed
    }
}
