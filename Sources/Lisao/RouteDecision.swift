/// The action the routing engine has chosen for a flow.
///
/// RouteDecision is the *only* output of the RouteEngine; all upstream connection
/// logic lives in adapters, not in the route engine itself.
public enum RouteDecision: Sendable, Equatable {
    /// Forward the connection directly without a proxy.
    case direct

    /// Forward through the named outbound adapter.
    case proxy(adapterID: String)

    /// Drop the connection silently.
    case reject

    /// Apply MITM inspection, then forward through the named adapter.
    case inspect(adapterID: String)
}
