import SwiftUI
import AppKit
import InferCore

extension ChatView {
    var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Suggestion popover above the composer when the user is
            // mid-typing a `[[mention]]`. Sits above the input so it
            // doesn't push the controls down on every keystroke.
            ChatComposerMentionsBar(vm: vm)
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
                    VStack(alignment: .trailing, spacing: 2) {
                        Button("Send") {
                            vm.send()
                            if composerExpanded { composerExpanded = false }
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!sendEnabled)
                        .help(sendDisabledReason ?? "Send (⌘↵)")
                        // Mention-cost badge: tells the user how much
                        // extra context their `[[Page]]` mentions
                        // will inject this turn. Counted against the
                        // current input only (mentions are per-turn
                        // — the always-injected pinned cost is
                        // already shown in the wiki sidebar footer).
                        if let cost = mentionCostBadge {
                            Text(cost)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(10)
        .animation(.easeInOut(duration: 0.15), value: composerExpanded)
        .onAppear {
            // Drop the user straight into the composer on launch so they
            // can start typing without a click. Fires on every appear (not
            // just first); harmless because the composer reappears only
            // when the whole chat view does, not on every transcript
            // re-render.
            composerFocused = true
        }
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

    /// Compact summary of the per-turn cost of `[[Page]]` mentions
    /// in the current input — synchronous + cheap (regex-light scan
    /// of the input string, then chars/4 estimate per resolved page
    /// from the cached `vm.wikiPages`). Returns nil when no mentions
    /// are present so the badge slot stays empty in the common case.
    var mentionCostBadge: String? {
        let raws = WikiLinkResolver.extractLinks(from: vm.input)
        guard !raws.isEmpty else { return nil }
        let pages = vm.wikiPages
        let fullIndex = Dictionary(
            uniqueKeysWithValues: pages.map { ($0.id.lowercased(), $0) }
        )
        var basenameIndex: [String: String] = [:]
        for fullKey in fullIndex.keys.sorted() {
            let base = (fullKey as NSString).lastPathComponent
            if basenameIndex[base] == nil { basenameIndex[base] = fullKey }
        }
        var resolved: Set<String> = []
        var totalTokens = 0
        for raw in raws {
            guard let key = WikiLinkResolver.resolveKey(
                raw, fullIndex: fullIndex, basenameIndex: basenameIndex
            ),
                  !resolved.contains(key),
                  let page = fullIndex[key] else { continue }
            resolved.insert(key)
            totalTokens += WikiContext.estimateTokens(for: page)
        }
        guard !resolved.isEmpty else { return nil }
        return "\(resolved.count) mention\(resolved.count == 1 ? "" : "s") · ~\(formattedTokens(totalTokens)) tok"
    }

    private func formattedTokens(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        return String(format: "%.1fk", Double(n) / 1000.0)
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
        // Placeholder doubles as the discoverability surface for the
        // otherwise-invisible Shift+Return-for-newline behaviour. Kept
        // short so it doesn't dominate the empty-field state; the
        // expanded editor's "Cmd+Return to send" overlay carries the
        // submit-side of the contract.
        TextField("Message  (⇧↵ newline)", text: $vm.input, axis: .vertical)
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
