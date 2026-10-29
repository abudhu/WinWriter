import Foundation
import IOKit
import Darwin

public enum DiskService {
    private static let diskutil = "/usr/sbin/diskutil"

    public static func list() throws -> [DiskTarget] {
        let ids = try externalPhysicalIDs()
        let protected = try physicalDisks(containing: URL(fileURLWithPath: "/"))
        return ids.sorted().compactMap { id in
            guard !protected.contains(id), let info = try? diskInfo(id),
                  isEligible(info), let identity = try? registryID(id) else { return nil }
            return DiskTarget(id: id, name: (info["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "USB disk",
                              size: number(info["TotalSize"] ?? info["Size"]), registryID: identity)
        }
    }

    /// Fail closed: disk names can be recycled after unplugging a device.
    public static func validate(_ target: DiskTarget) throws {
        guard isWholeDiskID(target.id), target.registryID != 0,
              try externalPhysicalIDs().contains(target.id) else {
            throw WriterError("The selected USB is no longer connected as a physical external disk. Refresh and select it again.")
        }
        let info = try diskInfo(target.id)
        guard isEligible(info), number(info["TotalSize"] ?? info["Size"]) == target.size else {
            throw WriterError("The selected disk changed or is not a writable external USB disk.")
        }
        let protected = try physicalDisks(containing: URL(fileURLWithPath: "/"))
        guard !protected.contains(target.id) else { throw WriterError("Refusing to erase the running macOS disk.") }
        guard try registryID(target.id) == target.registryID else {
            throw WriterError("The USB was disconnected or replaced. Refresh and select it again.")
        }
    }

    public static func assertSourceIsNotOnTarget(_ source: URL, target: DiskTarget) throws {
        guard !(try physicalDisks(containing: source)).contains(target.id) else {
            throw WriterError("\(source.lastPathComponent) is on the USB being erased. Move it to your Mac first.")
        }
    }


    /// Trigger removable-volume privacy approval before lengthy source work.
    /// An unformatted disk has no mounted files for macOS to authorize yet.
    static func prepareVolumeAccess(_ target: DiskTarget) throws {
        try validate(target)
        let listing = try dictionary(ProcessRunner.run(diskutil, ["list", "-plist", "/dev/\(target.id)"]))
        guard let disks = listing["AllDisksAndPartitions"] as? [[String: Any]] else {
            throw WriterError("Cannot inspect the selected USB's mounted volumes.")
        }
        for disk in disks {
            let volumes = [disk] + (disk["Partitions"] as? [[String: Any]] ?? [])
            for volume in volumes {
                guard let path = volume["MountPoint"] as? String, !path.isEmpty else { continue }
                guard let directory = opendir(path) else {
                    throw WriterError("Cannot access the selected USB. In System Settings → Privacy & Security → Files & Folders → Win11 USB Creator, allow Removable Volumes, then try again. No disk was erased.")
                }
                closedir(directory)
            }
        }
    }

    public static func remount(_ target: DiskTarget) throws -> URL {
        try validate(target)
        // Unmount flushes the filesystem and invalidates mounted-file caches. Mount by
        // device identifier, never by a potentially duplicated WIN11 volume name.
        try ProcessRunner.run(diskutil, ["unmountDisk", "/dev/\(target.id)"])
        try validate(target)
        try ProcessRunner.run(diskutil, ["mount", "/dev/\(target.id)s1"])
        return try mountedVolume(target)
    }

    public static func eject(_ target: DiskTarget) throws {
        try validate(target)
        try ProcessRunner.run(diskutil, ["eject", "/dev/\(target.id)"])
    }

    static func mountedVolume(_ target: DiskTarget) throws -> URL {
        try validate(target)
        let info = try diskInfo(target.id + "s1")
        guard info["ParentWholeDisk"] as? String == target.id,
              info["FilesystemType"] as? String == "msdos",
              info["VolumeName"] as? String == "WIN11",
              let path = info["MountPoint"] as? String, path.hasPrefix("/Volumes/"),
              info["WritableVolume"] as? Bool == true else {
            throw WriterError("The formatted FAT32 partition did not mount on the selected USB.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func externalPhysicalIDs() throws -> [String] {
        let plist = try dictionary(ProcessRunner.run(diskutil, ["list", "-plist", "external", "physical"]))
        guard let ids = plist["WholeDisks"] as? [String] else { throw WriterError("Cannot enumerate external disks safely.") }
        return ids.filter(isWholeDiskID)
    }

    private static func isEligible(_ info: [String: Any]) -> Bool {
        let size = number(info["TotalSize"] ?? info["Size"])
        return info["WholeDisk"] as? Bool == true && info["Internal"] as? Bool == false
            && info["WritableMedia"] as? Bool == true
            && (info["BusProtocol"] as? String)?.caseInsensitiveCompare("USB") == .orderedSame
            && info["VirtualOrPhysical"] as? String != "Virtual"
            && info["OSInternalMedia"] as? Bool != true
            && size > 0 && size <= 2_199_023_255_040 // MBR's 32-bit sector address space.
    }

    private static func physicalDisks(containing url: URL) throws -> Set<String> {
        let resolved = url.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.volumeURLKey])
        let volume = values.volume ?? resolved
        let info = try diskInfo(volume.path)
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]], !stores.isEmpty {
            return try Set(stores.map { store in
                guard let id = store["APFSPhysicalStore"] as? String else {
                    throw WriterError("Cannot resolve the APFS source disk safely.")
                }
                let backing = try diskInfo(id)
                guard let whole = backing["ParentWholeDisk"] as? String, isWholeDiskID(whole) else {
                    throw WriterError("Cannot resolve the APFS physical disk safely.")
                }
                return whole
            })
        }
        if let id = info["ParentWholeDisk"] as? String, isWholeDiskID(id) { return [id] }
        if info["WholeDisk"] as? Bool == true, let id = info["DeviceIdentifier"] as? String, isWholeDiskID(id) { return [id] }
        throw WriterError("Cannot identify the disk containing \(url.lastPathComponent). Use a local file on your Mac.")
    }

    private static func diskInfo(_ value: String) throws -> [String: Any] {
        try dictionary(ProcessRunner.run(diskutil, ["info", "-plist", value]))
    }

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw WriterError("macOS returned invalid disk information.")
        }
        return value
    }

    private static func registryID(_ id: String) throws -> UInt64 {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, id))
        guard service != 0 else { throw WriterError("The selected USB disappeared.") }
        defer { IOObjectRelease(service) }
        var identity: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identity) == KERN_SUCCESS, identity != 0 else {
            throw WriterError("Cannot establish a safe identity for the selected USB.")
        }
        return identity
    }

    private static func isWholeDiskID(_ id: String) -> Bool {
        id.hasPrefix("disk") && id.count > 4 && id.dropFirst(4).utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    private static func number(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }
}
