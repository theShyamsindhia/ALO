import ALOVirtualDisplay
import CoreGraphics
import Foundation

protocol VirtualDisplayManaging: AnyObject {
    var displayID: CGDirectDisplayID { get }
    func stop()
}

final class VirtualDisplayManager: VirtualDisplayManaging {
    enum Error: LocalizedError {
        case unsupported
        case creationFailed

        var errorDescription: String? {
            switch self {
            case .unsupported: "ALO Display is not supported by this macOS version."
            case .creationFailed: "ALO couldn't create its virtual display."
            }
        }
    }

    private var handle: OpaquePointer?
    let displayID: CGDirectDisplayID

    init() throws {
        guard ALOVirtualDisplayIsSupported() else { throw Error.unsupported }
        guard let handle = ALOVirtualDisplayCreate() else { throw Error.creationFailed }
        let displayID = ALOVirtualDisplayGetDisplayID(handle)
        guard displayID != kCGNullDirectDisplay else {
            ALOVirtualDisplayDestroy(handle)
            throw Error.creationFailed
        }
        self.handle = handle
        self.displayID = displayID
    }

    func stop() {
        guard let handle else { return }
        ALOVirtualDisplayDestroy(handle)
        self.handle = nil
    }

    deinit { stop() }
}

final class VirtualDisplayOwner {
    private let factory: () throws -> VirtualDisplayManaging
    private var display: VirtualDisplayManaging?

    init(factory: @escaping () throws -> VirtualDisplayManaging = { try VirtualDisplayManager() }) {
        self.factory = factory
    }

    var displayID: CGDirectDisplayID? { display?.displayID }

    func create() throws -> CGDirectDisplayID {
        stop()
        let display = try factory()
        self.display = display
        return display.displayID
    }

    func stop() {
        display?.stop()
        display = nil
    }

    deinit { stop() }
}
