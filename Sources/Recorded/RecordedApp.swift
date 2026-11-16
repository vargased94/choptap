import AppKit
import SwiftUI

@main
struct RecordedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Recorded") {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            window.isMovableByWindowBackground = false
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
        }
        runSelfTestIfRequested()
    }

    /// Modo de prueba de calidad: `Recorded --selftest <salida.caf> <segundos>`
    /// Graba el audio del sistema durante N segundos con el mismo grabador de la app y sale.
    private let selfTestRecorder = SystemAudioRecorder()

    private func runSelfTestIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), args.count > i + 2,
              let seconds = Double(args[i + 2]) else { return }
        let url = URL(fileURLWithPath: args[i + 1])
        var options = RecordingOptions()
        options.waitForAudio = false
        options.autoStopSeconds = nil
        Task { @MainActor in
            do {
                try await selfTestRecorder.start(writingTo: url, options: options)
                try await Task.sleep(for: .seconds(seconds))
                let frames = await selfTestRecorder.stop()
                print("selftest frames:", frames)
            } catch {
                try? "error: \(error.localizedDescription)".write(to: url.appendingPathExtension("error"), atomically: true, encoding: .utf8)
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
