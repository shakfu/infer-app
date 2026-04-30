import SwiftUI
import InferCore

/// Cloud-backend configuration rows + key entry sheet. Lives next to
/// `SidebarSections.swift`'s `modelSection` and is composed in via the
/// `vm.backend == .cloud` branch there. Kept in its own file because the
/// cloud surface (provider picker, compat name + URL, hybrid model field,
/// keychain status) is conceptually distinct from the local-model load
/// flow and would crowd `SidebarSections.swift` further.
extension SidebarView {
    /// Per-provider model id binding. Reads/writes the right slot on
    /// `vm` based on the active `cloudProviderKind` so SwiftUI keeps each
    /// provider's last-used model independent.
    private var cloudActiveModelBinding: Binding<String> {
        Binding(
            get: {
                switch vm.cloudProviderKind {
                case .openai: return vm.cloudOpenAIModel
                case .anthropic: return vm.cloudAnthropicModel
                case .openaiCompatible: return vm.cloudCompatModel
                }
            },
            set: { newValue in
                switch vm.cloudProviderKind {
                case .openai: vm.cloudOpenAIModel = newValue
                case .anthropic: vm.cloudAnthropicModel = newValue
                case .openaiCompatible: vm.cloudCompatModel = newValue
                }
            }
        )
    }

