import XCTest
@testable import WinWriterCore

final class InstallerToolProgressTests: XCTestCase {
    func testPartIntegrityCannotResetOrCompleteOverallSplitProgress() throws {
        let progress = InstallerToolProgress(arguments: ["split", "/source/install.wim"])
        let split = try value(progress.event(for: "Splitting WIM: 3800 MiB of 7600 MiB (50%) written, part 1 of 2"))
        XCTAssertEqual(split.fraction, 0.5)
        for percent in [0, 100] {
            let integrity = try value(progress.event(for: "Calculating integrity table for WIM: 0 MiB of 3800 MiB (\(percent)%) done"))
            XCTAssertEqual(integrity.fraction, 0.5)
        }
        let next = try value(progress.event(for: "Splitting WIM: 5700 MiB of 7600 MiB (75%) written, part 2 of 2"))
        XCTAssertEqual(next.fraction, 0.75)
    }

    func testInvalidOrUnrelatedPercentagesDoNotInventProgress() {
        let progress = InstallerToolProgress(arguments: ["split", "/source/install.wim"])
        for line in ["Splitting WIM: (-1%) written", "Splitting WIM: (101%) written",
                     "Splitting WIM: (nan%) written", "file (50%).txt", "Splitting WIM: waiting"] {
            XCTAssertNil(progress.event(for: line))
        }
    }

    func testVerificationAndExportUseTheirOwnMeasuredPercentages() throws {
        let verify = InstallerToolProgress(arguments: ["verify", "/usb/install.swm"])
        XCTAssertEqual(try value(verify.event(for: "Verifying file data: 30 GiB of 40 GiB (75%) done")).fraction, 0.75)
        let export = InstallerToolProgress(arguments: ["export", "/source/install.esd"])
        XCTAssertEqual(try value(export.event(for: "Archiving file data: 1 GiB of 4 GiB (25%) done")).fraction, 0.25)
    }

    private func value(_ event: CreationEvent?) throws -> (stage: String, fraction: Double?) {
        guard case .progress(let stage, let fraction, _) = try XCTUnwrap(event) else {
            throw WriterError("Expected measured progress")
        }
        return (stage, fraction)
    }
}
