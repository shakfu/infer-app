import SwiftUI
import AppKit
import MarkdownUI
import Splash
import InferAgents
import InferCore

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
            if let refs = message.retrievedChunks, !refs.isEmpty {
                SourcesDisclosure(chunks: refs)
            }
            if message.isThinking || (message.thinkingText?.isEmpty == false) {
                ThinkingDisclosure(
                    text: message.thinkingText ?? "",
                    isLive: message.isThinking
                )
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
    /// non-Default agent, this is the agent's pre-snapshotted
    /// `displayLabel` (a Unicode-safe, single-token flattening of the
    /// agent name). Default assistant replies and historical (pre-agent)
    /// ones stay "assistant".
    private var roleLabel: String {
        switch message.role {
        case .user: return "user"
        case .system: return "system"
        case .assistant:
            if let label = message.agentLabel, !label.isEmpty { return label }
            if let name = message.agentName, !name.isEmpty {
                // Legacy rows from before agentLabel was snapshotted —
                // flatten on the fly using the same rules so the row
                // still renders as a single token.
                return AgentListing.makeDisplayLabel(
                    from: name,
                    fallbackId: message.agentId ?? "agent"
                )
            }
            return "assistant"
        }
    }
}

/// Disclosure group rendered above an assistant message when the turn
/// went through the tool loop. Auto-expands while the trace is in-flight
/// (no terminator) so the user sees tool progress live; collapses to a
/// step-count badge once the turn settles. A user toggle overrides the
/// auto-behaviour for the remainder of the row's lifetime.
struct StepTraceDisclosure: View {
    let trace: StepTrace
    @State private var userOverride: Bool?
    /// Default true — matches the pre-M3 always-auto-expand behaviour.
    /// `UserDefaults.bool(forKey:)` returns false for unset keys, so
    /// `AppDelegate.applicationDidFinishLaunching` registers the default
    /// once at launch.
    @AppStorage(PersistKey.autoExpandAgentTraces) private var autoExpand: Bool = true

    private var isStreaming: Bool { trace.terminator == nil }

