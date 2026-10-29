import Foundation
import Darwin

public struct InstallerFile: Sendable {
    public let source: URL
    public let path: String
    public let size: Int64
    let snapshot: InstallerSnapshot
}

public enum InstallPayload: Sendable {
    case image(path: String)
    case split(source: URL, destination: String)
    case preSplit(first: String, parts: [String])
    case needsConversion(source: URL)
}

public struct InstallerPlan: Sendable {
    public let root: URL
    public let directories: [String]
    public let files: [InstallerFile]
    public let bootImage: String
    public let payload: InstallPayload
    /// Conservative physical-capacity estimate, including cluster, FAT, and split overhead.
    public let requiredCapacity: Int64
    public let copyBytes: Int64

    public func requireCapacity(_ bytes: Int64) throws {
        guard bytes >= requiredCapacity else {
            throw WriterError("The installer needs approximately \(InstallerPlanner.bytes(requiredCapacity)) including FAT32 and split overhead, but the USB has \(InstallerPlanner.bytes(bytes)). Use a larger USB; 8 GB or larger is recommended, and some installers need more.")
        }
    }
}

public enum InstallerPlanner {
    public static let maximumFATFileSize: Int64 = 4_294_967_295
    public static let splitPartMiB = 3800
    private static let cluster: Int64 = 65_536

    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    public static func plan(root: URL, convertedInstallWIM: URL? = nil,
                            cancellation: Cancellation = Cancellation()) throws -> InstallerPlan {
        try plan(root: root, convertedInstallWIM: convertedInstallWIM, cancellation: cancellation,
                 splitThreshold: maximumFATFileSize)
    }

