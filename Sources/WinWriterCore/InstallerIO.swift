import Foundation
import CryptoKit
import Darwin

public struct InstallerDigest: Sendable {
    public let path: String
    public let size: Int64
    public let sha256: String
}

/// Small, bounded-memory operations shared by copying and independent readback.
enum InstallerIO {
    private static let bufferSize = 1_048_576

    static func posix(_ operation: String, _ url: URL) -> WriterError {
        let code = errno
        var message = "\(operation) failed for \(url.lastPathComponent): \(String(cString: strerror(code))) (\(code))."
        if code == EPERM || code == EACCES {
            message += " For USB access, allow System Settings > Privacy & Security > Files & Folders > Win11 USB Creator > Removable Volumes. For ISO source access, reselect the ISO using the file chooser and check the app's Files & Folders permissions."
        }
        return WriterError(message)
    }

    static func copy(_ file: InstallerFile, to destination: URL, verifyContents: Bool = false,
                     cancellation: Cancellation, progress: (Int64) -> Void) throws -> InstallerDigest? {
        try cancellation.check()
        let input = open(file.source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw posix("Open source", file.source) }
        defer { close(input) }
        guard try InstallerSnapshot.descriptor(input, url: file.source) == file.snapshot else {
            throw WriterError("The source changed after preflight: \(file.path). Nothing from this file can be trusted; start again.")
        }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard output >= 0 else { throw posix("Create USB file", destination) }
        var outputOpen = true
        defer { if outputOpen { close(output) } }
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var hash: SHA256? = verifyContents ? SHA256() : nil
        var total: Int64 = 0
        try buffer.withUnsafeMutableBytes { bytes in
            while true {
                try cancellation.check()
                let count = Darwin.read(input, bytes.baseAddress, bytes.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posix("Read source", file.source)
                }
                if count == 0 { break }
                total = try InstallerPlanner.add(total, Int64(count))
                guard total <= file.size else { throw WriterError("Source grew while copying: \(file.path).") }
                hash?.update(bufferPointer: UnsafeRawBufferPointer(start: bytes.baseAddress, count: count))
                var written = 0
                while written < count {
                    try cancellation.check()
                    let result = Darwin.write(output, bytes.baseAddress!.advanced(by: written), count - written)
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw posix("Write USB file", destination)
                    }
                    guard result > 0 else { throw WriterError("The USB stopped accepting data for \(file.path).") }
                    written += result
                }
                progress(Int64(count))
            }
        }
        guard total == file.size, try InstallerSnapshot.descriptor(input, url: file.source) == file.snapshot else {
            throw WriterError("Source changed while copying: \(file.path).")
        }
        try flush(output, url: destination)
        let closeResult = close(output)
        outputOpen = false
        guard closeResult == 0 else { throw posix("Close USB file", destination) }
        guard let hash else { return nil }
        return InstallerDigest(path: file.path, size: total, sha256: hex(hash.finalize()))
    }

    private static func digest(_ url: URL, path: String, cancellation: Cancellation,
                               progress: (Int64) -> Void) throws -> InstallerDigest {
        try cancellation.check()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix("Open file for verification", url) }
        defer { close(descriptor) }
        let before = try InstallerSnapshot.descriptor(descriptor, url: url)
        guard before.isRegular else { throw WriterError("Verification expected a regular file: \(path).") }
        if fcntl(descriptor, F_NOCACHE, 1) != 0 {
            throw posix("Enable uncached USB readback", url)
        }
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var hash = SHA256()
        var total: Int64 = 0
        try buffer.withUnsafeMutableBytes { bytes in
            while true {
                try cancellation.check()
                let count = Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posix("Read file for verification", url)
                }
                if count == 0 { break }
                hash.update(bufferPointer: UnsafeRawBufferPointer(start: bytes.baseAddress, count: count))
                total = try InstallerPlanner.add(total, Int64(count))
                progress(Int64(count))
            }
        }
        guard total == before.size, try InstallerSnapshot.descriptor(descriptor, url: url) == before else {
            throw WriterError("File changed during verification: \(path).")
        }
        return InstallerDigest(path: path, size: total, sha256: hex(hash.finalize()))
    }

    static func verify(_ expected: InstallerDigest, at url: URL, cancellation: Cancellation,
                       progress: (Int64) -> Void = { _ in }) throws {
        let state = try InstallerSnapshot.at(url)
        guard state.isRegular, state.size == expected.size, state.size <= InstallerPlanner.maximumFATFileSize else {
            throw WriterError("USB readback size/type mismatch: \(expected.path). The installer is not verified.")
        }
        let actual = try digest(url, path: expected.path, cancellation: cancellation, progress: progress)
        guard actual.sha256 == expected.sha256 else {
            throw WriterError("USB readback SHA-256 mismatch: \(expected.path). The installer is not verified; the USB may be faulty.")
        }
    }

    static func flush(_ descriptor: Int32, url: URL) throws {
        guard fsync(descriptor) == 0 else { throw posix("Flush file writes", url) }
        // F_FULLFSYNC is not implemented by every FAT/USB driver. fsync above is
        // mandatory; checked unmount/ejection provides the filesystem-wide flush.
        if fcntl(descriptor, F_FULLFSYNC) != 0 {
            let code = errno
            guard code == ENOTSUP || code == EINVAL || code == ENOTTY else {
                throw posix("Flush USB hardware cache", url)
            }
        }
    }

    static func flushFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix("Open split image for flushing", url) }
        defer { close(descriptor) }
        try flush(descriptor, url: url)
    }

    static func freeBytes(at url: URL) throws -> Int64 {
        var filesystem = statfs()
        guard statfs(url.path, &filesystem) == 0 else { throw posix("Read available disk space", url) }
        let blocks = UInt64(filesystem.f_bavail)
        let blockSize = UInt64(filesystem.f_bsize)
        let (size, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
        guard !overflow, size <= UInt64(Int64.max) else { throw WriterError("Available disk space is outside the supported range.") }
        return Int64(size)
    }

    static func requireFATVolume(_ root: URL) throws {
        guard try InstallerSnapshot.at(root).isDirectory else { throw WriterError("Destination is not a real directory.") }
        var filesystem = statfs()
        guard statfs(root.path, &filesystem) == 0 else { throw posix("Read destination filesystem", root) }
        let kind = withUnsafeBytes(of: &filesystem.f_fstypename) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        guard kind == "msdos" else { throw WriterError("The destination must be a mounted FAT32 volume, not \(kind).") }
    }

    static func isMountPoint(_ url: URL) throws -> Bool {
        var filesystem = statfs()
        guard statfs(url.path, &filesystem) == 0 else { throw posix("Read mount information", url) }
        let mount = withUnsafeBytes(of: &filesystem.f_mntonname) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return URL(fileURLWithPath: mount).standardizedFileURL.path == url.standardizedFileURL.path
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var result = [UInt8]()
        result.reserveCapacity(64)
        for byte in digest { result.append(alphabet[Int(byte >> 4)]); result.append(alphabet[Int(byte & 15)]) }
        return String(decoding: result, as: UTF8.self)
    }
}

