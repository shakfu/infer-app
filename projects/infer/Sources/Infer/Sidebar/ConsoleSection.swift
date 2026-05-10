import SwiftUI
import AppKit

extension SidebarView {
    /// Console tab: live, structured observability over what the app is
    /// doing in the background. Surfaces events that previously only
    /// went to stderr (vault writes, Whisper / speech-service warnings,
    /// agent bootstrap diagnostics, model loads). Read-only; not
    /// persisted. A sink for all `vm.logs.log(...)` calls.
    var consoleSection: some View {
        ConsoleBody(vm: vm)
    }
}

private struct ConsoleBody: View {
    let vm: ChatViewModel
    @State private var filter: LogFilter = LogFilter()
    @State private var autoScroll: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(icon: "terminal", title: "Console")

            toolbar

            let visible = vm.logs.events.filter(filter.matches)

            if visible.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(visible) { event in
                                LogRow(event: event)
                                    .id(event.id)
                            }
                        }
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: vm.logs.appendCount) { _, _ in
                        guard autoScroll, let last = visible.last else { return }
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 6) {
            Picker("Level", selection: $filter.minLevel) {
                ForEach(LogLevel.allCases, id: \.self) { l in
                    Text(l.label.capitalized).tag(l)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 90)
            .help("Show this level and above.")

            TextField("Filter", text: $filter.query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            Spacer()
        }

        let knownSources = Array(Set(vm.logs.events.map(\.source))).sorted()
        if !knownSources.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(knownSources, id: \.self) { src in
                        let selected = filter.sources.contains(src)
                        Button {
                            if selected { filter.sources.remove(src) }
                            else { filter.sources.insert(src) }
                        } label: {
                            Text(src)
                                .font(.caption2.monospaced())
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
                        .help(selected
                              ? "Click to remove \(src) from the filter"
                              : "Click to show only \(src)")
                    }
                    if !filter.sources.isEmpty {
                        Button("clear") { filter.sources.removeAll() }
                            .font(.caption2)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
        }

        HStack(spacing: 8) {
            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Spacer()

            // Action buttons are icon-only because the sidebar is
            // narrow (240pt with the wiki tree + tab bar already
            // in the column) and Label-style buttons truncate to
            // a single character ("C…", "Re…", "Cl…") at this
            // width. Tooltips carry the full action name so the
            // affordance stays discoverable on hover. Standard
            // macOS toolbar convention.
            Button {
                let text = vm.logs.formatForCopy(filter)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                vm.toasts.show("Copied \(vm.logs.events.filter(filter.matches).count) log line(s).")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .controlSize(.small)
            .disabled(vm.logs.events.isEmpty)
            .help("Copy log lines to clipboard (respects the current filter).")

            // Persistent JSONL files live in
            // `Application Support/Infer/logs/`. Reveal-in-Finder
            // is the simplest export: the user grabs whatever
            // daily files they want and hands them to support.
            // Disabled when persistence is off (test-fixture
            // construction or future deployments that opt out).
            if let dir = vm.logs.logDirectory {
                Button {
                    // Create the dir on first reveal so the user
                    // doesn't see "folder does not exist" on a
                    // fresh install before any log has rolled.
                    try? FileManager.default.createDirectory(
                        at: dir,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                } label: {
                    Image(systemName: "folder")
                }
                .controlSize(.small)
                .help("Reveal log files in Finder. Daily-rotated JSONL with 14-day retention.")
            }

            Button(role: .destructive) {
                vm.logs.clear()
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .disabled(vm.logs.events.isEmpty)
            .help("Clear the in-memory Console log. On-disk JSONL files are NOT touched — those rotate daily and are pruned at the 14-day horizon.")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No log events yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Events from background systems (vault, whisper, agents, model loads) will appear here.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }
}

/// One line in the Console. Timestamp + level badge + source tag +
/// message, with an optional collapsed payload the user can expand.
private struct LogRow: View {
    let event: LogEvent
    @State private var expanded: Bool = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Self.timeFormatter.string(from: event.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Text(event.level.label)
                    .font(.caption2.monospaced())
                    .foregroundStyle(event.level.tint)
                    .frame(width: 38, alignment: .leading)
                Text(event.source)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Text(event.message)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let payload = event.payload, !payload.isEmpty {
                if expanded {
                    Text(payload)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 52)
                } else {
                    Button {
                        expanded = true
                    } label: {
                        Text("show detail")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 52)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
