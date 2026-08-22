import SwiftUI

/// Entry point. With a file argument the app runs headless and prints the
/// summary to stdout — useful for scripting and for testing the pipeline
/// without driving the UI. Otherwise it launches the normal window.
@main
enum Entry {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let removedAudioCommands: Set<String> = [
            "--request-audio-permission",
            "--blackhole-audio-server"
        ]
        // Ignore stale Audio Helper launch requests restored by macOS after the
        // removed real-time subtitle feature. Always show the normal app.
        if arguments.contains(where: removedAudioCommands.contains) {
            MeetingScribeApp.main()
            return
        }
        let args = arguments.filter { !$0.hasPrefix("-") }
        if let path = args.first, FileManager.default.fileExists(atPath: path) {
            CommandLineRunner.run(path: path)
        } else {
            MeetingScribeApp.main()
        }
    }
}

struct MeetingScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 760, height: 540)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Keep the app from getting stuck in the macOS state where the process is
/// running but every window restored as closed/hidden.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            self.showAnExistingWindowIfNeeded(in: NSApp)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // If a window already exists, only raise that window. Returning true
        // here asks SwiftUI's WindowGroup to create another one, so repeated
        // Dock/Finder open events can produce an apparent endless window loop.
        if showAnExistingWindowIfNeeded(in: sender) { return false }

        // No usable window remains; allow WindowGroup to create exactly one.
        return true
    }

    @discardableResult
    private func showAnExistingWindowIfNeeded(in application: NSApplication) -> Bool {
        application.activate(ignoringOtherApps: true)
        guard let window = application.windows.first(where: isMainWindow) else { return false }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return true
    }

    private func isMainWindow(_ window: NSWindow) -> Bool {
        window.canBecomeKey
            && window.styleMask.contains(.titled)
    }
}

/// Headless driver: same pipeline as the UI, progress on stderr, summary on stdout.
enum CommandLineRunner {

    /// The pipeline is `@MainActor`, so the main thread must stay free to run
    /// it — blocking here on a semaphore would deadlock. Drive the run loop
    /// instead and exit from inside the task.
    static func run(path: String) {
        let url = URL(fileURLWithPath: path)

        Task { @MainActor in
            let runner = PipelineRunner()
            var lastStage: PipelineRunner.Stage = .idle
            var lastDetail = ""

            let watcher = Task { @MainActor in
                while !Task.isCancelled {
                    if runner.stage != lastStage {
                        lastStage = runner.stage
                        lastDetail = ""
                        log("▸ \(runner.stage.label)")
                    }
                    if !runner.detail.isEmpty, runner.detail != lastDetail {
                        lastDetail = runner.detail
                        log("    \(runner.detail)")
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }

            runner.run(url: url)
            while runner.isRunning {
                try? await Task.sleep(for: .milliseconds(300))
            }
            watcher.cancel()

            if let error = runner.error {
                log("错误：\(error)")
                exit(1)
            }

            print(runner.summary)
            if let saved = try? runner.saveOutputs() {
                log("▸ 已保存 → \(saved.path)")
            }
            exit(0)
        }

        // Keep the main thread servicing the run loop until the task exits.
        RunLoop.main.run()
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    }
}
