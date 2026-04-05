/// Transport-layer protocol of a flow.
public enum TransportProtocol: Sendable, Equatable {
    case tcp
    case udp
}

/// Observable attributes of an incoming flow before any routing or inspection.
///
/// This is the input to the RouteEngine and is immutable once created.
public struct FlowMetadata: Sendable {
    /// Source IP address (device/app side).
    public let sourceAddress: String
    public let sourcePort: UInt16

    /// Destination IP address as dialed by the app.
    public let destinationAddress: String
    public let destinationPort: UInt16

    public let transportProtocol: TransportProtocol

    /// Hostname resolved from DNS cache or SNI/Host header, if available.
    public var resolvedHostname: String?

    /// Process name (full path) that originated this flow, if known.
    /// Used for PROCESS-NAME rule matching.
    public var processName: String?

    public init(
        sourceAddress: String,
        sourcePort: UInt16,
        destinationAddress: String,
        destinationPort: UInt16,
        transportProtocol: TransportProtocol,
        resolvedHostname: String? = nil,
        processName: String? = nil
    ) {
        self.sourceAddress = sourceAddress
        self.sourcePort = sourcePort
        self.destinationAddress = destinationAddress
        self.destinationPort = destinationPort
        self.transportProtocol = transportProtocol
        self.resolvedHostname = resolvedHostname
        self.processName = processName
    }
}
