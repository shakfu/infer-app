import InferRAG
import SwiftUI

/// "Add file..." and "Add URL" for a workspace's RAG corpus.
struct WorkspaceAddSourceControls: View {
    let vm: ChatViewModel
    let workspaceId: Int64
    @State private var sourceURL = ""

    private var embedderReady: Bool {
        vm.embeddingModelPresent && !vm.embeddingModelDownloading
    }
    private var hasURL: Bool {
        !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                vm.addFileToWorkspace(workspaceId: workspaceId)
            } label: {
                Label("Add file...", systemImage: "doc.badge.plus")
            }
            .controlSize(.small)
            .disabled(!embedderReady)
            TextField("https://example.com/page", text: $sourceURL)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .accessibilityLabel("URL to add")
                .onSubmit(addURL)
            Button("Add URL", action: addURL)
                .controlSize(.small)
                .disabled(!embedderReady || !hasURL)
        }
        .help(embedderReady ? "Add a source to this workspace's RAG corpus." : "Download the embedding model first.")
    }

    private func addURL() {
        guard embedderReady, hasURL else { return }
        vm.addURLToWorkspace(workspaceId: workspaceId, urlString: sourceURL)
        sourceURL = ""
    }
}

/// The workspace's removable sources. Wiki pages are left out because the wiki
/// owns their index entries and the next save would restore them.
struct WorkspaceSourcesList: View {
    let vm: ChatViewModel
    let workspaceId: Int64
    @State private var sources: [VectorSourceSummary] = []
    @State private var pendingRemoval: VectorSourceSummary?

    /// Reloads after any ingest ends or the corpus counts change.
    private var reloadKey: String {
        let stats = vm.corpusStats
        return "\(workspaceId)-\(stats?.sources ?? -1)-\(stats?.chunks ?? -1)-\(vm.ingestProgress == nil)"
    }

    var body: some View {
        Group {
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sources").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(sources) { row($0) }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
        .task(id: reloadKey) {
            sources = await vm.removableSources(workspaceId: workspaceId)
        }
        .confirmationDialog(
            "Remove this source?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { source in
            Button("Remove", role: .destructive) {
                Task { await vm.removeSource(workspaceId: workspaceId, uri: source.uri) }
            }
        } message: { source in
            Text("\(source.uri)\n\nA file inside the data folder returns on the next scan.")
        }
    }

    private func row(_ source: VectorSourceSummary) -> some View {
        HStack(spacing: 6) {
            Text(source.uri)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(source.uri)
            Spacer()
            Text("\(source.chunkCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .accessibilityLabel("\(source.chunkCount) chunks")
            Button {
                pendingRemoval = source
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(vm.ingestProgress != nil)
            .accessibilityLabel("Remove \(source.uri)")
        }
    }
}
