import SwiftUI
import AppKit

/// TTS, dictation, voice loop, and whisper file transcription. Lifted
/// wholesale from the sidebar's Voice tab in P3 — the controls bind
/// directly to `vm` (no draft pattern; speech toggles take effect
/// immediately because `setTTSEnabled` / `setContinuousVoice` already
/// debounce / cascade correctly).
///
/// Note: this tab includes some live-action UI (record button,
/// transcription progress) that doesn't fit the typical "static
/// configuration" Settings model. We keep it together rather than
/// splitting because the configuration controls (TTS toggles, voice
/// picker) and the active controls (record, model download progress)
/// share so much surrounding state that splitting them would force
/// the user to context-switch between two surfaces to set up
/// transcription.
struct VoiceSettingsView: View {
    @Bindable var vm: ChatViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                ttsControls
                voicePickerRow
                ttsButtons
                voiceSendPhraseGroup
                voiceSendSilenceGroup
                dictationStatus
                Divider().padding(.vertical, 4)
                whisperSubsection
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Voice")
                .font(.title3.weight(.semibold))
            Text("TTS, dictation, the hands-free voice loop, and `whisper.cpp` file transcription.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var ttsControls: some View {
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
    }

    private var voicePickerRow: some View {
        HStack {
            Text("Voice").font(.caption)
            Spacer()
            voiceMenu
        }
        .disabled(!vm.ttsEnabled)
    }

    private var ttsButtons: some View {
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
    }

    private var voiceSendPhraseGroup: some View {
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
    }

    private var voiceSendSilenceGroup: some View {
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
    }

    @ViewBuilder
    private var dictationStatus: some View {
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
    }

    private var whisperSubsection: some View {
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

    private static func formatDuration(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private var whisperModelMenu: some View {
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

    private var voiceMenu: some View {
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
}
