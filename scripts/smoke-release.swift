import AppKit
import Foundation

// Exercises the downloaded app and its bundled tool without authorizing or
// formatting any disk. Run on a native Intel or Apple silicon macOS host.
struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeFailure(message) }
}

func run(_ executable: URL, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    try require(process.terminationStatus == 0, "Failed: \(executable.lastPathComponent) \(arguments)")
}

func smoke() throws {
    try require(CommandLine.arguments.count == 3, "Usage: smoke-release.swift APP_PATH EXPECTED_ARCH")
    #if arch(x86_64)
    let architecture = "x86_64"
    #elseif arch(arm64)
    let architecture = "arm64"
    #else
    throw SmokeFailure("Unsupported host architecture")
    #endif
    try require(CommandLine.arguments[2] == architecture, "Smoke process architecture mismatch")
    let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let tool = app.appendingPathComponent("Contents/Resources/wimlib-imagex")
    let files = FileManager.default
    let temporary = files.temporaryDirectory.appendingPathComponent("WinWriter-native-smoke-\(UUID().uuidString)")
    try files.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: temporary) }

    let source = temporary.appendingPathComponent("source")
    let output = temporary.appendingPathComponent("extracted")
    try files.createDirectory(at: source, withIntermediateDirectories: true)
    try files.createDirectory(at: output, withIntermediateDirectories: true)
    let names = ["boot.bin", "setup.bin", "install.bin", "unicode-é.bin"]
    for (index, name) in names.enumerated() {
        let payload = Data((0..<(512 * 1024)).map { UInt8(truncatingIfNeeded: $0 + index * 17) })
        try payload.write(to: source.appendingPathComponent(name))
    }
    let wim = temporary.appendingPathComponent("fixture.wim")
    let swm = temporary.appendingPathComponent("install.swm")
    let references = "--ref=\(temporary.path)/install*.swm"
    try run(tool, ["--version"])
    try run(tool, ["capture", source.path, wim.path, "Native smoke", "--compress=none", "--check"])
    try run(tool, ["split", wim.path, swm.path, "1", "--no-check"])
    try require(files.fileExists(atPath: temporary.appendingPathComponent("install2.swm").path), "Split must produce multiple parts")
    try run(tool, ["verify", swm.path, references])
    try run(tool, ["apply", swm.path, "1", output.path, references])
    for name in names {
        let original = try Data(contentsOf: source.appendingPathComponent(name))
        let restored = try Data(contentsOf: output.appendingPathComponent(name))
        try require(original == restored, "WIM round-trip data mismatch: \(name)")
    }
    print("PASS: native \(architecture) WIM capture/split/verify/extract; all file bytes match")

    let process = Process()
    process.executableURL = app.appendingPathComponent("Contents/MacOS/WinWriter")
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 3))
    try require(process.isRunning, "Application exited before showing its window")
    let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
    let mainWindow = windows.first { window in
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == process.processIdentifier,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
              let width = bounds["Width"], let height = bounds["Height"] else { return false }
        return width >= 600 && height >= 600
    }
    try require(mainWindow != nil, "Application did not create its main window")
    print("PASS: native \(architecture) release app launched and created its main window")
    print("PASS: no authorization, formatting, or physical USB writes were performed")
}

do {
    try smoke()
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
