#if os(macOS)
import SwiftUI
import JumpUI

@main
struct JumpForgeApp: App {
    var body: some Scene {
        Window("JumpForge", id: "main") {
            JumpForgeRootView()
        }
        .defaultSize(width: 1200, height: 820)
    }
}
#endif
