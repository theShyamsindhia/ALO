import ALOIdentity
import ALONetworking

/// Local construction material for channel-independent services. This is not
/// cached peer admission: each service must verify live TLS bindings and current
/// policy when authenticating and dispatching. No channel membership is implied.
/// Acquire at service setup/replacement, not per message: fetching reloads disk
/// policy and signs a fresh binding. Binding IDs are not stable installation IDs.
public struct NetworkDeviceAccess: Sendable {
    public let policy: NetworkPolicyCenter
    public let localDevice: DeviceIdentityBinding

    init(policy: NetworkPolicyCenter, localDevice: DeviceIdentityBinding) {
        self.policy = policy
        self.localDevice = localDevice
    }
}
