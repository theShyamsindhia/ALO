import Network

/// Parameters for the existing legacy wire protocol. These deliberately do not
/// select or fall back from the separate v2 authenticated transport.
public enum LocalNetworkParameters {
    public static func tcp() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // A room listens and dials on the same Mac. Permit Network.framework
        // to reuse a local TCP endpoint that is still retiring from either role.
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        return parameters
    }

    public static func udp() -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        return parameters
    }
}
