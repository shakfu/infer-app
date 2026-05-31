import SwiftUI
import InferCore

/// Display preferences: color scheme + chat-transcript rendering.
/// Persisted under `@AppStorage` keys read live elsewhere (the App
/// scene reads `infer.appearance` for `preferredColorScheme`; the
/// WKWebView message renderer reads `PersistKey.chatThrottleStreaming`
/// per token), so changes apply instantly without an Apply button.
struct AppearanceSettingsView: View {
    @AppStorage("infer.appearance") private var appearanceRaw: String = AppearanceMode.light.rawValue
    @AppStorage(PersistKey.chatThrottleStreaming) private var throttleStreaming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Appearance")
                    .font(.title3.weight(.semibold))
                Text("Applies live; no Apply button.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Divider()
            Picker("Color scheme", selection: Binding(
                get: { AppearanceMode(rawValue: appearanceRaw) ?? .light },
                set: { appearanceRaw = $0.rawValue }
            )) {
                ForEach(AppearanceMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Throttle streaming re-render", isOn: $throttleStreaming)
                Text("Coalesces chat re-rendering to ~12×/sec while a reply streams, instead of re-rendering on every token. Leave off for local models (already smooth); turn on if a fast cloud model or a very long, code-heavy reply stutters as it streams.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
    }
}
