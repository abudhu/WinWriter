import Foundation

public struct InstallerReceipt: Sendable {
    public let files: [InstallerDigest]
    public let bootImage: String
    public let installImage: String
    public let splitParts: [String]
    /// True only when copying collected source digests for independent readback.
    public let verifyContents: Bool
}

/// Writes only to an already-mounted FAT volume. It never discovers, formats,
/// unmounts, or ejects a disk; the caller owns those destructive boundaries.
public final class InstallerWriter: @unchecked Sendable {
    private let wimlib: URL
    private let splitPartMiB: Int
    private let verifyContents: Bool

    /// Full Verification prepares content digests and generated image integrity tables.
    /// The caller still invokes source verification and independent USB readback separately.
    public init(wimlib: URL, verifyContents: Bool = false) {
        self.wimlib = wimlib
        self.verifyContents = verifyContents
        splitPartMiB = InstallerPlanner.splitPartMiB
    }

    // Test-only small split parts; not exposed through the app or its command line.
    init(wimlib: URL, splitPartMiB: Int, verifyContents: Bool = false) {
        self.wimlib = wimlib
        self.verifyContents = verifyContents
        self.splitPartMiB = splitPartMiB
    }

    public func verifySourceImages(plan: InstallerPlan, cancellation: Cancellation,
                                   events: @escaping EventSink) throws {
        events(.log("Checking WIM image integrity, not publisher authenticity. Use an ISO obtained from Microsoft."))
        try verifyImage(plan.root.appendingPathComponent(plan.bootImage), cancellation: cancellation, events: events)
        switch plan.payload {
        case .image(let path):
            guard let file = plan.files.first(where: { $0.path == path }) else { throw WriterError("The install image is absent from the copy plan.") }
            try verifyImage(file.source, cancellation: cancellation, events: events)
        case .split(let source, _), .needsConversion(let source):
            try verifyImage(source, cancellation: cancellation, events: events)
        case .preSplit(let first, let parts):
            try validateSplitParts(parts, at: plan.root)
            try verifyImage(plan.root.appendingPathComponent(first), split: true, cancellation: cancellation, events: events)
        }
    }

