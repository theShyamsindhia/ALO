import Foundation
import Testing
import WERAICore

struct AppVersionTests {
    @Test("Release versions compare numerically and tolerate v tags")
    func numericComparison() {
        #expect(AppVersion("v0.12.1")! > AppVersion("0.12.0")!)
        #expect(AppVersion("1.10.0")! > AppVersion("1.9.99")!)
        #expect(AppVersion("1.2")! == AppVersion("1.2.0")!)
    }

    @Test("Stable releases sort after prereleases")
    func prereleaseComparison() {
        #expect(AppVersion("1.0.0-beta.2")! < AppVersion("1.0.0")!)
        #expect(AppVersion("not-a-version") == nil)
    }

    @Test("Mesh envelopes retain optional app versions across encoding")
    func meshEnvelopeVersionRoundTrip() throws {
        let envelope = MeshEnvelope(type: "hello", nodeID: "peer", appVersion: "0.12.1")
        let data = try envelope.encodedLine().dropLast()
        let decoded = try JSONDecoder().decode(MeshEnvelope.self, from: data)
        #expect(decoded.appVersion == "0.12.1")
    }
}
