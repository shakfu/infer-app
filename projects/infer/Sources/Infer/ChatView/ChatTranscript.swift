import SwiftUI
import AppKit
import MarkdownUI
import Splash
import InferAgents

extension ChatView {
    var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(vm.messages.enumerated()), id: \.element.id) { idx, msg in
                        if case .agentDivider(let agentName) = msg.kind {
                            AgentDividerRow(agentName: agentName).id(msg.id)
                        } else {
                            MessageRow(
                                message: msg,
                                onRegenerate: canRegenerate(at: idx) ? { vm.regenerateLast() } : nil,
                                onEdit: canEdit(at: idx) ? { vm.editLastUserMessage() } : nil
                            )
                            .id(msg.id)
                        }
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
                .lineLimit(1)
                .truncationMode(.tail)
                .help(roleLabel)
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
            if let trace = message.steps, !trace.steps.isEmpty {
                StepTraceDisclosure(trace: trace)
            }
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

    /// Role column text. For assistant messages produced by a
    /// non-Default agent, this is the agent's display name flattened to
    /// a single lowercase hyphenated token so it reads as one word
    /// alongside the other role labels ("user", "system"). Default
    /// assistant replies and historical (pre-agent) ones stay
    /// "assistant" — attribution is unambiguous.
    private var roleLabel: String {
        switch message.role {
        case .user: return "user"
        case .system: return "system"
        case .assistant:
            if let name = message.agentName, !name.isEmpty {
                return Self.labelize(name)
            }
            return "assistant"
        }
    }

    private static func labelize(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

/// Disclosure group rendered above an assistant message when the turn
/// went through the tool loop. Collapsed by default with a step-count
/// badge so a transcript full of tool-using replies stays readable; one
/// click expands to show the tool calls and results inline.
struct StepTraceDisclosure: View {
    let trace: StepTrace
    @State private var expanded = false

    var body: some View {
        let callCount = trace.steps.reduce(into: 0) { acc, step in
            if case .toolCall = step { acc += 1 }
        }
        if callCount == 0 { EmptyView() } else {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(trace.steps.enumerated()), id: \.offset) { _, step in
                        StepRow(step: step)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "hammer")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(callCount) tool call\(callCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2))
            )
        }
    }
}

private struct StepRow: View {
    let step: StepTrace.Step

    var body: some View {
        switch step {
        case .assistantText(let text) where !text.isEmpty:
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .assistantText:
            EmptyView()
        case .toolCall(let call):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.circle")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                    Text(call.name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                }
                if call.arguments != "{}" && !call.arguments.isEmpty {
                    Text(call.arguments)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.leading, 16)
                }
            }
        case .toolResult(let result):
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "arrow.down.left.circle")
                    .font(.caption2)
                    .foregroundStyle(result.error == nil ? Color.green : Color.red)
                Text(result.error ?? result.output)
                    .font(.caption.monospaced())
                    .foregroundStyle(result.error == nil ? Color.primary : Color.red)
                    .textSelection(.enabled)
            }
        case .finalAnswer:
            // Final answer is rendered as the main message body; no need
            // to repeat inside the disclosure.
            EmptyView()
        case .cancelled:
            Text("cancelled")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .budgetExceeded:
            Text("step budget exhausted")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .error(let message):
            Text("error: \(message)")
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}

/// Divider row rendered when the active agent switches mid-conversation.
/// UI-only — never sent to a runner, never persisted to the vault.
struct AgentDividerRow: View {
    let agentName: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
            Text("Agent: \(agentName)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(Color.secondary.opacity(0.1))
                )
                .overlay(Capsule().stroke(Color.secondary.opacity(0.3)))
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}