    public func write(plan: InstallerPlan, to root: URL, cancellation: Cancellation,
                      events: @escaping EventSink) throws -> InstallerReceipt {
        try cancellation.check()
        guard splitPartMiB > 0, splitPartMiB <= InstallerPlanner.splitPartMiB else { throw WriterError("Invalid split part size.") }
        if case .needsConversion = plan.payload { throw WriterError("The solid install image must be converted locally before writing the USB.") }
        try InstallerIO.requireFATVolume(root)
        try plan.requireCapacity(InstallerIO.freeBytes(at: root))
        for file in plan.files {
            guard try InstallerSnapshot.at(file.source) == file.snapshot else {
                throw WriterError("Installer source changed after preflight: \(file.path).")
            }
        }
        for directory in plan.directories {
            try cancellation.check()
            let destination = root.appendingPathComponent(directory, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw WriterError("Refusing to merge into an existing destination directory: \(directory). Use a freshly formatted volume.")
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        }
        let progress = InstallerByteProgress(stage: "Copying installer files", total: plan.copyBytes, events: events)
        var digests: [InstallerDigest] = []
        if verifyContents { digests.reserveCapacity(plan.files.count) }
        for file in plan.files {
            try cancellation.check()
            events(.log("Copying \(file.path) (\(InstallerPlanner.bytes(file.size)))"))
            if let digest = try InstallerIO.copy(file, to: root.appendingPathComponent(file.path),
                                                 verifyContents: verifyContents, cancellation: cancellation,
                                                 progress: progress.advance) {
                digests.append(digest)
            }
        }
        progress.finish()
        let installImage: String
        let splitParts: [String]
        switch plan.payload {
        case .image(let path):
            installImage = path; splitParts = []
        case .preSplit(let first, let parts):
            installImage = first; splitParts = parts
            try validateSplitParts(parts, at: root)
        case .split(let source, let destination):
            let before = try InstallerSnapshot.at(source)
            guard before.isRegular else { throw WriterError("The install image changed before splitting.") }
            guard !(try InstallerWIMHeader.read(source)).allowsSolidResources else {
                throw WriterError("Solid WIMs must be converted before writing the USB.")
            }
            events(.progress(stage: "Splitting install image into FAT32-sized SWM files", fraction: nil, cancellable: true))
            events(.log("Splitting \(source.lastPathComponent) into \(splitPartMiB) MiB parts\(verifyContents ? " with integrity tables" : ""). A single WIM resource may exceed the requested size; every output's header, part number, and size will be checked."))
            let arguments = ["split", source.path, root.appendingPathComponent(destination).path,
                             String(splitPartMiB), verifyContents ? "--check" : "--nocheck"]
            try run(arguments, cancellation: cancellation, events: events)
            guard try InstallerSnapshot.at(source) == before else { throw WriterError("The source changed while splitting its install image.") }
            let directory = (destination as NSString).deletingLastPathComponent
            let entries = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            splitParts = entries.compactMap { url -> String? in
                let path = directory + "/" + url.lastPathComponent
                return InstallerPlanner.splitPartNumber(path, directory: directory) == nil ? nil : path
            }.sorted { InstallerPlanner.splitPartNumber($0, directory: directory)! < InstallerPlanner.splitPartNumber($1, directory: directory)! }
            try validateSplitParts(splitParts, at: root)
            installImage = destination
            for path in splitParts {
                try cancellation.check()
                try InstallerIO.flushFile(root.appendingPathComponent(path))
            }
        case .needsConversion:
            throw WriterError("The install image was not prepared.")
        }
        try cancellation.check()
        events(.log(verifyContents
                    ? "All file writes flushed. The USB must be unmounted and remounted before independent readback."
                    : "All file writes flushed. Full Verification was not requested; content readback is skipped."))
        return InstallerReceipt(files: digests, bootImage: plan.bootImage, installImage: installImage,
                                splitParts: splitParts, verifyContents: verifyContents)
    }

    public func verify(receipt: InstallerReceipt, at root: URL, cancellation: Cancellation,
                       events: @escaping EventSink) throws {
        guard receipt.verifyContents, !receipt.files.isEmpty else {
            throw WriterError("This write was not prepared for Full Verification. Create the USB again with Full Verification enabled to check its contents.")
        }
        try InstallerIO.requireFATVolume(root)
        let total = try receipt.files.reduce(Int64(0)) { try InstallerPlanner.add($0, $1.size) }
        let progress = InstallerByteProgress(stage: "Verifying USB readback (SHA-256)", total: total, events: events)
        for expected in receipt.files {
            try cancellation.check()
            let url = root.appendingPathComponent(expected.path)
            events(.log("Reading back \(expected.path)"))
            try InstallerIO.verify(expected, at: url, cancellation: cancellation, progress: progress.advance)
        }
        progress.finish()
        try verifyImage(root.appendingPathComponent(receipt.bootImage), cancellation: cancellation, events: events)
        if !receipt.splitParts.isEmpty { try validateSplitParts(receipt.splitParts, at: root) }
        try verifyImage(root.appendingPathComponent(receipt.installImage), split: !receipt.splitParts.isEmpty,
                        cancellation: cancellation, events: events)
        try cancellation.check()
        events(.log("Readback verified: copied files match their source SHA-256, and boot/install images pass wimlib integrity and content-checksum verification. This checks integrity, not Microsoft's publisher authenticity."))
    }

    func convert(source: URL, to destination: URL, cancellation: Cancellation,
                 events: @escaping EventSink) throws {
        let size = try InstallerSnapshot.at(source).size
        let free = try InstallerIO.freeBytes(at: destination.deletingLastPathComponent())
        let minimum = try InstallerPlanner.add(size, 256 * 1_048_576)
        guard free >= minimum else {
            throw WriterError("Not enough local free space to start install-image conversion. At least \(InstallerPlanner.bytes(minimum)) is needed; non-solid WIM output may require substantially more. No USB has been erased.")
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw WriterError("The local conversion destination already exists.") }
        events(.log("Converting all install images to a local non-solid LZX WIM. \(InstallerPlanner.bytes(free)) is free locally; expansion depends on the image. The USB will not be erased unless conversion and capacity checks succeed."))
        events(.progress(stage: "Converting solid install image locally", fraction: nil, cancellable: true))
        let arguments = ["export", source.path, "all", destination.path, "--compress=LZX",
                         verifyContents ? "--check" : "--nocheck"]
        try run(arguments, cancellation: cancellation, events: events)
        let header = try InstallerWIMHeader.read(destination)
        guard !header.allowsSolidResources, header.part == 1, header.totalParts == 1, header.imageCount > 0 else {
            throw WriterError("wimlib did not produce a complete standard non-solid WIM.")
        }
        if verifyContents { try verifyImage(destination, cancellation: cancellation, events: events) }
    }

    private func verifyImage(_ url: URL, split: Bool = false, cancellation: Cancellation,
                             events: @escaping EventSink) throws {
        try cancellation.check()
        let header = try InstallerWIMHeader.read(url)
        guard header.part == 1, header.imageCount > 0, split || header.totalParts == 1 else {
            throw WriterError("Missing images or incomplete WIM: \(url.lastPathComponent).")
        }
        events(.progress(stage: "Checking image integrity: \(url.lastPathComponent)", fraction: nil, cancellable: true))
        events(.log("Verifying decompression and content checksums in \(url.lastPathComponent)"))
        var arguments = ["verify", url.path]
        if split {
            let directory = escapeGlob(url.deletingLastPathComponent().path)
            // Passed as one literal argv item: wimlib, not a shell, expands this glob.
            arguments.append("--ref=\(directory)/[Ii][Nn][Ss][Tt][Aa][Ll][Ll]*.[Ss][Ww][Mm]")
        }
        try run(arguments, cancellation: cancellation, events: events)
    }

    private func validateSplitParts(_ parts: [String], at root: URL) throws {
        guard let first = parts.first else { throw WriterError("wimlib did not produce any split install images.") }
        let directory = (first as NSString).deletingLastPathComponent
        let firstHeader = try InstallerWIMHeader.read(root.appendingPathComponent(first))
        guard firstHeader.part == 1, firstHeader.totalParts == parts.count, firstHeader.imageCount > 0 else {
            throw WriterError("The split install image is incomplete: expected \(firstHeader.totalParts) parts, found \(parts.count).")
        }
        for (index, path) in parts.enumerated() {
            let url = root.appendingPathComponent(path)
            let state = try InstallerSnapshot.at(url)
            guard state.isRegular, state.size > 0, state.size <= InstallerPlanner.maximumFATFileSize else {
                throw WriterError("Split output \(path) does not fit FAT32. A WIM resource can exceed the requested part size; this installer cannot be represented safely as these SWM files.")
            }
            let header = try InstallerWIMHeader.read(url)
            guard InstallerPlanner.splitPartNumber(path, directory: directory) == index + 1,
                  header.part == index + 1, header.totalParts == parts.count, header.guid == firstHeader.guid else {
                throw WriterError("Split install image has a missing, misnamed, or unrelated part: \(path).")
            }
        }
    }

    private func escapeGlob(_ path: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(path.utf8.count)
        for character in path {
            if "\\*?[]".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    private func run(_ arguments: [String], cancellation: Cancellation, events: @escaping EventSink) throws {
        guard FileManager.default.isExecutableFile(atPath: wimlib.path) else {
            throw WriterError("The bundled wimlib-imagex is missing or not executable. Reinstall the complete app; no Homebrew runtime is supported.")
        }
        let progress = InstallerToolProgress(arguments: arguments)
        try ProcessRunner.run(wimlib.path, arguments, cancellation: cancellation, output: { line in
            events(.log(line))
            if let event = progress.event(for: line) { events(event) }
        })
    }
}
