import SwiftUI

/// Native SwiftUI application entry point. AppDelegate owns the menu-bar item
/// and standard macOS window so left and right clicks can behave differently.
@main
struct EC25ToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
