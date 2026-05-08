import SwiftUI
import AppKit

/// Cmd+F find bar that overlays the top of the transcript. Slim
/// horizontal strip with a search field, match counter, prev/next
/// arrows, and a close button. Cmd+G / Shift+Cmd+G step through
/// matches; Esc closes.
///
/// The bar mutates `vm.transcriptFindQuery` (string binding) and
/// `vm.transcriptFindActiveMatch` (cursor index). `MessageRow` reads
/// the query to highlight matched ranges in its rendered body; the
/// scroll-to-active behaviour fires from `ChatTranscript` listening
/// to active-match changes.
struct TranscriptFindBar: View {
    @Bindable var vm: ChatViewModel
    /// Total matches across the rendered transcript. Recomputed by
    /// `ChatTranscript` from the message bodies on every query
    /// change; passed in here purely for display.
    let matchCount: Int

    @FocusState private var fieldFocused: Bool

    private var queryBinding: Binding<String> {
        Binding(
            get: { vm.transcriptFindQuery ?? "" },
            set: { vm.transcriptFindQuery = $0; vm.transcriptFindActiveMatch = 0 }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in transcript", text: queryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit { vm.transcriptFindStepNext() }

            Text(matchSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)

            Button { vm.transcriptFindStepPrev() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(matchCount == 0)
            .help("Previous match (Shift+Cmd+G)")

            Button { vm.transcriptFindStepNext() } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("g", modifiers: .command)
            .disabled(matchCount == 0)
            .help("Next match (Cmd+G)")

            Button { vm.transcriptFindClose() } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .help("Close find bar (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(.separator).frame(height: 1)
        }
        .onAppear {
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    private var matchSummary: String {
        let query = vm.transcriptFindQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if query.isEmpty { return "" }
        if matchCount == 0 { return "No matches" }
        // The VM's raw counter is unbounded — Cmd+G keeps adding,
        // Shift+Cmd+G keeps subtracting. Wrap into [0, matchCount)
        // for display so the badge always reads "N of M" with a
        // sensible N.
        let raw = vm.transcriptFindActiveMatch
        let wrapped = ((raw % matchCount) + matchCount) % matchCount
        return "\(wrapped + 1) of \(matchCount)"
    }
}
