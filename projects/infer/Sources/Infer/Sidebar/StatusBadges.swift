import SwiftUI

/// Compact one-row status indicator: SF Symbol + caption text. Used
/// for inline "is this thing configured?" surfaces — the cloud-key
/// status under the Cloud backend selector, the OpenAI-key status
/// under the Image tab's cloud backend, and similar.
///
/// Replaces ~12 lines of HStack + Image + Text + foregroundStyle
/// per call site. Tint is applied only to the icon; the label stays
/// `.secondary` so the row reads as descriptive rather than alarming
/// (the icon shape carries the urgency cue).
struct InlineStatusBadge: View {
    let icon: String
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.caption)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
    }
}

/// Three-state download/ready/missing card for a managed model file.
/// Used by the workspace sheet's embedding and reranker model rows.
/// The "downloading" state shows a linear progress bar inside an
/// accent-tinted card; the "missing" state shows a heading + a
/// description + a CTA button inside an orange-tinted card; the
/// "ready" state collapses to a single inline check + caption row
/// (no card chrome — it's quiet by design once the model is present).
///
/// API takes the three states as an enum so a caller can't construct
/// an inconsistent combination (e.g. "downloading + missing" or
/// "ready with a download button"). The CTA is a `() -> Void` plus a
/// label rather than a generic `View` so the callsite stays terse.
struct ModelDownloadStatus: View {
    enum State {
        case downloading(name: String, progress: Double)
        case missing(title: String, description: String, ctaLabel: String, action: () -> Void)
        case ready(label: String)
    }

    let state: State

    var body: some View {
        switch state {
        case .downloading(let name, let progress):
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Downloading \(name)…")
                        .font(.caption)
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.accentColor.opacity(0.3))
            )

        case .missing(let title, let description, let ctaLabel, let action):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(title)
                        .font(.callout).fontWeight(.medium)
                }
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: action) {
                    Label(ctaLabel, systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange.opacity(0.3))
            )

        case .ready(let label):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
