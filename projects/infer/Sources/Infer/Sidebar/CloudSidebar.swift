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
