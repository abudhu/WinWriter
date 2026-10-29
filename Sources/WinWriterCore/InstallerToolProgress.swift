import Foundation

/// Parses the pinned wimlib CLI's measured progress, never guesses from elapsed time.
final class InstallerToolProgress: @unchecked Sendable {
    private let imageName: String
    private let splitting: Bool
    private var splitFraction: Double = 0

    init(arguments: [String]) {
        splitting = arguments.first == "split"
        imageName = arguments.count > 1 ? URL(fileURLWithPath: arguments[1]).lastPathComponent : "image"
    }

    // Called serially by ProcessRunner's output reader.
    func event(for line: String) -> CreationEvent? {
        if line.hasPrefix("Verifying metadata for image ") {
            return .progress(stage: "Checking image metadata: \(imageName)", fraction: nil, cancellable: true)
        }
        guard let end = line.range(of: "%)", options: .backwards)?.lowerBound,
              let start = line[..<end].lastIndex(of: "("),
              let percent = Int(line[line.index(after: start)..<end]), (0...100).contains(percent) else { return nil }
        let fraction = Double(percent) / 100
        let stage: String
        if line.hasPrefix("Splitting WIM: ") {
            splitFraction = max(splitFraction, fraction)
            let part = line.range(of: ", part ").map { String(line[$0.upperBound...]) }
            stage = "Splitting install image" + (part.map { " — part \($0)" } ?? "")
            return .progress(stage: stage, fraction: splitFraction, cancellable: true)
        } else if line.hasPrefix("Calculating integrity table for WIM: ") {
            if splitting {
                // This percentage describes just ONE part's checksum pass. It must
                // not overwrite overall split progress with a false 0% or 100%.
                return .progress(stage: "Splitting install image — checking part integrity", fraction: splitFraction, cancellable: true)
            }
            stage = "Calculating image integrity: \(imageName)"
        } else if line.hasPrefix("Verifying file data: ") {
            stage = "Verifying image contents: \(imageName)"
        } else if line.hasPrefix("Verifying integrity of ") {
            let quoted = line.split(separator: "\"", maxSplits: 2)
            let name = quoted.count > 1 ? URL(fileURLWithPath: String(quoted[1])).lastPathComponent : imageName
            stage = "Checking image checksum: \(name)"
        } else if line.hasPrefix("Archiving file data: ") {
            stage = "Converting install image"
        } else {
            return nil
        }
        return .progress(stage: stage, fraction: fraction, cancellable: true)
    }
}
