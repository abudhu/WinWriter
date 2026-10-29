import Foundation
import Security
import Darwin

/// One authorized formatter for one selected disk. It waits for preflight without
/// relying on macOS's short-lived authorization cache. No service is installed.
final class AuthorizedFormatter {
    private let target: DiskTarget
    private var channel: FormatChannel?

    private init(target: DiskTarget, channel: FormatChannel) {
        self.target = target
        self.channel = channel
    }

    static func authorize(_ target: DiskTarget, events: @escaping EventSink) throws -> AuthorizedFormatter {
        guard let executable = Bundle.main.executableURL else { throw WriterError("Cannot locate the app executable.") }
        // sockaddr_un has a short path limit; /tmp contains only this private socket,
        // never commands, credentials, or files opened by the root formatter.
        let socketDirectory = URL(fileURLWithPath: "/tmp").appendingPathComponent("WinWriter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: socketDirectory) }
        let listener = try FormatChannel.listen(at: socketDirectory.appendingPathComponent("control").path)
        defer { Darwin.close(listener.descriptor) }
        events(.progress(stage: "Administrator approval — before any ISO verification or erasure", fraction: nil, cancellable: false))
        events(.log("Approve macOS authorization now. No disk is erased until source preflight succeeds. Your password is handled only by macOS."))
        let arguments = [executable.path, "--format-session", listener.path, target.id,
                         String(target.registryID), String(target.size), String(getuid()), String(getpid())]
        let command = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            + " </dev/null >/dev/null 2>&1 &"
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        // Execute within our app, not osascript: macOS attributes the prompt to
        // Win11 USB Creator. The background formatter has no access to the ISO.
        let request = {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: "do shell script \"\(literal)\" with administrator privileges") else {
                throw WriterError("Cannot create the macOS authorization request.")
            }
            script.executeAndReturnError(&error)
            if let error {
                if (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue == -128 { throw CancellationError() }
                throw WriterError("Administrator authorization failed: \(error[NSAppleScript.errorMessage] as? String ?? error.description). No disk was erased.")
            }
        }
        if Thread.isMainThread { try request() }
        else { try DispatchQueue.main.sync(execute: request) }
        let channel = try FormatChannel.accept(listener.descriptor)
        do {
            try channel.requirePeer(uid: 0)
            let ready = try channel.receive()
            guard ready.kind == "ready" else { throw WriterError(ready.text ?? "The authorized formatter could not prepare.") }
            events(.log("Administrator approval complete. The formatter is ready for this USB; no later password prompt is needed."))
            return AuthorizedFormatter(target: target, channel: channel)
        } catch {
            channel.close()
            throw error
        }
    }

    func erase(events: @escaping EventSink) throws -> URL {
        guard let channel else { throw WriterError("This formatting authorization has already been used or closed.") }
        defer { close() }
        try DiskService.validate(target)
        try channel.send(FormatMessage(kind: "erase"))
        while true {
            let message = try channel.receive()
            switch message.kind {
            case "log": events(.log(message.text ?? ""))
            case "done": return try DiskService.mountedVolume(target)
            case "error": throw WriterError(message.text ?? "USB formatting failed.")
            default: throw WriterError("Unexpected response from the authorized formatter.")
            }
        }
    }

    func close() {
        channel?.close()
        channel = nil
    }

    deinit { close() }
}

public enum PrivilegedFormatter {
    /// The only root entry point: authenticate the originating app, wait for one
    /// command, recheck the bound disk identity, then run fixed diskutil arguments.
    public static func run(arguments: [String]) -> Int32 {
        var channel: FormatChannel?
        defer { channel?.close() }
        do {
            guard geteuid() == 0, arguments.count == 6,
                  let identity = UInt64(arguments[2]), let size = Int64(arguments[3]),
                  let uid = UInt32(arguments[4]), uid != 0,
                  let pid = Int32(arguments[5]), pid > 1 else {
                throw WriterError("Invalid authorized formatting session.")
            }
            let connection = try FormatChannel.connect(to: arguments[0])
            channel = connection
            try connection.requirePeer(uid: uid, pid: pid)
            let target = DiskTarget(id: arguments[1], name: "USB", size: size, registryID: identity)
            try DiskService.validate(target)
            try connection.send(FormatMessage(kind: "ready"))
            // EOF (cancel, preflight failure, app crash) exits without erasing.
            let request = try connection.receive()
            guard request.kind == "erase", request.text == nil else { throw WriterError("Invalid formatting command.") }
            try DiskService.validate(target)
            try ProcessRunner.run("/usr/sbin/diskutil", ["eraseDisk", "FAT32", "WIN11", "MBRFormat", "/dev/\(target.id)"],
                                  output: { line in try? connection.send(FormatMessage(kind: "log", text: line)) })
            try connection.send(FormatMessage(kind: "done"))
            return 0
        } catch {
            try? channel?.send(FormatMessage(kind: "error", text: error.localizedDescription))
            return 1
        }
    }
}

struct FormatMessage: Codable {
    let kind: String
    var text: String? = nil
}

/// Length-bounded IPC; the kernel audit token authenticates both signed peers,
/// rather than trusting a PID lookup or a caller-writable request file.
final class FormatChannel: @unchecked Sendable {
    private var descriptor: Int32
    init(_ descriptor: Int32) throws {
        self.descriptor = descriptor
        var yes: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(descriptor)
            self.descriptor = -1
            throw WriterError("Cannot secure formatter connection.")
        }
    }

