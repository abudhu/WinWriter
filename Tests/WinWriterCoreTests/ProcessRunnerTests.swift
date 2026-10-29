import XCTest
import Foundation
@testable import WinWriterCore

final class ProcessRunnerTests: XCTestCase {
    func testCarriageReturnProgressArrivesBeforeChildExit() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("WinWriter-stream-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let cancellation = Cancellation()
        let deadline = DispatchWorkItem { cancellation.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: deadline)
        defer { deadline.cancel() }
        // The child cannot exit until its first progress event reaches the consumer.
        // A reader that waits for a full buffer deadlocks until cancellation fails this test.
        let result = try ProcessRunner.run("/bin/sh", ["-c",
            "printf 'ready\\r'; while [ ! -e \"$1\" ]; do /bin/sleep 0.01; done; printf 'done\\n'",
            "stream-test", marker.path], cancellation: cancellation, output: { line in
                if line == "ready" { _ = FileManager.default.createFile(atPath: marker.path, contents: Data()) }
            })
        XCTAssertEqual(String(decoding: result, as: UTF8.self), "ready\rdone\n")
        XCTAssertFalse(cancellation.isCancelled)
    }
}
