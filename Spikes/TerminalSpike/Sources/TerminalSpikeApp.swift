import AppKit
import SwiftUI

@main
struct TerminalSpikeApp: App {
    @NSApplicationDelegateAdaptor(SpikeAppDelegate.self) private var appDelegate
    @State private var title = "TerminalSpike"

    init() {
        OctetTerminalRuntime.configure(overrides: """
        background = 050505
        window-padding-x = 6
        window-padding-y = 4
        """)
    }

    var body: some Scene {
        Window("TerminalSpike", id: "main") {
            OctetTerminalView(
                command: ProcessInfo.processInfo.environment["SPIKE_COMMAND"] ?? "/bin/zsh -l",
                environment: ["TERM": "xterm-256color", "COLORTERM": "truecolor"],
                workingDirectory: NSHomeDirectory(),
                onTitleChange: { title = $0 },
                onExit: { NSApp.terminate(nil) }
            )
            .frame(minWidth: 400, minHeight: 300)
            .navigationTitle(title)
        }
        .defaultSize(width: 900, height: 600)
    }
}

final class SpikeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        SpikeSnapshot.start()
    }
}
