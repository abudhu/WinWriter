import XCTest
import Darwin
@testable import WinWriterCore

final class AuthorizedFormatterTests: XCTestCase {
    private func channels() throws -> (FormatChannel, FormatChannel) {
        var sockets: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return try (FormatChannel(sockets[0]), FormatChannel(sockets[1]))
    }

    func testClosingBeforeEraseTerminatesWaitingSession() throws {
        let (app, formatter) = try channels()
        defer { formatter.close() }
        app.close()
        XCTAssertThrowsError(try formatter.receive())
        XCTAssertThrowsError(try formatter.send(FormatMessage(kind: "ready")))
    }

    func testWrongPeerCannotAuthorizeFormatting() throws {
        let (app, formatter) = try channels()
        defer { app.close(); formatter.close() }
        XCTAssertThrowsError(try formatter.requirePeer(uid: UInt32.max))
    }

    func testNonRootInvocationCannotStartFormatter() {
        guard geteuid() != 0 else { return }
        XCTAssertEqual(PrivilegedFormatter.run(arguments: ["/tmp/not-a-socket", "disk0", "1", "1", "501", "2"]), 1)
    }

    func testOversizedMessageIsRejectedWithoutDesynchronizingChannel() throws {
        let (app, formatter) = try channels()
        defer { app.close(); formatter.close() }
        XCTAssertThrowsError(try app.send(FormatMessage(kind: "log", text: String(repeating: "x", count: 65_537))))
        try app.send(FormatMessage(kind: "erase"))
        let command = try formatter.receive()
        XCTAssertEqual(command.kind, "erase")
        XCTAssertNil(command.text)
    }
}
