import Foundation

public struct DiskTarget: Hashable, Sendable {
    public let id: String
    public let name: String
    public let size: Int64
    public let registryID: UInt64

    public init(id: String, name: String, size: Int64, registryID: UInt64) {
        self.id = id
        self.name = name
        self.size = size
        self.registryID = registryID
    }

    public var displayName: String {
        "\(name) — \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) — /dev/\(id)"
    }
}

public enum CreationEvent: Sendable {
    case log(String)
    /// Nil fraction means the operation has no measurable progress.
    case progress(stage: String, fraction: Double?, cancellable: Bool)
}

public typealias EventSink = @Sendable (CreationEvent) -> Void

public struct WriterError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    public init() {}
    public func cancel() { lock.lock(); requested = true; lock.unlock() }
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return requested
    }
    public func check() throws {
        if isCancelled { throw CancellationError() }
    }
}
