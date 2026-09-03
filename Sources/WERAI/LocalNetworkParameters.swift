import Network

enum LocalNetworkParameters {
    static func tcp() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        return parameters
    }

    static func udp() -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = true
        return parameters
    }
}