    static func listen(at path: String) throws -> (descriptor: Int32, path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WriterError("Cannot create formatter connection.") }
        do {
            try address(path) { guard Darwin.bind(fd, $0, $1) == 0 else { throw WriterError("Cannot bind formatter connection.") } }
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, Darwin.listen(fd, 1) == 0 else {
                throw WriterError("Cannot listen for the formatter.")
            }
            return (fd, path)
        } catch { Darwin.close(fd); throw error }
    }

    static func accept(_ fd: Int32) throws -> FormatChannel {
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        var status: Int32
        repeat { status = poll(&event, 1, 30_000) } while status < 0 && errno == EINTR
        guard status > 0, event.revents & Int16(POLLIN) != 0 else {
            throw WriterError("The authorized formatter did not connect. No disk was erased. Start again.")
        }
        let peer = Darwin.accept(fd, nil, nil)
        guard peer >= 0 else { throw WriterError("Cannot accept the formatter connection.") }
        return try FormatChannel(peer)
    }

    static func connect(to path: String) throws -> FormatChannel {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WriterError("Cannot create formatter connection.") }
        do {
            try address(path) { guard Darwin.connect(fd, $0, $1) == 0 else { throw WriterError("The requesting app is no longer available.") } }
        } catch { Darwin.close(fd); throw error }
        return try FormatChannel(fd)
    }

    private static func address(_ path: String, body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void) throws {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw WriterError("Formatter socket path is too long.") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    func requirePeer(uid: uid_t, pid: pid_t? = nil) throws {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout.size(ofValue: token))
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout.size(ofValue: token) else { throw WriterError("Cannot authenticate the formatter connection.") }
        let values = withUnsafeBytes(of: token) { Array($0.bindMemory(to: UInt32.self)) }
        guard values[1] == uid, pid == nil || values[5] == UInt32(pid!) else { throw WriterError("Formatter peer identity mismatch.") }
        var ownCode: SecCode?
        var ownStaticCode: SecStaticCode?
        var requirement: SecRequirement?
        var peer: SecCode?
        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess, let ownStaticCode,
              SecCodeCopyDesignatedRequirement(ownStaticCode, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCopyGuestWithAttributes(nil, attributes, [], &peer) == errSecSuccess, let peer,
              SecCodeCheckValidity(peer, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw WriterError("The formatter and app must have matching valid code signatures. Reinstall the complete signed app.")
        }
    }

    func send(_ message: FormatMessage) throws {
        let data = try JSONEncoder().encode(message)
        guard data.count <= 65_536 else { throw WriterError("Formatter response is too large.") }
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try write($0) }
        try data.withUnsafeBytes { try write($0) }
    }

    func receive() throws -> FormatMessage {
        let header = try read(count: 4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= 65_536 else { throw WriterError("Invalid formatter response length.") }
        return try JSONDecoder().decode(FormatMessage.self, from: read(count: Int(length)))
    }

    private func write(_ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw WriterError("The formatter connection closed.") }
            offset += count
        }
    }

    private func read(count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let result = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw WriterError("The formatter connection closed.") }
                offset += result
            }
        }
        return data
    }

    func close() {
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
    }
    deinit { close() }
}
