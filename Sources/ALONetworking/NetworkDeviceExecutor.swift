import Foundation

/// Owns protocol-state serialization independently of the caller's target queue.
func networkDeviceExecutor(target: DispatchQueue) -> DispatchQueue {
    DispatchQueue(label: "alo.network.device-text.\(UUID().uuidString)", target: target)
}