    @ViewBuilder
    var cloudConfigRows: some View {
        Picker("Provider", selection: $vm.cloudProviderKind) {
            ForEach(CloudProviderKind.allCases) { kind in
                Text(kind.label).tag(kind)
            }
        }
        .pickerStyle(.menu)
        .disabled(vm.isLoadingModel || vm.isGenerating)

        if vm.cloudProviderKind == .openaiCompatible {
            TextField("Endpoint name (e.g. Ollama)", text: $vm.cloudCompatName)
                .textFieldStyle(.roundedBorder)
                .disabled(vm.isLoadingModel || vm.isGenerating)
            TextField("Endpoint URL (https:// or http://localhost…)", text: $vm.cloudCompatURL)
                .textFieldStyle(.roundedBorder)
                .disabled(vm.isLoadingModel || vm.isGenerating)
                .help("Loopback HTTP allowed for local runtimes (Ollama, LM Studio); remote endpoints must use https.")
        }

        HStack(spacing: 4) {
            TextField("Model id", text: cloudActiveModelBinding)
                .textFieldStyle(.roundedBorder)
                .disabled(vm.isLoadingModel || vm.isGenerating)
                .onSubmit { vm.loadCurrentBackend() }
            let suggestions = recommendedModelsForCurrentProvider()
            if !suggestions.isEmpty {
                Menu {
                    ForEach(suggestions, id: \.self) { id in
                        Button(id) { cloudActiveModelBinding.wrappedValue = id }
                    }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Recommended models for \(vm.cloudProviderKind.label)")
            }
        }

        cloudKeyStatusRow

        HStack(spacing: 6) {
            if vm.isLoadingModel {
                Button(role: .cancel) { vm.cancelLoad() } label: {
                    Label("Cancel", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
            } else {
                Button {
                    vm.loadCurrentBackend()
                } label: {
                    Label("Load", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .disabled(vm.isGenerating)
                Button {
                    showingCloudKeySheet = true
                } label: {
                    Label("Set Key…", systemImage: "key")
                }
                .disabled(vm.isGenerating)
            }
        }
        .buttonStyle(.bordered)
    }

    /// Resolved-key status. Reads the keychain + env var on every render
    /// — both are cheap operations (a single `SecItemCopyMatching` and a
    /// dictionary lookup) and the sidebar isn't a hot path. Re-evaluates
    /// when the user finishes the Set Key sheet because `showingCloudKeySheet`
    /// flips and triggers a render.
    @ViewBuilder
    private var cloudKeyStatusRow: some View {
        let status = currentCloudKeyStatus()
        HStack(spacing: 4) {
            Image(systemName: status.icon)
                .foregroundStyle(status.tint)
                .font(.caption)
            Text(status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
    }

    private struct KeyStatus {
        let icon: String
        let label: String
        let tint: Color
    }

    private func currentCloudKeyStatus() -> KeyStatus {
        guard let provider = vm.makeCloudProvider() else {
            return KeyStatus(
                icon: "exclamationmark.circle",
                label: "Configure endpoint",
                tint: .orange
            )
        }
        if let resolved = APIKeyStore.resolve(for: provider) {
            switch resolved.source {
            case .keychain:
                return KeyStatus(icon: "checkmark.circle", label: "Key in keychain", tint: .green)
            case .envVar:
                return KeyStatus(
                    icon: "checkmark.circle",
                    label: "Key from \(provider.envVarName ?? "env")",
                    tint: .yellow
                )
            }
        }
        return KeyStatus(icon: "exclamationmark.circle", label: "No API key set", tint: .orange)
    }

    private func recommendedModelsForCurrentProvider() -> [String] {
        switch vm.cloudProviderKind {
        case .openai: return CloudRecommendedModels.openai
        case .anthropic: return CloudRecommendedModels.anthropic
        case .openaiCompatible: return []
        }
    }

    // MARK: Cloud parameters

    /// Provider-specific generation knobs not in the universal Parameters
    /// card. Lives here (not in `parametersSection`) because every control
    /// is wire-only: it ships in the request body if non-default, and is
    /// silently ignored otherwise. Rendered conditionally — the user only
    /// sees the controls relevant to the active provider.
    @ViewBuilder
    var cloudParamsSection: some View {
        DisclosureGroup(isExpanded: $showCloudParams) {
            VStack(alignment: .leading, spacing: 10) {
                stopSequencesRow

                switch vm.cloudProviderKind {
                case .openai, .openaiCompatible:
                    openAICloudParamRows
                case .anthropic:
                    anthropicCloudParamRows
                }
            }
            .padding(.top, 6)
        } label: {
            SectionHeader(icon: "cloud", title: "Cloud parameters")
        }
    }

    @ViewBuilder
    private var stopSequencesRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stop sequences")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { draft.stopSequences.joined(separator: "\n") },
                set: { s in
                    draft.stopSequences = s
                        .split(separator: "\n", omittingEmptySubsequences: false)
                        .map(String.init)
                        .filter { !$0.isEmpty }
                }
            ))
            .font(.caption.monospaced())
            .frame(minHeight: 50, maxHeight: 90)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.3))
            )
            Text("One per line. OpenAI accepts up to 4 (extras dropped).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var openAICloudParamRows: some View {
        // Reasoning effort. The picker shows "Default" for nil, then the
        // enum cases. Only o-series and gpt-5.x honour this — surfaced in
        // help text rather than gated by model id, so users picking the
        // model id later see the prior selection persist.
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Reasoning effort").font(.caption)
                Spacer()
                Picker("", selection: Binding(
                    get: { draft.reasoningEffort?.rawValue ?? "" },
                    set: { raw in
                        draft.reasoningEffort = raw.isEmpty
                            ? nil
                            : CloudGenerationParams.ReasoningEffort(rawValue: raw)
                    }
                )) {
                    Text("Default").tag("")
                    ForEach(CloudGenerationParams.ReasoningEffort.allCases, id: \.rawValue) { v in
                        Text(v.rawValue.capitalized).tag(v.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            Text("o-series and gpt-5 only — other models ignore this.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }

        // Verbosity. Same shape; gpt-5 only.
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Verbosity").font(.caption)
                Spacer()
                Picker("", selection: Binding(
                    get: { draft.verbosity?.rawValue ?? "" },
                    set: { raw in
                        draft.verbosity = raw.isEmpty
                            ? nil
                            : CloudGenerationParams.Verbosity(rawValue: raw)
                    }
                )) {
                    Text("Default").tag("")
                    ForEach(CloudGenerationParams.Verbosity.allCases, id: \.rawValue) { v in
                        Text(v.rawValue.capitalized).tag(v.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            Text("gpt-5 family only.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }

        penaltyRow(
            label: "Frequency penalty",
            help: "Negative encourages repetition; positive discourages it. Range -2…2.",
            value: $draft.frequencyPenalty
        )
        penaltyRow(
            label: "Presence penalty",
            help: "Pushes toward (-) or away from (+) topics already mentioned. Range -2…2.",
            value: $draft.presencePenalty
        )

        VStack(alignment: .leading, spacing: 4) {
            Text("Prompt cache key").font(.caption).foregroundStyle(.secondary)
            TextField("optional opaque tag", text: Binding(
                get: { draft.promptCacheKey ?? "" },
                set: { s in
                    let trimmed = s.trimmingCharacters(in: .whitespaces)
                    draft.promptCacheKey = trimmed.isEmpty ? nil : trimmed
                }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            Text("OpenAI hint that this turn shares a cacheable prefix with prior turns of the same key.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }

        serviceTierRow(
            placeholder: "auto | default | flex | scale | priority"
        )
    }

    @ViewBuilder
    private var anthropicCloudParamRows: some View {
        Toggle("Cache system prompt", isOn: $draft.anthropicPromptCaching)
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Tag the system prompt as ephemeral so the cached billing rate applies. Most useful for long, stable system prompts you re-send each turn.")

        Toggle("Extended thinking", isOn: $draft.cloudExtendedThinkingEnabled)
            .toggleStyle(.switch)
            .controlSize(.small)
            .help("Enable Anthropic's extended-thinking mode. Uses 'Thinking budget' from the Parameters card as the budget. Forces temperature to 1.0 — the API rejects other values combined with thinking.")
        if draft.cloudExtendedThinkingEnabled, draft.thinkingBudget <= 0 {
            Text("Set Thinking budget > 0 above for this to take effect.")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        serviceTierRow(placeholder: "auto | standard_only")
    }

    /// Optional Double slider with a "use default" / clear button. Used
    /// for `frequency_penalty` and `presence_penalty` — both nil-when-omitted
    /// so we can't bind a plain slider directly.
    @ViewBuilder
    private func penaltyRow(
        label: String,
        help: String,
        value: Binding<Double?>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                if let v = value.wrappedValue {
                    Text(String(format: "%.2f", v))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Clear") { value.wrappedValue = nil }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                } else {
                    Text("default").font(.caption2).foregroundStyle(.tertiary)
                    Button("Set") { value.wrappedValue = 0.0 }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                }
            }
            if value.wrappedValue != nil {
                Slider(
                    value: Binding(
                        get: { value.wrappedValue ?? 0 },
                        set: { value.wrappedValue = $0 }
                    ),
                    in: -2...2,
                    step: 0.05
                )
            }
            Text(help)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Service tier free-form field. Both providers accept the param but
    /// with disjoint enum values — a free-text field with a placeholder is
    /// less misleading than a unified picker.
    @ViewBuilder
    private func serviceTierRow(placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Service tier").font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: Binding(
                get: { draft.serviceTier ?? "" },
                set: { s in
                    let trimmed = s.trimmingCharacters(in: .whitespaces)
                    draft.serviceTier = trimmed.isEmpty ? nil : trimmed
                }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            Text("Empty = provider default.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Modal sheet for entering / clearing the API key for the active cloud
/// provider. Saves to `APIKeyStore` (keychain) on Save; Clear deletes the
/// item. Env-var fallback is reflected on dismiss via the sidebar's
/// `cloudKeyStatusRow`.
struct CloudKeySheet: View {
    let vm: ChatViewModel
    @Binding var isPresented: Bool
    @State private var keyInput: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("API Key — \(providerDisplayName)")
                .font(.headline)
            Text("Stored in your macOS keychain, scoped to this app's signature. Not synced via iCloud.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Paste API key", text: $keyInput)
                .textFieldStyle(.roundedBorder)

            if let env = currentProvider?.envVarName {
                Text("Tip: leave blank and set \(env) in your shell to use an env var instead.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if currentProvider.map({ APIKeyStore.hasKey(for: $0) }) == true {
                    Button("Clear", role: .destructive) {
                        if let p = currentProvider {
                            APIKeyStore.clear(for: p)
                        }
                        isPresented = false
                    }
                }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var currentProvider: CloudProvider? {
        vm.makeCloudProvider()
    }

    private var providerDisplayName: String {
        currentProvider?.displayName ?? vm.cloudProviderKind.label
    }

    private func save() {
        guard let provider = currentProvider else {
            errorMessage = "Configure provider/endpoint first."
            return
        }
        let trimmed = keyInput.trimmingCharacters(in: .whitespaces)
        do {
            try APIKeyStore.set(trimmed, for: provider)
            keyInput = ""
            errorMessage = nil
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
