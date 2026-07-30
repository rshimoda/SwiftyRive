// RiveInspector — a minimal macOS demo for SwiftyRive's dynamic API.
// Drop any .riv file to auto-discover its artboards and data-binding
// properties, rendered as live controls. macOS only.
#if os(macOS)
import AppKit
import SwiftUI

@main
struct RiveInspectorApp: App {
    init() {
        // Under `swift run` the process is a bare executable with no bundle;
        // promote it to a regular app and front the window.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("RiveInspector") {
            if ProbeMode.isActive {
                ProbeView()
            } else {
                ContentView()
                    .frame(minWidth: 760, minHeight: 480)
            }
        }
    }
}
#endif
