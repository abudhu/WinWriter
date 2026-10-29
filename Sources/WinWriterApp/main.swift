import AppKit
import Darwin
import WinWriterCore

// A one-shot authorized formatter never starts AppKit or opens the ISO.
if CommandLine.arguments.dropFirst().first == "--format-session" {
    exit(PrivilegedFormatter.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let appDelegate = AppDelegate()
    application.setActivationPolicy(.regular)
    application.delegate = appDelegate
    withExtendedLifetime(appDelegate) { application.run() }
}
