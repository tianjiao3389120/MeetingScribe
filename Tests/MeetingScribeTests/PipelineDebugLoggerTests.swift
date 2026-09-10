import XCTest
@testable import MeetingScribe

final class PipelineDebugLoggerTests: XCTestCase {
    func testNodeLogUsesReadableProtocolAndExplicitEmptyValues() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try PipelineDebugSession(root: root, pausesAtNodeStart: false)

        session.progress("提取画面", "扫描进度 10%")
        session.progress("提取画面", "扫描进度 35%")
        session.progress("提取画面", "扫描进度 70%")
        session.engineEnd(tool: "/bin/tool", exitCode: 0, stdout: "", stderr: "")

        let log = try String(contentsOf: session.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("[NODE PROGRESS · 提取画面]"))
        XCTAssertTrue(log.contains("扫描进度 35%"))
        XCTAssertEqual(log.components(separatedBy: "[NODE PROGRESS · 提取画面]").count - 1, 3)
        XCTAssertTrue(log.contains("[ENGINE END · /bin/tool]"))
        XCTAssertTrue(log.contains("stdout：\n<空>"))
        XCTAssertTrue(log.contains("stderr：\n<空>"))
    }

    func testPercentageProgressDeduplicatesAndRendersBar() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try PipelineDebugSession(root: root, pausesAtNodeStart: false)

        session.progressPercent("音频提取", label: "提取进度", fraction: 0.001)
        session.progressPercent("音频提取", label: "提取进度", fraction: 0.004)
        session.progressPercent("音频提取", label: "提取进度", fraction: 0.01)
        session.progressPercent("音频提取", label: "提取进度", fraction: 1)

        let log = try String(contentsOf: session.logURL, encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "[NODE PROGRESS · 音频提取]").count - 1, 3)
        XCTAssertTrue(log.contains("[░░░░░░░░░░░░░░░░░░░░] 0%"))
        XCTAssertTrue(log.contains("[████████████████████] 100%"))
    }

    func testPauseWaitsForContinueFileThenDeletesIt() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try PipelineDebugSession(root: root, pausesAtNodeStart: true)

        let task = Task { try await session.beginNode("OCR", input: "画面数量：2") }
        try await waitUntil { FileManager.default.fileExists(atPath: session.logURL.path)
            && ((try? String(contentsOf: session.logURL, encoding: .utf8))?
                .contains("[TERMINAL WAIT · OCR]") == true) }
        FileManager.default.createFile(atPath: session.continueURL.path, contents: Data())
        try await task.value

        let log = try String(contentsOf: session.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("[TERMINAL CONTINUE RECEIVED · OCR]"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.continueURL.path))
    }

    func testShellArchivesRawStreamsWithoutDuplicatingNoiseInPipelineLog() async throws {
        let root = temporaryRoot()
        defer {
            PipelineDebugRegistry.install(nil)
            try? FileManager.default.removeItem(at: root)
        }
        let session = try PipelineDebugSession(root: root, pausesAtNodeStart: false)
        PipelineDebugRegistry.install(session)

        _ = try await Shell.check("/bin/sh", ["-c", "printf output; printf diagnostic >&2"])

        let log = try String(contentsOf: session.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("[ENGINE START · /bin/sh]"))
        XCTAssertFalse(log.contains("[ENGINE STDERR · /bin/sh]"))
        XCTAssertTrue(log.contains("完整内容："))
        let files = try FileManager.default.contentsOfDirectory(at: session.directory,
                                                                 includingPropertiesForKeys: nil)
        let stdout = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix("stdout.log") })
        let stderr = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix("stderr.log") })
        XCTAssertEqual(try String(contentsOf: stdout, encoding: .utf8), "output")
        XCTAssertEqual(try String(contentsOf: stderr, encoding: .utf8), "diagnostic")
    }

    func testTranscriptProgressDeduplicatesNearbyTimecodes() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try PipelineDebugSession(root: root, pausesAtNodeStart: false)

        session.transcriptProgress("语音转录", seconds: 10, duration: 100)
        session.transcriptProgress("语音转录", seconds: 10.2, duration: 100)
        session.transcriptProgress("语音转录", seconds: 15, duration: 100)
        session.transcriptProgress("语音转录", seconds: 20, duration: 100)

        let log = try String(contentsOf: session.logURL, encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "[NODE PROGRESS · 语音转录]").count - 1, 2)
        XCTAssertTrue(log.contains("（10%）"))
        XCTAssertTrue(log.contains("（20%）"))
    }

    func testRunSummaryIncludesTokenAttributionAndEngineCount() async throws {
        let root = temporaryRoot()
        defer {
            PipelineDebugRegistry.install(nil)
            try? FileManager.default.removeItem(at: root)
        }
        let session = try PipelineDebugSession(root: root, pausesAtNodeStart: false)
        PipelineDebugRegistry.install(session)
        try await session.beginNode("模型调用", input: "输入")
        session.engineStart(tool: "/bin/codex", arguments: [])
        session.engineEnd(tool: "/bin/codex", exitCode: 0,
                          stdout: "tokens used\n4,703", stderr: "")
        session.endNode("模型调用", output: "完成")
        session.runSummary(status: "成功", cache: "转录命中", screen: "发送 5")

        let log = try String(contentsOf: session.logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("[RUN SUMMARY · 流水线]"))
        XCTAssertTrue(log.contains("Token · 模型调用：4703"))
        XCTAssertTrue(log.contains("Token · 合计：4703"))
        XCTAssertTrue(log.contains("外部引擎：1 次"))
        XCTAssertTrue(log.contains("耗时："))
    }

    func testEngineProgressIsCompactedAndLongStreamsGoToFiles() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try PipelineDebugSession(root: root, pausesAtNodeStart: false)
        let tool = "/bin/python"
        session.engineStart(tool: tool, arguments: [])
        session.engineStderr(tool: tool, text: "PROGRESS 1 1000\nPROGRESS 2 1000\nPROGRESS 10 1000\n")
        let longError = String(repeating: "diagnostic line\n", count: 1_000)
        session.engineEnd(tool: tool, exitCode: 0, stdout: "", stderr: longError)

        let log = try String(contentsOf: session.logURL, encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "[ENGINE STDERR · /bin/python]").count - 1, 2)
        XCTAssertTrue(log.contains("PROGRESS 0%（1/1000）"))
        XCTAssertTrue(log.contains("PROGRESS 1%（10/1000）"))
        XCTAssertTrue(log.contains("完整内容："))
        let stderrPath = try XCTUnwrap(log.split(separator: "\n")
            .first { $0.contains("engine-01-python-stderr.log") })
        let path = stderrPath.replacingOccurrences(of: "stderr 文件：", with: "")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), longError)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pipeline-debug-tests-\(UUID().uuidString)")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<40 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Condition was not met before timeout")
    }
}
