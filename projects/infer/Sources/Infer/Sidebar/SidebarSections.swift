import SwiftUI
import AppKit
import InferAgents
import InferCore

extension SidebarView {
    // MARK: History

    var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search conversations", text: Binding(
                get: { vm.vaultQuery },
                set: { vm.vaultQuery = $0; vm.scheduleVaultSearch() }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)

            tagFacet

            let isSearching = !vm.vaultQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if isSearching {
                if vm.vaultResults.isEmpty {
                    Text("No matches").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(vm.vaultResults) { hit in
                            VaultHitRow(hit: hit) { vm.loadVaultConversation(id: hit.conversationId) }
                        }
                    }
                }
            } else {
                if vm.vaultRecents.isEmpty {
                    Text("No saved conversations yet.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(vm.vaultRecents) { conv in
                            VaultConversationRow(
                                conv: conv,
                                onOpen: { vm.loadVaultConversation(id: conv.id) },
                                onDelete: { vm.deleteVaultConversation(id: conv.id) },
                                onAddTag: { vm.addTag($0, to: conv.id) },
                                onRemoveTag: { vm.removeTag($0, from: conv.id) },
                                onToggleTagFilter: { vm.toggleTagFilter($0) }
                            )
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Clear vault…") {
                    let alert = NSAlert()
                    alert.messageText = "Clear all saved conversations?"
                    alert.informativeText = "This removes every conversation in the vault and cannot be undone."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Clear")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        vm.clearVault()
                    }
                }
                .controlSize(.small)
            }
        }
    }

    /// Tag facet filter for History. Renders horizontally-scrolling
    /// chips for every tag in the vault; clicking toggles the chip's
    /// membership in `vm.vaultTagFilter`. AND-match, so multiple
    /// selected chips narrow the list. Hidden when no tags exist yet.
    @ViewBuilder
    var tagFacet: some View {
        if !vm.allVaultTags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(vm.allVaultTags, id: \.self) { tag in
                        let selected = vm.vaultTagFilter.contains(
                            VaultStore.normalizeTag(tag)
                        )
                        Button {
                            vm.toggleTagFilter(tag)
                        } label: {
                            Text("#\(tag)")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        selected
                                            ? Color.accentColor.opacity(0.2)
                                            : Color.secondary.opacity(0.1)
                                    )
                                )
                                .overlay(
                                    Capsule().stroke(
                                        selected
                                            ? Color.accentColor.opacity(0.5)
                                            : Color.secondary.opacity(0.25)
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    if !vm.vaultTagFilter.isEmpty {
                        Button("clear") { vm.clearTagFilter() }
                            .font(.caption2)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // Tools / Appearance moved to the Settings window in P2/P3 — see
    // `Sources/Infer/Settings/ToolsSettingsView.swift` and
    // `AppearanceSettingsView.swift`. The Parameters card and the
    // Voice tab were also migrated, then reverted: they're accessed
    // often enough during normal use that the extra Cmd-, hop wasn't
    // worth the trip. Settings is the home for set-once-and-forget
    // configuration; sidebar holds anything you touch frequently.

    // MARK: Parameters

    var parametersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "slider.horizontal.3", title: "Parameters")

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
    }

    /// Seed editor. Empty field = random (non-deterministic). A numeric
    /// value is parsed as UInt64 and pinned as the sampling seed until
    /// cleared. Invalid input (non-digits) leaves `draft.seed` unchanged.
    var seedRow: some View {
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

    /// Used by `parametersSection`'s Apply button to grey-out when
    /// nothing has changed against the live `vm.settings`. Only the
    /// fields this card edits participate; settings owned by the
    /// Settings window (Tools, Appearance, etc.) don't appear here.
    var draftMatchesCurrent: Bool {
        let s = vm.settings
        return s.systemPrompt == draft.systemPrompt
            && s.temperature == draft.temperature
            && s.topP == draft.topP
            && s.maxTokens == draft.maxTokens
            && s.thinkingBudget == draft.thinkingBudget
            && s.seed == draft.seed
    }

    // MARK: Voice

    /// TTS, dictation, voice loop, plus the whisper file-transcription
    /// subsection. Bound directly to `vm` (no draft pattern) since
    /// `setTTSEnabled` / `setContinuousVoice` already cascade their
    /// effects correctly on each toggle.
    var speechSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Read responses aloud", isOn: Binding(
                get: { vm.ttsEnabled },
                set: { vm.setTTSEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle("Continuous voice (auto-mic after reply)", isOn: Binding(
                get: { vm.continuousVoice },
                set: { vm.setContinuousVoice($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle("Barge-in (interrupt TTS by speaking)", isOn: Binding(
                get: { vm.bargeInEnabled },
                set: { vm.bargeInEnabled = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!vm.continuousVoice)
            .padding(.leading, 16)

            if vm.continuousVoice, vm.bargeInEnabled {
                Text("Use headphones — laptop speakers will self-trigger.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
            }

            if vm.continuousVoice,
               vm.voiceSendPhrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Set a voice-send phrase below — otherwise there's no way to submit each turn.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Voice").font(.caption)
                Spacer()
                voiceMenu
            }
            .disabled(!vm.ttsEnabled)

            HStack(spacing: 6) {
                Button {
                    let sample = "The quick brown fox jumps over the lazy dog."
                    vm.speechSynthesizer.speak(
                        sample,
                        voiceIdentifier: vm.ttsVoiceId.isEmpty ? nil : vm.ttsVoiceId
                    )
                } label: {
                    Label("Preview", systemImage: "play.circle")
                }
                .controlSize(.small)
                .disabled(!vm.ttsEnabled)

                Button {
                    vm.speechSynthesizer.stop()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .controlSize(.small)
                .disabled(!vm.speechSynthesizer.isSpeaking)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Voice-send phrase").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. send it", text: Binding(
                    get: { vm.voiceSendPhrase },
                    set: { vm.voiceSendPhrase = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                Text("Saying this at the end of a dictation submits the message. Leave empty to disable.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("Or send after silence").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("e.g. 2.5", text: Binding(
                        get: { vm.voiceSendSilenceSeconds.map { String(format: "%.1f", $0) } ?? "" },
                        set: { s in
                            let trimmed = s.trimmingCharacters(in: .whitespaces)
                            if trimmed.isEmpty {
                                vm.voiceSendSilenceSeconds = nil
                            } else if let v = Double(trimmed), v > 0 {
                                vm.voiceSendSilenceSeconds = v
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.caption.monospacedDigit())
                    Text("sec").font(.caption2).foregroundStyle(.tertiary)
                }
                Text("Auto-submit when no new speech arrives for this many seconds. Leave empty to disable.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)

            if !vm.speechRecognizer.supportsOnDevice {
                Text("On-device dictation unavailable for this locale.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            switch vm.speechRecognizer.state {
            case .error(let msg):
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .unauthorized:
                Text("Microphone or speech-recognition permission denied. Enable in System Settings > Privacy & Security.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .unavailable(let msg):
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .recording:
                EmptyView()
            }

            Divider().padding(.vertical, 4)

            whisperSubsection
        }
    }

    var whisperSubsection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File transcription (whisper.cpp)")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("Model").font(.caption)
                Spacer()
                whisperModelMenu
            }

            Toggle("Translate to English", isOn: Binding(
                get: { vm.whisperModels.translate },
                set: { vm.whisperModels.setTranslate($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            HStack(spacing: 6) {
                Button {
                    vm.toggleAudioRecording()
                } label: {
                    Label(
                        vm.audioRecorder.isRecording ? "Stop & Transcribe" : "Record",
                        systemImage: vm.audioRecorder.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(vm.audioRecorder.isRecording ? SwiftUI.Color.red : SwiftUI.Color.primary)
                }
                .controlSize(.small)
                .disabled(vm.isTranscribingFile && !vm.audioRecorder.isRecording)

                if vm.audioRecorder.isRecording {
                    Text(Self.formatDuration(vm.audioRecorder.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                    Button {
                        vm.cancelAudioRecording()
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Discard recording")
                }
                Spacer()
            }

            if case .error(let msg) = vm.audioRecorder.state {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Record from the mic or drop audio/video files onto the window. Transcripts are inserted into the composer.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Button {
                    vm.revealRecordingsInFinder()
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .controlSize(.small)

                Button {
                    let alert = NSAlert()
                    alert.messageText = "Delete all recordings?"
                    alert.informativeText = "Every .wav file under ~/Library/Application Support/Infer/recordings/ will be removed. This cannot be undone."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Delete")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        vm.clearRecordings()
                    }
                } label: {
                    Label("Clear recordings…", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(vm.audioRecorder.isRecording)

                Spacer()
            }

            if let msg = vm.whisperModels.statusMessage {
                HStack(spacing: 6) {
                    if let p = vm.whisperModels.downloadProgress {
                        ProgressView(value: p)
                            .progressViewStyle(.linear)
                            .frame(width: 80)
                        Text("\(Int(p * 100))%")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    static func formatDuration(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    var whisperModelMenu: some View {
        let current = vm.whisperModels.selected
        let downloaded = current.isDownloaded()
        let title = "\(current.label) (\(downloaded ? "ready" : current.approxSize))"
        return Menu {
            ForEach(WhisperModelChoice.allCases) { m in
                Button(action: { vm.whisperModels.setSelected(m) }) {
                    HStack {
                        Text(m.label)
                        Spacer()
                        Text(m.isDownloaded() ? "ready" : m.approxSize)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).font(.caption)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(vm.isTranscribingFile || vm.whisperModels.downloadProgress != nil)
    }

    var voiceMenu: some View {
        let voices = SpeechSynthesizer.availableVoices()
        let current = voices.first { $0.identifier == vm.ttsVoiceId }
        let title = current.map { "\($0.name) (\($0.language))" } ?? "System default"
        return Menu {
            Button("System default") { vm.ttsVoiceId = "" }
            Divider()
            ForEach(voices, id: \.identifier) { v in
                Button("\(v.name) — \(v.language)") { vm.ttsVoiceId = v.identifier }
            }
        } label: {
            HStack {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Model

    var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "cube.box", title: "Model")

            Picker("Backend", selection: $vm.backend) {
                ForEach(Backend.allCases) { b in
                    Text(b.label).tag(b)
                }
            }
            .pickerStyle(.segmented)
            .disabled(vm.isLoadingModel || vm.isGenerating)

            if vm.backend == .cloud {
                cloudConfigRows
            } else {
                modelPicker

                TextField(
                    vm.backend == .mlx
                        ? "HF repo id (empty = default)"
                        : ".gguf path, filename, or https:// URL",
                    text: $vm.modelInput
                )
                .textFieldStyle(.roundedBorder)
                .disabled(vm.isLoadingModel || vm.isGenerating)
                .onSubmit { vm.loadCurrentBackend() }

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
                        if vm.backend == .llama {
                            Button {
                                vm.browseForLlamaModel()
                            } label: {
                                Label("Browse…", systemImage: "folder")
                            }
                            .disabled(vm.isGenerating)
                        }
                    }
                }
                .buttonStyle(.bordered)

                if vm.backend == .llama {
                    ggufDirectoryRow
                }
            }
        }
        .onAppear { vm.refreshAvailableModelsIfNeeded() }
        .sheet(isPresented: $showingCloudKeySheet) {
            CloudKeySheet(vm: vm, isPresented: $showingCloudKeySheet)
        }
    }

    @ViewBuilder
    var modelPicker: some View {
        let entries = vm.availableModels
        Menu {
            if entries.isEmpty {
                Text("No downloaded models").foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.self) { entry in
                    Button {
                        vm.selectAvailableModel(entry)
                    } label: {
                        Text(SidebarView.dropdownLabel(for: entry))
                    }
                }
            }
        } label: {
            HStack {
                Text(modelPickerTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3))
        )
        .disabled(vm.isLoadingModel || vm.isGenerating)
    }

    var ggufDirectoryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("GGUF folder").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(vm.resolvedGGUFDirectory.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Change…") { vm.pickGGUFDirectory() }
                    .controlSize(.small)
                if !vm.ggufDirectory.isEmpty {
                    Button("Reset") { vm.resetGGUFDirectory() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: Migrated to Settings (P3)
    //
    // The Voice tab (`speechSection` + `whisperSubsection` +
    // `whisperModelMenu` + `voiceMenu` + `formatDuration`) and the
    // Appearance tab (`appearanceSection`) moved to the Settings
    // window in P3. See `Sources/Infer/Settings/VoiceSettingsView.swift`
    // and `Sources/Infer/Settings/AppearanceSettingsView.swift`.
}
