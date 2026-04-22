import SwiftUI
import AppKit
import MarkdownUI
import Splash

extension ChatView {
    var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(vm.messages.enumerated()), id: \.element.id) { idx, msg in
                        MessageRow(
                            message: msg,
                            onRegenerate: canRegenerate(at: idx) ? { vm.regenerateLast() } : nil,
                            onEdit: canEdit(at: idx) ? { vm.editLastUserMessage() } : nil
                        )
                        .id(msg.id)
                    }
                    // Bottom sentinel: when the LazyVStack has it in its
                    // render range (user is near the bottom), we're pinned
                    // and streaming auto-scrolls. Scrolling up unloads it
                    // and unpins.
                    Color.clear
                        .frame(height: 1)
                        .onAppear { pinnedToBottom = true }
                        .onDisappear { pinnedToBottom = false }
                        .id("_bottom_sentinel")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.textBackgroundColor))
            .onChange(of: vm.messages.last?.text) { _, _ in
                if pinnedToBottom, let last = vm.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
            .onChange(of: vm.messages.count) { _, _ in
                // A new turn was appended — treat as a user intention to
                // follow the conversation again.
                pinnedToBottom = true
                if let last = vm.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !pinnedToBottom, !vm.messages.isEmpty {
                    Button {
                        pinnedToBottom = true
                        if let last = vm.messages.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.thinMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.secondary.opacity(0.25)))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: pinnedToBottom)
        }
    }

    /// True when the message at `idx` is the last assistant turn, preceded
    /// by a user turn, and the VM is idle — the conditions under which
    /// regenerating is well-defined.
    func canRegenerate(at idx: Int) -> Bool {
        guard !vm.isGenerating, vm.modelLoaded else { return false }
        guard idx == vm.messages.count - 1, idx > 0 else { return false }
        return vm.messages[idx].role == .assistant
            && vm.messages[idx - 1].role == .user
    }

    /// True when the message at `idx` is the user turn immediately preceding
    /// the last assistant turn, and the VM is idle — the conditions under
    /// which edit-and-resend is well-defined.
    func canEdit(at idx: Int) -> Bool {
        guard !vm.isGenerating, vm.modelLoaded else { return false }
        let last = vm.messages.count - 1
        guard idx == last - 1, idx >= 0, last > 0 else { return false }
        return vm.messages[idx].role == .user
            && vm.messages[last].role == .assistant
    }

    @ViewBuilder
    var transcriptionBanner: some View {
        if let status = vm.transcriptionStatus {
            HStack(spacing: 8) {
                if let p = vm.whisperModels.downloadProgress {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                    Text("\(Int(p * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.thinMaterial)
            .overlay(Divider(), alignment: .top)
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    /// When non-nil, hover reveals a regenerate button that invokes this.
    /// Wired only for the latest assistant turn when the VM is idle.
    var onRegenerate: (() -> Void)? = nil
    /// When non-nil, hover reveals an edit button that invokes this. Wired
    /// only for the last user turn (preceding the latest assistant) when the
    /// VM is idle.
    var onEdit: (() -> Void)? = nil
    @State private var isHovered = false
    @State private var justCopied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(roleLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            content
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            if isHovered, !message.text.isEmpty {
                HStack(spacing: 4) {
                    if let onEdit {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SwiftUI.Color.secondary)
                                .padding(4)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help("Edit and resend")
                    }
                    if let onRegenerate {
                        Button(action: onRegenerate) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(SwiftUI.Color.secondary)
                                .padding(4)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help("Regenerate response")
                    }
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(message.text, forType: .string)
                        justCopied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 900_000_000)
                            await MainActor.run { justCopied = false }
                        }
                    } label: {
                        Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(justCopied ? SwiftUI.Color.green : SwiftUI.Color.secondary)
                            .padding(4)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Copy message")
                }
                .transition(.opacity)
            }
        }
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: justCopied)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = message.imageURL, let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 280, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.25)))
            }
            if message.text.isEmpty, message.imageURL == nil {
                Text("…").foregroundStyle(.secondary)
            } else if !message.text.isEmpty {
                switch message.role {
                case .assistant:
                    Markdown(message.text)
                        .markdownTheme(.gitHub)
                        .markdownCodeSyntaxHighlighter(
                            .splash(theme: .sundellsColors(withFont: .init(size: 14)))
                        )
                        .environment(\.openURL, OpenURLAction { url in
                            NSWorkspace.shared.open(url)
                            return .handled
                        })
                case .user, .system:
                    Text(message.text)
                }
            }
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return "user"
        case .assistant: return "assistant"
        case .system: return "system"
        }
    }
}
