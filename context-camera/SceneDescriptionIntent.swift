//
//  SceneDescriptionIntent.swift
//  context-camera
//
//  Siri shortcut support for opening the app and triggering a one-shot
//  description flow inside the app itself.
//

import AppIntents

struct OpenContextCamIntent: AppIntent {
    static let title: LocalizedStringResource = "Open ContextCam"
    static let description = IntentDescription("Open ContextCam and prepare a quick description capture.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        ShortcutLaunchManager.requestCaptureOnNextLaunch()
        return .result()
    }
}

struct ContextCamShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenContextCamIntent(),
            phrases: [
                "Describe with \(.applicationName)",
                "\u{5FEB}\u{901F}\u{63CF}\u{8FF0} \(.applicationName)"
            ],
            shortTitle: "Quick Describe",
            systemImageName: "camera.viewfinder"
        )
    }
}
