import SwiftUI
import AppKit

extension ChatView {
    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = vm.pendingImageURL {
                attachmentChip(url: url)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    composerExpanded.toggle()
                    DispatchQueue.main.async { composerFocused = true }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(composerExpanded ? 90 : 0))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(composerExpanded ? "Collapse editor" : "Expand editor")
                .padding(.bottom, 4)

                attachButton
                    .padding(.bottom, 4)

                micButton
                    .padding(.bottom, 4)

                Group {
                    if composerExpanded {
                        expandedEditor
                    } else {
                        collapsedField
                    }
                }

                if vm.isGenerating {
                    Button("Stop") { vm.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Send") {
                        vm.send()
                        if composerExpanded { composerExpanded = false }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!sendEnabled)
                    .help(sendDisabledReason ?? "Send (⌘↵)")
                }
            }
        }
        .padding(10)
        .animation(.easeInOut(duration: 0.15), value: composerExpanded)
    }

    var sendEnabled: Bool {
        vm.modelLoaded
            && !vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && vm.canSendAttachment
    }

    var sendDisabledReason: String? {
        if !vm.canSendAttachment {
            return "The current backend can't use image attachments. Switch to MLX with a vision-capable model (e.g. gemma-3-4b-it-4bit)."
        }
        return nil
    }

    var attachButton: some View {
        Button {
            vm.pickAttachment()
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Attach image or audio…")
        .disabled(vm.isGenerating || vm.isTranscribingFile)
    }

    @ViewBuilder
    func attachmentChip(url: URL) -> some View {
        let image = NSImage(contentsOf: url)
        HStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))

            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            if !vm.canSendAttachment {
                Text("MLX VLM only")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button {
                vm.clearPendingImage()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    var micButton: some View {
        let recording = vm.speechRecognizer.isRecording
        let starting = vm.speechRecognizer.isStarting
        let active = recording || starting
        return Button {
            vm.toggleDictation()
        } label: {
            Image(systemName: active ? "mic.fill" : "mic")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? .red : .secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(starting && !recording)
        .help(recording ? "Stop dictation" : "Dictate (on-device)")
    }

    var collapsedField: some View {
        TextField("Message", text: $vm.input, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...6)
            .font(.body)
            .focused($composerFocused)
            .onKeyPress(keys: [.return], phases: .down) { keyPress in
                if keyPress.modifiers.contains(.shift) {
                    // NSTextField can't insert newlines, so auto-expand
                    // into the TextEditor and carry the newline forward.
                    vm.input += "\n"
                    composerExpanded = true
                    DispatchQueue.main.async { composerFocused = true }
                    return .handled
                }
                vm.send()
                return .handled
            }
    }

    var expandedEditor: some View {
        TextEditor(text: $vm.input)
            .font(.body)
            .focused($composerFocused)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: 120, maxHeight: 260)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.35))
            )
            .overlay(alignment: .bottomTrailing) {
                Text("Cmd+Return to send")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(6)
            }
    }
}
