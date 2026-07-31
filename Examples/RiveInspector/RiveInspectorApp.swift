// RiveInspector — a minimal demo app for SwiftyRive's dynamic API.
// Open any .riv file (drag & drop, file picker, URL, or a recents entry) to
// auto-discover its artboards and data-binding properties, rendered as live
// controls. Runs on macOS via `swift run RiveInspector` and on iOS via
// Examples/RiveInspectorApp.
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct RiveInspectorApp: App {
    init() {
        #if os(macOS)
        // Under `swift run` the process is a bare executable with no bundle;
        // promote it to a regular app and front the window.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup("RiveInspector") {
            #if os(macOS)
            if ProbeMode.isActive {
                ProbeView()
            } else {
                ContentView()
                    .frame(minWidth: 760, minHeight: 480)
            }
            #else
            ContentView()
            #endif
        }
        #if os(macOS)
        if #available(macOS 15.0, *) {
            UtilityWindow("Utility", id: "utility") {
                Text("Utility")
                    .padding()
            }
        }
        Settings {
            EmptyView()
        }
        #endif
    }
}
