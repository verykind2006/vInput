import SwiftUI

@main
struct vInputApp: App {
    var body: some Scene {
        MenuBarExtra("vInput", systemImage: "mic") {
            Text("vInput")
            Divider()
            Button("退出") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
