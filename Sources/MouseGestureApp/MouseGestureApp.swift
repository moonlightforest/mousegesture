import SwiftUI

@main
struct MouseGestureApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            appDelegate.settingsContent
        }
    }
}
