// Hidden diagnostic mode: `swift run RiveInspector --probe [file.riv] [artboard]`.
// Verifies in a real window that runtime-originated data-binding writes flow
// back into a RiveDynamicInstance's mirror. Prints PROBE lines to stdout.
#if os(macOS)
import SwiftUI
@_spi(Probe) import SwiftyRive

enum ProbeMode {
    static var isActive: Bool { CommandLine.arguments.contains("--probe") }

    /// Unbuffered stdout logging: lines must not sit in a stdio buffer if the
    /// process is killed externally.
    static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    static var fileArgument: String {
        argument(offset: 1) ?? "LocalAssets/main.riv"
    }

    static var artboardArgument: String {
        argument(offset: 2) ?? "Animated_Text"
    }

    private static func argument(offset: Int) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--probe"), args.count > index + offset else {
            return nil
        }
        return args[index + offset]
    }
}

struct ProbeView: View {
    @State private var instance: RiveDynamicInstance?
    @State private var status = "Loading…"

    var body: some View {
        VStack {
            if let instance {
                RiveView(instance, artboard: ProbeMode.artboardArgument)
                    .frame(width: 480, height: 320)
            } else {
                Text(status)
            }
        }
        .task { await run() }
    }

    private func run() async {
        ProbeMode.log("PROBE: task started")
        do {
            let url = URL(fileURLWithPath: ProbeMode.fileArgument)
            ProbeMode.log("PROBE: loading \(url.path)")
            let document = try await RiveDocument.load(.url(url))
            ProbeMode.log("PROBE: document loaded")
            for line in await document.probeDumpViewModels(artboard: ProbeMode.artboardArgument) {
                ProbeMode.log("PROBE: \(line)")
            }
            let instance = try await document.makeDynamicInstance(artboard: ProbeMode.artboardArgument)
            self.instance = instance
            ProbeMode.log("PROBE: artboard = \(ProbeMode.artboardArgument)")
            ProbeMode.log("PROBE: properties = \(instance.properties.map(\.path).joined(separator: ", "))")
            ProbeMode.log("PROBE: initial mirror text = \(instance[string: "text"] ?? "nil")")

            // Let the view attach, bind the state machine, and render frames.
            try await Task.sleep(for: .seconds(1))

            // Write directly to the runtime, bypassing the mirror: the mirror
            // can only learn about it through the value stream.
            let sentinel = "STREAM-ECHO-\(Int.random(in: 1000...9999))"
            instance.probeRuntimeWrite(string: sentinel, at: "text")
            ProbeMode.log("PROBE: bypass-wrote sentinel '\(sentinel)' to runtime; waiting 2s of frames")

            try await Task.sleep(for: .seconds(2))
            let mirror = instance[string: "text"]
            let direct = await instance.probeRuntimeString(at: "text")
            ProbeMode.log("PROBE: after 2s mirror text = \(mirror ?? "nil")")
            ProbeMode.log("PROBE: after 2s direct text = \(direct ?? "nil")")

            if direct == sentinel {
                if mirror == sentinel {
                    ProbeMode.log("PROBE VERDICT: STREAMS-WORK — mirror received the runtime-side change via its value stream")
                } else {
                    ProbeMode.log("PROBE VERDICT: MIRROR-STALE — runtime holds the sentinel but the mirror shows '\(mirror ?? "nil")'")
                }
            } else {
                ProbeMode.log("PROBE VERDICT: INCONCLUSIVE — the bypass write never reached the runtime (direct = '\(direct ?? "nil")')")
            }
            exit(0)
        } catch {
            ProbeMode.log("PROBE ERROR: \(error)")
            exit(1)
        }
    }

    private func describe(_ value: Double?) -> String {
        value.map { String($0) } ?? "nil"
    }
}
#endif
