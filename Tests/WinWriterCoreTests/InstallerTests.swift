import XCTest
import Foundation
@testable import WinWriterCore

final class InstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("WinWriter-Tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }


    func testRequiredWindowsPathsAreCaseInsensitiveAndPreserved() throws {
        let source = try makeInstaller()
        let plan = try InstallerPlanner.plan(root: source)
        XCTAssertEqual(plan.bootImage, "SoUrCeS/BoOt.WiM")
        XCTAssertTrue(plan.files.contains { $0.path == "EfI/BoOt/BoOtX64.EfI" })
        if case .image(let path) = plan.payload { XCTAssertEqual(path, "SoUrCeS/InStAlL.WiM") }
        else { XCTFail("A small WIM should be copied unchanged") }
    }

    func testARM64UEFIBootloaderIsRecognized() throws {
        let source = try makeInstaller()
        try FileManager.default.moveItem(at: source.appendingPathComponent("EfI/BoOt/BoOtX64.EfI"),
                                         to: source.appendingPathComponent("EfI/BoOt/BOOTAA64.EFI"))
        let plan = try InstallerPlanner.plan(root: source)
        XCTAssertTrue(plan.files.contains { $0.path == "EfI/BoOt/BOOTAA64.EFI" })
    }

    func testFATFileBoundaryIsInclusiveAndOversizedWIMSplits() throws {
        let source = try makeInstaller()
        let install = source.appendingPathComponent("SoUrCeS/InStAlL.WiM")
        try resize(install, to: InstallerPlanner.maximumFATFileSize)
        if case .image = try InstallerPlanner.plan(root: source).payload {} else {
            XCTFail("Exactly 4,294,967,295 bytes fits FAT32")
        }
        try resize(install, to: InstallerPlanner.maximumFATFileSize + 1)
        let plan = try InstallerPlanner.plan(root: source)
        if case .split(_, let destination) = plan.payload { XCTAssertEqual(destination, "SoUrCeS/install.swm") }
        else { XCTFail("The first byte over the FAT32 limit must trigger splitting") }
        XCTAssertGreaterThan(plan.requiredCapacity, InstallerPlanner.maximumFATFileSize + 1)
    }

    func testOversizedNonInstallPayloadIsRejectedBeforeWriting() throws {
        let source = try makeInstaller()
        let other = source.appendingPathComponent("large.bin")
        try Data([1]).write(to: other)
        try resize(other, to: InstallerPlanner.maximumFATFileSize + 1)
        XCTAssertThrowsError(try InstallerPlanner.plan(root: source))
    }

    func testOversizedESDRequiresLocalConversionAndCanReplan() throws {
        let source = try makeInstaller()
        let esd = source.appendingPathComponent("SoUrCeS/install.esd")
        try FileManager.default.moveItem(at: source.appendingPathComponent("SoUrCeS/InStAlL.WiM"), to: esd)
        try resize(esd, to: InstallerPlanner.maximumFATFileSize + 1)
        if case .needsConversion = try InstallerPlanner.plan(root: source).payload {} else {
            XCTFail("Oversized ESD must be converted before erase")
        }
        let converted = root.appendingPathComponent("converted.wim")
        try wimHeader().write(to: converted)
        let plan = try InstallerPlanner.plan(root: source, convertedInstallWIM: converted)
        XCTAssertFalse(plan.files.contains { $0.path.lowercased().hasSuffix("install.esd") })
        XCTAssertTrue(plan.files.contains { $0.source == converted && $0.path == "SoUrCeS/install.wim" })
    }

    func testOversizedSolidWIMRequiresNormalization() throws {
        let source = try makeInstaller()
        let install = source.appendingPathComponent("SoUrCeS/InStAlL.WiM")
        try wimHeader(solid: true).write(to: install)
        try resize(install, to: InstallerPlanner.maximumFATFileSize + 1)
        if case .needsConversion = try InstallerPlanner.plan(root: source).payload {} else {
            XCTFail("Solid WIM resources cannot be passed directly to split")
        }
    }

    func testSymlinkIsRejectedRatherThanFollowed() throws {
        let source = try makeInstaller()
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("linked-file"),
                                                  withDestinationURL: source.appendingPathComponent("SeTuP.ExE"))
        XCTAssertThrowsError(try InstallerPlanner.plan(root: source))
    }

    func testUnrepresentableFATNamesAreRejected() throws {
        for path in ["sources/bad?.txt", "sources/trailing.", "sources/trailing ", "sources/CON.txt",
                     "sources/COM1", "sources/../outside", "sources/line\nfeed", "sources/" + String(repeating: "a", count: 256)] {
            XCTAssertThrowsError(try InstallerPlanner.validatePath(path), path)
        }
        XCTAssertNoThrow(try InstallerPlanner.validatePath("sources/日本語/normal-file.txt"))
        XCTAssertEqual(InstallerPlanner.pathKey("Sources/é.txt"), InstallerPlanner.pathKey("SOURCES/e\u{301}.TXT"))
    }

    func testIncompletePresplitImageIsRejected() throws {
        let source = try makeInstaller()
        try FileManager.default.moveItem(at: source.appendingPathComponent("SoUrCeS/InStAlL.WiM"),
                                         to: source.appendingPathComponent("SoUrCeS/install.swm"))
        try wimHeader().write(to: source.appendingPathComponent("SoUrCeS/install3.swm"))
        XCTAssertThrowsError(try InstallerPlanner.plan(root: source))
    }

    func testInsufficientCapacityIncludesAllocationOverhead() throws {
        let plan = try InstallerPlanner.plan(root: makeInstaller())
        XCTAssertGreaterThan(plan.requiredCapacity, plan.copyBytes)
        XCTAssertThrowsError(try plan.requireCapacity(plan.requiredCapacity - 1))
        XCTAssertNoThrow(try plan.requireCapacity(plan.requiredCapacity))
    }

    func testSourceMutationAfterPlanningIsRejected() throws {
        let source = try makeInstaller()
        let plan = try InstallerPlanner.plan(root: source)
        let file = try XCTUnwrap(plan.files.first { $0.path == "SeTuP.ExE" })
        try Data("modified source".utf8).write(to: file.source)
        for verifyContents in [false, true] {
            XCTAssertThrowsError(try InstallerIO.copy(file, to: root.appendingPathComponent("copy.exe"),
                                                     verifyContents: verifyContents,
                                                     cancellation: Cancellation(), progress: { _ in }))
        }
    }

    func testDefaultCopyOmitsDigestWithoutSkippingDataOrProgress() throws {
        let source = try makeInstaller()
        let bytes = Data(repeating: 0xA5, count: 1_048_577)
        try bytes.write(to: source.appendingPathComponent("SeTuP.ExE"))
        let plan = try InstallerPlanner.plan(root: source)
        let file = try XCTUnwrap(plan.files.first { $0.path == "SeTuP.ExE" })
        let destination = root.appendingPathComponent("copy.exe")
        var copied: Int64 = 0
        let digest = try InstallerIO.copy(file, to: destination, cancellation: Cancellation(), progress: { copied += $0 })
        XCTAssertNil(digest)
        XCTAssertEqual(copied, file.size)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertThrowsError(try InstallerIO.copy(file, to: destination,
                                                 cancellation: Cancellation(), progress: { _ in }))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }


    func testSameSizeReadbackCorruptionFailsSHA256() throws {
        let source = try makeInstaller()
        let plan = try InstallerPlanner.plan(root: source)
        let file = try XCTUnwrap(plan.files.first { $0.path == "SeTuP.ExE" })
        let destination = root.appendingPathComponent("copy.exe")
        let receipt = try XCTUnwrap(InstallerIO.copy(file, to: destination, verifyContents: true,
                                                    cancellation: Cancellation(), progress: { _ in }))
        XCTAssertNoThrow(try InstallerIO.verify(receipt, at: destination, cancellation: Cancellation()))
        try Data([2]).write(to: destination)
        XCTAssertThrowsError(try InstallerIO.verify(receipt, at: destination, cancellation: Cancellation()))
        try Data([2, 3]).write(to: destination)
        XCTAssertThrowsError(try InstallerIO.verify(receipt, at: destination, cancellation: Cancellation()))
    }

    private func makeInstaller() throws -> URL {
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("SoUrCeS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("EfI/BoOt"), withIntermediateDirectories: true)
        try Data([1]).write(to: source.appendingPathComponent("SeTuP.ExE"))
        try Data([1]).write(to: source.appendingPathComponent("EfI/BoOt/BoOtX64.EfI"))
        try wimHeader().write(to: source.appendingPathComponent("SoUrCeS/BoOt.WiM"))
        try wimHeader().write(to: source.appendingPathComponent("SoUrCeS/InStAlL.WiM"))
        return source
    }

    private func resize(_ url: URL, to size: Int64) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size)) // sparse files; no multi-GB data allocations
    }

    /// Structural planner fixtures only, deliberately not represented as valid WIM contents.
    private func wimHeader(solid: Bool = false) -> Data {
        var bytes = [UInt8](repeating: 0, count: 208)
        bytes.replaceSubrange(0..<8, with: [77, 83, 87, 73, 77, 0, 0, 0])
        bytes[8] = 208
        if solid { bytes[13] = 14 } else { bytes[13] = 13; bytes[14] = 1 }
        bytes[40] = 1; bytes[42] = 1; bytes[44] = 1
        return Data(bytes)
    }
}
