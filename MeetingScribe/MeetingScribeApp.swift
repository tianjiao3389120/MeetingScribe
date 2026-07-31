import SwiftUI

/// Entry point. With a file argument the app runs headless and prints the
/// summary to stdout — useful for scripting and for testing the pipeline
/// without driving the UI. Otherwise it launches the normal window.
@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first, FileManager.default.fileExists(atPath: path) {
            CommandLineRunner.run(path: path)
        } else {
            MeetingScribeApp.main()
        }
    }
}

struct MeetingScribeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
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
