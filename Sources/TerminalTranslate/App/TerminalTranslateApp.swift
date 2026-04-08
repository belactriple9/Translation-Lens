import SwiftUI

@main
struct LensApp: App {
    @StateObject private var model = OverlayViewModel()

    var body: some Scene {
        WindowGroup {
            OverlayView(model: model)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .defaultSize(width: 520, height: 340)
        .commands {
            CommandMenu("Lens") {
                Button(model.isPaused ? "Resume Lens" : "Pause Lens") {
                    model.togglePause()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Refresh Capture") {
                    model.triggerRefresh(force: true)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Toggle(
                    "Show Source Text",
                    isOn: Binding(
                        get: { model.settings.showSourceText },
                        set: { model.setShowSourceText($0) }
                    )
                )
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
