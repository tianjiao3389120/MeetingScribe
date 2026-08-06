import Darwin
import XCTest
@testable import MeetingScribe

final class RealtimeAudioProtocolTests: XCTestCase {
    func testStopCommandRoundTrip() {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer {
            Darwin.close(sockets[0])
            Darwin.close(sockets[1])
        }
        let clientSocket = sockets[0]
        let serverSocket = sockets[1]

        let received = expectation(description: "Helper receives stop command")
        DispatchQueue.global().async {
            XCTAssertTrue(BlackHoleAudioProtocol.waitForStop(on: serverSocket))
            received.fulfill()
        }

        XCTAssertTrue(BlackHoleAudioProtocol.sendStop(to: clientSocket))
        wait(for: [received], timeout: 1)
    }

    func testClosedSocketDoesNotCountAsStopAcknowledgement() {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        Darwin.close(sockets[0])
        defer { Darwin.close(sockets[1]) }

        XCTAssertFalse(BlackHoleAudioProtocol.waitForStop(on: sockets[1]))
    }
}
