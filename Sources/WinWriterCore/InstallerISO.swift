import Foundation

public enum InstallerISO {
    /// Mounts only in a newly created private directory. Cleanup never detaches a
    /// pre-existing user mount and never recursively removes a still-mounted ISO.
    public static func withMounted(iso: URL, cancellation: Cancellation,
                                   events: @escaping EventSink, body: (URL) throws -> Void) throws {
        let source = iso.resolvingSymlinksInPath()
        guard try InstallerSnapshot.at(source).isRegular else { throw WriterError("Select a regular Windows ISO file.") }
        let workspace = try privateDirectory(prefix: "WinWriter-ISO")
        let mount = workspace.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var attemptedAttach = false
        func cleanup() throws {
            if attemptedAttach, try InstallerIO.isMountPoint(mount) {
                events(.log("Detaching the private ISO mount."))
                do {
                    try ProcessRunner.run("/usr/bin/hdiutil", ["detach", mount.path])
                } catch {
                    events(.log("Normal ISO detach failed; retrying forced detach of this app's private mount only."))
                    try ProcessRunner.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
                }
            }
            guard !(try InstallerIO.isMountPoint(mount)) else {
                throw WriterError("The private source ISO is still mounted at \(mount.path). Its temporary directory was left intact for safe manual detachment.")
            }
            try FileManager.default.removeItem(at: workspace)
        }
        do {
            try cancellation.check()
            events(.progress(stage: "Mounting ISO read-only", fraction: nil, cancellable: true))
            events(.log("Attaching \(source.lastPathComponent) read-only; no source files will be modified."))
            attemptedAttach = true
            let data = try ProcessRunner.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen",
                "-owners", "off", "-plist", "-mountpoint", mount.path, source.path], cancellation: cancellation)
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let entities = plist["system-entities"] as? [[String: Any]],
                  entities.contains(where: { entity in
                      guard let path = entity["mount-point"] as? String else { return false }
                      return URL(fileURLWithPath: path).standardizedFileURL.path == mount.standardizedFileURL.path
                  }), try InstallerIO.isMountPoint(mount) else {
                throw WriterError("hdiutil did not attach the ISO at the app's private mount point.")
            }
            try cancellation.check()
            try body(mount)
        } catch {
            do { try cleanup() } catch let cleanupError {
                events(.log("Source cleanup failed: \(cleanupError.localizedDescription)"))
            }
            throw error
        }
        try cleanup()
    }

    static func privateDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }
}
