import Foundation

/// Uniquely identifies a session within the SessionManager.
public struct SessionID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init() { self.rawValue = UUID() }
    public init(rawValue: UUID) { self.rawValue = rawValue }

    public var description: String { rawValue.uuidString }
    public var uuidString:String{
        return rawValue.uuidString
    }
}
