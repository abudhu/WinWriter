import Foundation
import Darwin

public enum ProcessRunner {
    /// Runs fixed executables with argument arrays, never interpolated shell commands.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String],
                           cancellation: Cancellation? = nil,
                           output: (@Sendable (String) -> Void)? = nil) throws -> Data {
        try cancellation?.check()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = output == nil ? stderr : stdout
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Close our write ends, otherwise reads cannot observe child EOF.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let errors = Capture()
        let group = DispatchGroup()
        if output == nil {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                while let data = try? stderr.fileHandleForReading.read(upToCount: 65_536), !data.isEmpty {
                    errors.append(data, limit: 1_048_576)
                }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        let stopState = StopState()
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler {
            guard cancellation?.isCancelled == true, process.isRunning else { return }
            if stopState.shouldKill() { kill(process.processIdentifier, SIGKILL) }
            else { process.terminate() }
        }
        timer.resume()
        defer {
            timer.cancel()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }
        var captured = Data()
        var pending = Data()
        var readError: Error?
        var buffer = [UInt8](repeating: 0, count: 65_536)
        do {
            while true {
                // FileHandle.read(upToCount:) can wait to fill a pipe buffer. POSIX
                // read returns available bytes so short CR-delimited progress is live.
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(stdout.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if count == 0 { break }
                buffer.withUnsafeBufferPointer {
                    captured.append($0.baseAddress!, count: count)
                    if output != nil { pending.append($0.baseAddress!, count: count) }
                }
                let limit = output == nil ? 16_777_216 : 1_048_576
                if captured.count > limit { captured.removeFirst(captured.count - limit) }
                if let output {
                    while let end = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                        let line = String(decoding: pending[..<end], as: UTF8.self)
                        pending.removeSubrange(...end)
                        if !line.isEmpty { output(line) }
                    }
                    if pending.count > 65_536 {
                        output(String(decoding: pending, as: UTF8.self))
                        pending.removeAll(keepingCapacity: true)
                    }
                }
            }
        } catch {
            readError = error
            if process.isRunning { process.terminate() }
        }
        if let output, !pending.isEmpty { output(String(decoding: pending, as: UTF8.self)) }
        process.waitUntilExit()
        group.wait()
        try cancellation?.check()
        if let readError { throw readError }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            let details = String(decoding: output == nil ? errors.data : captured, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw WriterError("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus)). \(details)")
        }
        return captured
    }
}

private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    func append(_ data: Data, limit: Int) {
        lock.lock(); defer { lock.unlock() }
        bytes.append(data)
        if bytes.count > limit { bytes.removeFirst(bytes.count - limit) }
    }
}

private final class StopState: @unchecked Sendable {
    private var firstRequest: Date?
    // Only accessed on the timer's serial event delivery.
    func shouldKill() -> Bool {
        if let firstRequest { return Date().timeIntervalSince(firstRequest) > 2 }
        firstRequest = Date()
        return false
    }
}