struct InstallerWIMHeader {
    let version: UInt32
    let guid: Data
    let part: Int
    let totalParts: Int
    let imageCount: UInt32
    var allowsSolidResources: Bool { version == 0xE00 }

    static func read(_ url: URL) throws -> InstallerWIMHeader {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw InstallerIO.posix("Open WIM header", url) }
        defer { close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: 48)
        var consumed = 0
        try bytes.withUnsafeMutableBytes { buffer in
            while consumed < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: consumed), buffer.count - consumed)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw InstallerIO.posix("Read WIM header", url)
                }
                guard count > 0 else { throw WriterError("Truncated WIM header: \(url.lastPathComponent).") }
                consumed += count
            }
        }
        func uint16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func uint32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        guard bytes.prefix(8).elementsEqual([77, 83, 87, 73, 77, 0, 0, 0]), uint32(8) == 208,
              [UInt32(0x10D00), UInt32(0xE00)].contains(uint32(12)), uint16(40) > 0, uint16(42) >= uint16(40) else {
            throw WriterError("Invalid or unsupported Windows WIM header: \(url.lastPathComponent).")
        }
        return InstallerWIMHeader(version: uint32(12), guid: Data(bytes[24..<40]), part: uint16(40),
                                  totalParts: uint16(42), imageCount: uint32(44))
    }
}

final class InstallerByteProgress {
    private let stage: String
    private let total: Int64
    private let events: EventSink
    private var completed: Int64 = 0
    private var lastEmission = ProcessInfo.processInfo.systemUptime
    init(stage: String, total: Int64, events: @escaping EventSink) {
        self.stage = stage; self.total = total; self.events = events
        events(.progress(stage: stage, fraction: 0, cancellable: true))
    }
    func advance(_ count: Int64) {
        completed += count
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastEmission >= 0.12 {
            emit(); lastEmission = now
        }
    }
    func finish() { completed = total; emit() }
    private func emit() {
        events(.progress(stage: stage, fraction: total == 0 ? 1 : min(1, Double(completed) / Double(total)), cancellable: true))
    }
}
