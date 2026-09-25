import XCTest
@testable import MeetingScribe

final class ShellTests: XCTestCase {
    func testCancellationTerminatesChildProcess() async {
        let task = Task {
            try await Shell.run("/bin/sleep", ["30"])
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testTimeoutHasDistinctError() async {
        do {
            _ = try await Shell.run("/bin/sleep", ["30"], timeout: 0.1)
            XCTFail("Expected timeout")
        } catch Shell.Failure.timedOut {
            // Expected.
        } catch {
            XCTFail("Expected timedOut, got \(error)")
        }
    }
}
