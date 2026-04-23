import SwiftUI
import AppKit

/// Minimal non-modal notification surface. One toast at a time; new
/// toasts replace the current one. Auto-dismisses after a short delay,
/// or can be dismissed with the `x` button. Optional action button
/// invokes an `@MainActor` closure (e.g., "Reveal in Finder").
///
/// Used for fire-and-forget confirmations — successful duplication,
/// vault write fallbacks, non-critical warnings — where an alert is
/// overkill and printing to stderr is invisible.
@Observable
@MainActor
final class ToastCenter {
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let actionTitle: String?
        let action: (@MainActor () -> Void)?

        static func == (lhs: Toast, rhs: Toast) -> Bool {
            lhs.id == rhs.id
                && lhs.message == rhs.message
                && lhs.actionTitle == rhs.actionTitle
        }
    }

    var current: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(
        _ message: String,
        actionTitle: String? = nil,
        autoDismissAfter seconds: Double = 4.0,
        action: (@MainActor () -> Void)? = nil
    ) {
        dismissTask?.cancel()
        let toast = Toast(message: message, actionTitle: actionTitle, action: action)
        current = toast
        let id = toast.id
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.current?.id == id else { return }
                self.current = nil
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        current = nil
    }
}

/// SwiftUI overlay that renders the active toast at the bottom of a
/// view. Apply as `.overlay(ToastOverlay(center: center), alignment: .bottom)`.
struct ToastOverlay: View {
    @Bindable var center: ToastCenter

    var body: some View {
        if let toast = center.current {
            HStack(spacing: 10) {
                Text(toast.message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = toast.actionTitle, let action = toast.action {
                    Button(title) {
                        action()
                        center.dismiss()
                    }
                    .buttonStyle(.link)
                }
                Button {
                    center.dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.25))
            )
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}
