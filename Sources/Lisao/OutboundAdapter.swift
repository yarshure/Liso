import Foundation

/// Context provided to an adapter when starting an outbound connection.
public struct OutboundContext: Sendable {
	public let sessionID: SessionID
		public let metadata: FlowMetadata
		public let decision: RouteDecision

		public init(sessionID: SessionID, metadata: FlowMetadata, decision: RouteDecision) {
			self.sessionID = sessionID
				self.metadata = metadata
				self.decision = decision
		}
}
public enum SessionError: Error, Sendable, Equatable {
    case timeout
    case routeRejected(reason: String)
    case outboundConnectionFailed
    case protocolError(String)
    case unexpectedClose
    case internalError(String)
}
/// Protocol for outbound connection adapters.
///
/// Implementations: DirectAdapter, Socks5Adapter, HttpConnectAdapter, ShadowsocksAdapter, …
///
/// Each adapter is responsible for exactly one concern: establishing and
/// forwarding data over a particular upstream protocol. Session management,
/// routing, and iOS lifecycle are handled elsewhere.
//public protocol OutboundAdapter: AnyObject, Sendable {
//    /// Stable identifier used to look up adapters in the registry.
//    var id: String { get }
//
//    /// Establish the upstream connection. Throws on failure.
//    func start(with context: OutboundContext) async throws
//
//    /// Send data to the upstream side.
//    //func send(_ data: Data) async throws
//    
//    func send(_ data: PacketBuffer<Any>) async throws
//    /// Receive data from the upstream side.
//    /// Returns `nil` when the upstream connection has closed normally.
//    //func receive() async throws -> Data?
//    
//    func receive() async throws -> PacketBuffer<Any>?
//    /// Tear down the upstream connection immediately (fire-and-forget).
//    func close()
//}
