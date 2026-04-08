import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: OverlayViewModel

    var body: some View {
        Form {
            Section("Translation") {
                Picker("Translate to", selection: Binding(
                    get: { model.settings.targetLanguage },
                    set: { model.setTargetLanguage($0) }
                )) {
                    ForEach(TargetLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }

                Toggle(
                    "Show source text below the translation",
                    isOn: Binding(
                        get: { model.settings.showSourceText },
                        set: { model.setShowSourceText($0) }
                    )
                )

                Text("Uses Apple's built-in Translation framework directly.")
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                Text(model.status.message)
                    .foregroundStyle(statusColor)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(18)
    }

    private var statusColor: Color {
        switch model.status {
        case .idle:
            return .secondary
        case .running:
            return .green
        case .error:
            return .yellow
        }
    }
}