    // Internal threshold enables small real-WIM split tests without changing production limits.
    static func plan(root: URL, convertedInstallWIM: URL? = nil,
                     cancellation: Cancellation = Cancellation(), splitThreshold: Int64) throws -> InstallerPlan {
        guard splitThreshold > 0, splitThreshold <= maximumFATFileSize else {
            throw WriterError("Invalid split threshold.")
        }
        let rootState = try InstallerSnapshot.at(root)
        guard rootState.isDirectory else { throw WriterError("The installer source must be a real directory, not a symbolic link.") }
        let manager = FileManager.default
        var files: [InstallerFile] = []
        var directories: [String] = []
        var paths: [String: String] = [:]
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, error in
            enumerationError = error
            return false
        }) else { throw WriterError("Cannot read the mounted installer.") }
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            try cancellation.check()
            let normalizedPath = url.standardizedFileURL.path
            guard normalizedPath.hasPrefix(prefix) else { throw WriterError("An installer path escaped its source directory.") }
            let path = String(normalizedPath.dropFirst(prefix.count))
            try validatePath(path)
            let key = pathKey(path)
            if let previous = paths.updateValue(path, forKey: key) {
                throw WriterError("FAT32 cannot distinguish these installer paths: \(previous) and \(path).")
            }
            let state = try InstallerSnapshot.at(url)
            if state.isDirectory {
                directories.append(path)
            } else if state.isRegular {
                files.append(InstallerFile(source: url, path: path, size: state.size, snapshot: state))
            } else {
                throw WriterError("Unsupported installer entry \(path). Symbolic links and special files cannot be copied to FAT32.")
            }
        }
        if let error = enumerationError { throw error }
        let byPath = Dictionary(uniqueKeysWithValues: files.map { (pathKey($0.path), $0) })
        func required(_ path: String) throws -> InstallerFile {
            guard let entry = byPath[pathKey(path)], entry.size > 0 else {
                throw WriterError("This is not a recognizable Windows UEFI installer: missing or empty \(path).")
            }
            return entry
        }
        let boot = try required("sources/boot.wim")
        _ = try required("setup.exe")
        guard ["efi/boot/bootx64.efi", "efi/boot/bootaa64.efi"].contains(where: { (byPath[pathKey($0)]?.size ?? 0) > 0 }) else {
            throw WriterError("The ISO does not contain a Windows x64 or ARM64 UEFI bootloader.")
        }
        let wim = byPath[pathKey("sources/install.wim")]
        let esd = byPath[pathKey("sources/install.esd")]
        let swm = byPath[pathKey("sources/install.swm")]
        guard [wim, esd, swm].compactMap({ $0 }).count == 1 else {
            throw WriterError("Expected exactly one install.wim, install.esd, or install.swm in sources. The ISO is missing its install image or has ambiguous install images.")
        }
        let install = wim ?? esd ?? swm!
        guard install.size > 0 else { throw WriterError("The Windows install image is empty.") }
        let sourcesPath = (install.path as NSString).deletingLastPathComponent
        let splitDestination = sourcesPath + "/install.swm"
        var payload: InstallPayload
        var splitSize: Int64 = 0
        if let converted = convertedInstallWIM {
            guard (esd != nil || wim != nil), install.size > splitThreshold else {
                throw WriterError("A converted WIM is only accepted for an oversized install image.")
            }
            let state = try InstallerSnapshot.at(converted)
            guard state.isRegular, state.size > 0 else { throw WriterError("The converted install WIM is not a nonempty regular file.") }
            files.removeAll { $0.path == install.path }
            if state.size > splitThreshold {
                payload = .split(source: converted, destination: splitDestination)
                splitSize = state.size
            } else {
                let destination = sourcesPath + "/install.wim"
                guard paths[pathKey(destination)] == nil || pathKey(destination) == pathKey(install.path) else {
                    throw WriterError("Converted WIM destination collides with an ISO entry.")
                }
                files.append(InstallerFile(source: converted, path: destination, size: state.size, snapshot: state))
                payload = .image(path: destination)
            }
        } else if install.size > splitThreshold && esd != nil {
            payload = .needsConversion(source: install.source)
            files.removeAll { $0.path == install.path }
            splitSize = install.size
        } else if install.size > splitThreshold && wim != nil {
            if try InstallerWIMHeader.read(install.source).allowsSolidResources {
                payload = .needsConversion(source: install.source)
            } else {
                payload = .split(source: install.source, destination: splitDestination)
            }
            files.removeAll { $0.path == install.path }
            splitSize = install.size
        } else if swm != nil {
            let parts = files.filter { splitPartNumber($0.path, directory: sourcesPath) != nil }
                .sorted { splitPartNumber($0.path, directory: sourcesPath)! < splitPartNumber($1.path, directory: sourcesPath)! }
            guard parts.enumerated().allSatisfy({ splitPartNumber($0.element.path, directory: sourcesPath) == $0.offset + 1 }) else {
                throw WriterError("The pre-split install image has missing or duplicate numbered SWM parts.")
            }
            payload = .preSplit(first: install.path, parts: parts.map(\.path))
        } else {
            payload = .image(path: install.path)
        }
        for file in files where file.size > maximumFATFileSize {
            throw WriterError("\(file.path) exceeds FAT32's 4,294,967,295-byte file limit. Only install.wim or install.esd can be transformed safely.")
        }
        if splitSize > 0 {
            // wimlib creates install.swm, install2.swm, ...; reject existing entries before any erase.
            for path in paths.values where pathKey((path as NSString).deletingLastPathComponent) == pathKey(sourcesPath) {
                let name = pathKey((path as NSString).lastPathComponent)
                if name.hasPrefix("INSTALL") && name.hasSuffix(".SWM") {
                    throw WriterError("Generated split install images would collide with \(path).")
                }
            }
        }
        var allocated: Int64 = cluster // root directory
        var copyBytes: Int64 = 0
        var directoryBytes = Dictionary(uniqueKeysWithValues: ([""] + directories).map { ($0, Int64(64)) })
        for path in directories + files.map(\.path) {
            let parent = (path as NSString).deletingLastPathComponent
            let nameLength = (path as NSString).lastPathComponent.utf16.count
            directoryBytes[parent, default: 64] = try add(directoryBytes[parent, default: 64], Int64(32 * (1 + (nameLength + 12) / 13)))
        }
        for size in directoryBytes.values { allocated = try add(allocated, rounded(size)) }
        for file in files {
            copyBytes = try add(copyBytes, file.size)
            allocated = try add(allocated, rounded(file.size))
        }
        if splitSize > 0 {
            // Integrity tables, duplicated per-part metadata, final cluster slack, and growth reserve.
            let partCount = splitSize / (Int64(splitPartMiB) * 1_048_576) + 2
            allocated = try add(allocated, splitSize)
            allocated = try add(allocated, splitSize / 20)
            allocated = try add(allocated, try multiply(partCount, 16 * 1_048_576 + cluster))
        }
        allocated = try add(allocated, allocated / 32 + 32 * 1_048_576)
        return InstallerPlan(root: root, directories: directories.sorted { a, b in
            let aDepth = a.split(separator: "/").count, bDepth = b.split(separator: "/").count
            return aDepth == bDepth ? a < b : aDepth < bDepth
        }, files: files.sorted { $0.path < $1.path }, bootImage: boot.path,
           payload: payload, requiredCapacity: allocated, copyBytes: copyBytes)
    }

    static func pathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.uppercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func validatePath(_ path: String) throws {
        guard !path.isEmpty, path.utf16.count <= 32_760 else { throw WriterError("Installer path is too long for FAT32: \(path)") }
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            let name = String(component)
            let stem = pathKey(String(name.split(separator: ".", omittingEmptySubsequences: false).first ?? ""))
            let reserved = ["CON", "PRN", "AUX", "NUL", "CLOCK$", "CONIN$", "CONOUT$"]
            let numberedDevice = ["COM", "LPT"].contains { prefix in
                guard stem.hasPrefix(prefix) else { return false }
                return ["1", "2", "3", "4", "5", "6", "7", "8", "9", "¹", "²", "³"].contains(String(stem.dropFirst(3)))
            }
            guard !name.isEmpty, name.utf16.count <= 255, name != ".", name != "..",
                  !name.hasSuffix("."), !name.hasSuffix(" "), !reserved.contains(stem), !numberedDevice,
                  !name.unicodeScalars.contains(where: { $0.value < 32 || "<>:\"\\|?*".unicodeScalars.contains($0) }) else {
                throw WriterError("Installer path cannot be represented safely on FAT32: \(path)")
            }
        }
    }

    static func splitPartNumber(_ path: String, directory: String) -> Int? {
        guard pathKey((path as NSString).deletingLastPathComponent) == pathKey(directory) else { return nil }
        let name = pathKey((path as NSString).lastPathComponent)
        if name == "INSTALL.SWM" { return 1 }
        guard name.hasPrefix("INSTALL"), name.hasSuffix(".SWM") else { return nil }
        let digits = name.dropFirst(7).dropLast(4)
        guard !digits.isEmpty, digits.first != "0", digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits), number >= 2 else { return nil }
        return number
    }

    static func add(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard !overflow, value >= 0 else { throw WriterError("Installer size exceeds the supported range.") }
        return value
    }

    private static func multiply(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (value, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow, value >= 0 else { throw WriterError("Installer size exceeds the supported range.") }
        return value
    }

    private static func rounded(_ size: Int64) throws -> Int64 {
        let adjusted = try add(size, cluster - 1)
        return adjusted / cluster * cluster
    }
}

struct InstallerSnapshot: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let mode: UInt16
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    var isRegular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    var isDirectory: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFDIR) }

    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size; mode = value.st_mode
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
    }

    static func at(_ url: URL) throws -> InstallerSnapshot {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw InstallerIO.posix("Read file information", url) }
        return InstallerSnapshot(value)
    }

    static func descriptor(_ descriptor: Int32, url: URL) throws -> InstallerSnapshot {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw InstallerIO.posix("Read open file information", url) }
        return InstallerSnapshot(value)
    }
}