    var body: some View {
        let callCount = trace.steps.reduce(into: 0) { acc, step in
            if case .toolCall = step { acc += 1 }
        }
        if callCount == 0 { EmptyView() } else {
            let expanded = Binding<Bool>(
                get: { userOverride ?? (isStreaming && autoExpand) },
                set: { userOverride = $0 }
            )
            DisclosureGroup(isExpanded: expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(trace.steps.enumerated()), id: \.offset) { offset, step in
                        HStack(alignment: .top, spacing: 6) {
                            // Multi-agent gutter (M5a-foundation
                            // SegmentSpan). When the trace was emitted
                            // by a composition, every step belongs to
                            // some segment; show that agent's id as a
                            // small chip so the user can attribute the
                            // row. Single-segment traces fall through
                            // to nil and render as before.
                            if let agentId = Self.agentId(forStep: offset, in: trace) {
                                Text(verbatim: agentId.rawValue)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule().fill(Color.secondary.opacity(0.12))
                                    )
                                    .fixedSize()
                            }
                            StepRow(step: step)
                        }
                    }
                    pendingRow
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "hammer")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(callCount) tool call\(callCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let telemetry = trace.telemetry {
                        TelemetryBadge(telemetry: telemetry)
                    }
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

    /// Find the agent id whose `SegmentSpan` covers `stepIndex`, or
    /// nil when the trace has no segments (single-agent turn). Spans
    /// tile with no overlap; linear scan is fine — composition turns
    /// rarely exceed a handful of segments.
    static func agentId(forStep stepIndex: Int, in trace: StepTrace) -> AgentID? {
        guard !trace.segments.isEmpty else { return nil }
        for span in trace.segments where stepIndex >= span.startStep && stepIndex < span.endStep {
            return span.agentId
        }
        return nil
    }

    /// Trailing row shown while the trace is in-flight. Signals to the
    /// user *what* is happening — tool running vs waiting on the
    /// follow-up decode — so a 2-5 s pause doesn't feel like a hang.
    @ViewBuilder
    private var pendingRow: some View {
        if isStreaming, let last = trace.steps.last {
            switch last {
            case .toolCall(let call):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("running \(call.name)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .toolResult:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("awaiting final answer…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            default:
                EmptyView()
            }
        }
    }
}

/// Compact summary chip rendered next to the trace disclosure label
/// (item 8 telemetry). Shows token count, segment duration, summed
/// tool latency, and a failure count when non-zero. Hidden values
/// (e.g. `durationMillis == nil` from a custom-loop agent) are
/// silently omitted so the badge stays narrow when the loop driver
/// didn't measure them.
private struct TelemetryBadge: View {
    let telemetry: StepTrace.TurnTelemetry

    var body: some View {
        HStack(spacing: 6) {
            if telemetry.tokens > 0 {
                Text("\(telemetry.tokens) tok")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let ms = telemetry.durationMillis {
                Text(formatMillis(ms))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            let toolMillis = telemetry.toolLatencyMillisByName.values.reduce(0, +)
            if toolMillis > 0 {
                Text("\(formatMillis(toolMillis)) tool")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if telemetry.toolFailureCount > 0 {
                Text("\(telemetry.toolFailureCount) fail")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.red)
            }
        }
        .help(tooltip)
    }

    private func formatMillis(_ ms: Int) -> String {
        // Sub-second precision matters for tool calls; multi-second
        // numbers compress to one decimal so the badge doesn't grow.
        if ms < 1000 { return "\(ms) ms" }
        return String(format: "%.1f s", Double(ms) / 1000.0)
    }

    private var tooltip: String {
        var lines: [String] = []
        lines.append("Tokens decoded (net): \(telemetry.tokens)")
        if let ms = telemetry.durationMillis {
            lines.append("Segment duration: \(ms) ms")
        }
        if telemetry.toolCallCount > 0 {
            lines.append("Tool calls: \(telemetry.toolCallCount) (\(telemetry.toolFailureCount) failed)")
        }
        for (name, ms) in telemetry.toolLatencyMillisByName.sorted(by: { $0.key < $1.key }) {
            lines.append("  \(name): \(ms) ms")
        }
        return lines.joined(separator: "\n")
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
/// Hover-tooltip carries the timestamp so a scroll-back through a
/// multi-switch conversation is auditable without touching the code.
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
                .help("Active agent switched to \"\(agentName)\" at this point in the conversation.")
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}

/// Collapsed "Sources" disclosure rendered on assistant messages
/// that went through RAG. Mirrors `StepTraceDisclosure` visually so
/// the two supplementary rows sit together naturally. Each row is a
/// Reveal-in-Finder affordance — click to open the source file.
struct SourcesDisclosure: View {
    let chunks: [RetrievedChunkRef]
    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(chunks.enumerated()), id: \.offset) { _, chunk in
                    SourceRow(chunk: chunk)
                }
            }
            .padding(.top, 4)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(chunks.count) source\(chunks.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let best = chunks.first {
                    // Similarity = 1 - distance/2 for cosine distance
                    // in [0, 2]. Closer to 1 = better match.
                    let sim = 1.0 - best.distance / 2.0
                    Text(String(format: "best %.2f", sim))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
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

private struct SourceRow: View {
    let chunk: RetrievedChunkRef

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text((chunk.sourceURI as NSString).lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                Text("chunk \(chunk.ord)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                // Show similarity (1 - distance/2 under cosine) so
                // the per-row number is comparable to the header's
                // "best X.XX" without the user juggling two metrics.
                // Higher is better; 1.0 is identical, 0.0 is
                // orthogonal.
                Text(String(format: "%.2f", 1.0 - chunk.distance / 2.0))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        URL(fileURLWithPath: chunk.sourceURI)
                    ])
                } label: {
                    Image(systemName: "folder")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Reveal \((chunk.sourceURI as NSString).lastPathComponent) in Finder")
            }
            Text(chunk.preview)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// Collapsible disclosure rendering captured `<think>…</think>`
/// content from reasoning models (Qwen-3, DeepSeek-R1, etc.).
/// Mirrors `SourcesDisclosure` styling so the auxiliary disclosures
/// stack consistently. Auto-expands while the model is actively
/// inside a `<think>` block (`isLive == true`); collapses to a
/// "thoughts" summary once thinking finishes and the visible answer
/// starts streaming. User toggle overrides the auto-state for the
/// row's lifetime.
struct ThinkingDisclosure: View {
    let text: String
    let isLive: Bool
    @State private var userOverride: Bool?

    var body: some View {
        // Always start collapsed — the live "thinking…" header is
        // enough signal that the model is reasoning. User clicks to
        // peek. Override sticks for the row's lifetime once toggled.
        let expanded = Binding<Bool>(
            get: { userOverride ?? false },
            set: { userOverride = $0 }
        )
        DisclosureGroup(isExpanded: expanded) {
            // Reasoning content. Monospaced + selectable + secondary
            // foreground so it reads as commentary, not the answer.
            ScrollView {
                Text(text.isEmpty ? "…" : text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .frame(maxHeight: 240)
        } label: {
            HStack(spacing: 6) {
                if isLive {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "brain")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(isLive ? "thinking…" : "thoughts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !isLive, !text.isEmpty {
                    Text("\(text.count) chars")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
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
