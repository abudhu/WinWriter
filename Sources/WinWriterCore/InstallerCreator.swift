import Foundation

public final class USBCreator: @unchecked Sendable {
    public init() {}

    public func create(iso: URL, target: DiskTarget, verifyContents: Bool = false,
                       cancellation: Cancellation, events: @escaping EventSink) throws {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Creating a Windows installation USB")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try cancellation.check()
        events(.progress(stage: "Checking source and USB safety", fraction: nil, cancellable: true))
        try DiskService.validate(target)
        try DiskService.assertSourceIsNotOnTarget(iso, target: target)
        guard let executable = Bundle.main.executableURL,
              let resources = Bundle.main.resourceURL else { throw WriterError("Cannot locate the application bundle.") }
        try DiskService.assertSourceIsNotOnTarget(executable, target: target)
        let wimlib = resources.appendingPathComponent("wimlib-imagex")
        guard FileManager.default.isExecutableFile(atPath: wimlib.path) else {
            throw WriterError("The application is missing its bundled wimlib-imagex. Reinstall the complete app.")
        }
        let formatter = try AuthorizedFormatter.authorize(target, events: events)
        defer { formatter.close() }
        try cancellation.check()
        try DiskService.prepareVolumeAccess(target)
        let writer = InstallerWriter(wimlib: wimlib, verifyContents: verifyContents)
        try InstallerISO.withMounted(iso: iso, cancellation: cancellation, events: events) { root in
            events(.progress(stage: "Preflighting Windows installer contents", fraction: nil, cancellable: true))
            var plan = try InstallerPlanner.plan(root: root, cancellation: cancellation)
            switch plan.payload {
            case .needsConversion: break // Capacity is measured again from the actual converted WIM.
            default: try plan.requireCapacity(target.size)
            }
            events(.log("Recognized Windows UEFI installer. Boot files and Microsoft signatures will be copied byte-for-byte; no bootloader patches are applied."))
            if verifyContents {
                try writer.verifySourceImages(plan: plan, cancellation: cancellation, events: events)
            }
            var conversionDirectory: URL?
            defer {
                if let conversionDirectory {
                    do { try FileManager.default.removeItem(at: conversionDirectory) }
                    catch { events(.log("Could not remove local conversion workspace \(conversionDirectory.path): \(error.localizedDescription)")) }
                }
            }
            if case .needsConversion(let source) = plan.payload {
                let directory = try InstallerISO.privateDirectory(prefix: "WinWriter-Conversion")
                conversionDirectory = directory
                try DiskService.assertSourceIsNotOnTarget(directory, target: target)
                let converted = directory.appendingPathComponent("install.wim")
                try writer.convert(source: source, to: converted, cancellation: cancellation, events: events)
                plan = try InstallerPlanner.plan(root: root, convertedInstallWIM: converted, cancellation: cancellation)
            }
            try plan.requireCapacity(target.size)
            events(.log("Estimated USB capacity required, including allocation and split overhead: \(InstallerPlanner.bytes(plan.requiredCapacity)). An 8 GB or larger USB is recommended; actual installer contents determine the minimum."))
            // Recheck after potentially lengthy source verification/conversion.
            try cancellation.check()
            try DiskService.validate(target)
            try DiskService.assertSourceIsNotOnTarget(iso, target: target)
            try DiskService.assertSourceIsNotOnTarget(executable, target: target)
            events(.progress(stage: "Erasing USB — do not disconnect", fraction: nil, cancellable: false))
            let destination = try formatter.erase(events: events)
            do {
                try cancellation.check()
                let receipt = try writer.write(plan: plan, to: destination, cancellation: cancellation, events: events)
                try cancellation.check()
                if verifyContents {
                    events(.progress(stage: "Flushing and remounting USB for readback", fraction: nil, cancellable: false))
                    events(.log("Unmounting and remounting the selected USB before independent readback."))
                    let readback = try DiskService.remount(target)
                    try cancellation.check()
                    try writer.verify(receipt: receipt, at: readback, cancellation: cancellation, events: events)
                }
                try cancellation.check()
                events(.progress(stage: "Ejecting USB — do not disconnect", fraction: nil, cancellable: false))
                try DiskService.eject(target)
                events(.log(verifyContents ? "The verified USB has been ejected safely." : "The USB has been created and ejected safely. Full content verification was not requested."))
            } catch {
                events(.log("Creation did not complete. The selected USB may contain incomplete files; do not use it as an installer. Eject it in Finder before unplugging."))
                throw error
            }
        }
        events(.progress(stage: verifyContents ? "Complete — USB verified and safely ejected" : "Complete — USB created and safely ejected", fraction: 1, cancellable: false))
    }
}
