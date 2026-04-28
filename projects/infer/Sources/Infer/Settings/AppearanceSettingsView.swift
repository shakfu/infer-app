import SwiftUI

/// Light / dark / system color-scheme picker. Persisted under
/// `infer.appearance` (matches the existing `@AppStorage` key the app
/// has used since the sidebar tab era — picks up the user's previous
/// choice transparently). The picker rebinds the same `@AppStorage`
/// the App scene reads for `preferredColorScheme`, so changes apply
/// instantly without an explicit Apply button.
struct AppearanceSettingsView: View {
    @AppStorage("infer.appearance") private var appearanceRaw: String = AppearanceMode.light.rawValue

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
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}
