import Foundation

/// Manager-level in-flight lock so a second concurrent send/sweep fails fast.
public final class SendGate: @unchecked Sendable {
    public static let alreadyInProgressMessage =
        "A send is already in progress. Wait for it to finish."

    public enum Error: LocalizedError, Equatable {
        case alreadyInProgress

        public var errorDescription: String? {
            switch self {
            case .alreadyInProgress:
                return SendGate.alreadyInProgressMessage
            }
        }
    }

    private var inFlight = false
    private let lock = NSLock()

    public init() {}

    public func tryBegin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight else { return false }
        inFlight = true
        return true
    }

    public func end() {
        lock.lock()
        defer { lock.unlock() }
        inFlight = false
    }

    public func withLock<T>(_ body: () throws -> T) throws -> T {
        guard tryBegin() else { throw Error.alreadyInProgress }
        defer { end() }
        return try body()
    }
}
