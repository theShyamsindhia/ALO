import Foundation
import Testing
import ALOIdentity
@testable import ALORooms

@Suite("Offline network authority")
struct NetworkAuthorityTests {
    @Test func creationAtomicallyIncludesOwnerAndDeterministicMain() throws {
        let owner = UserIdentity.ephemeral()
        let id = UUID()
        let manifest = try NetworkManifest.create(name: "Friends", owner: owner, id: id)
        #expect(manifest.revision == 1)
        #expect(manifest.members == [NetworkMember(identity: owner.publicIdentity, role: .owner)])
        #expect(manifest.channels.count == 1)
        #expect(manifest.mainChannel.id == NetworkManifest.mainChannelID(for: id))
        #expect(manifest.mainChannel.name == "Main")
        #expect(manifest.mainChannel.visibility == .publicToMembers)
        #expect(try manifest.authorize(owner.publicIdentity, channelID: manifest.mainChannel.id) == manifest.mainChannel)
        #expect(try NetworkManifest.decode(manifest.encoded()) == manifest)
    }

    @Test func publicChannelsRequireMembershipAndPrivateChannelsRequireAllowlist() throws {
        let owner = UserIdentity.ephemeral()
        let alice = UserIdentity.ephemeral()
        let bob = UserIdentity.ephemeral()
        let outsider = UserIdentity.ephemeral()
        var manifest = try NetworkManifest.create(name: "Friends", owner: owner)
        manifest = try manifest.addingMember(alice.publicIdentity, signedBy: owner)
        manifest = try manifest.addingMember(bob.publicIdentity, signedBy: owner)
        let privateChannel = try NetworkChannel(name: "Planning", visibility: .privateMembers,
                                                allowedUserIDs: [alice.publicIdentity.userID])
        manifest = try manifest.addingChannel(privateChannel, signedBy: owner)
        #expect(try manifest.accessibleChannels(for: alice.publicIdentity).count == 2)
        #expect(try manifest.accessibleChannels(for: bob.publicIdentity) == [manifest.mainChannel])
        #expect(try manifest.authorize(owner.publicIdentity, channelID: privateChannel.id) == privateChannel)
        #expect(throws: NetworkAuthorityError.channelAccessDenied) {
            try manifest.authorize(bob.publicIdentity, channelID: privateChannel.id)
        }
        #expect(throws: NetworkAuthorityError.notMember) {
            try manifest.authorize(outsider.publicIdentity, channelID: manifest.mainChannel.id)
        }
        #expect(throws: NetworkAuthorityError.notMember) {
            try manifest.accessibleChannels(for: outsider.publicIdentity)
        }
    }

    @Test func ownerOnlyChannelsAndMemberRemovalKeepAllowlistConsistent() throws {
        let owner = UserIdentity.ephemeral()
        let member = UserIdentity.ephemeral()
        var manifest = try NetworkManifest.create(name: "Team", owner: owner)
        manifest = try manifest.addingMember(member.publicIdentity, signedBy: owner)
        let channel = try NetworkChannel(name: "Private", visibility: .privateMembers,
                                         allowedUserIDs: [member.publicIdentity.userID])
        manifest = try manifest.addingChannel(channel, signedBy: owner)
        manifest = try manifest.removingMember(userID: member.publicIdentity.userID, signedBy: owner)
        #expect(manifest.channels.first(where: { $0.id == channel.id })?.allowedUserIDs.isEmpty == true)
        #expect(try manifest.authorize(owner.publicIdentity, channelID: channel.id).id == channel.id)
        #expect(throws: NetworkAuthorityError.notMember) {
            try manifest.authorize(member.publicIdentity, channelID: channel.id)
        }
        #expect(throws: NetworkAuthorityError.invalidOwner) {
            try manifest.removingMember(userID: owner.publicIdentity.userID, signedBy: owner)
        }
        #expect(throws: NetworkAuthorityError.ownerRequired) { try manifest.renamed(to: "Hijacked", signedBy: member) }
    }

    @Test func tamperingSignedPolicyIsRejected() throws {
        let owner = UserIdentity.ephemeral()
        let member = UserIdentity.ephemeral()
        let original = try NetworkManifest.create(name: "Original", owner: owner)
            .addingMember(member.publicIdentity, signedBy: owner)
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["name"] = "Tampered" },
            { $0["revision"] = 77 },
            { $0["generation"] = UUID().uuidString },
            { $0["signature"] = Data(repeating: 0, count: 64).base64EncodedString() },
            { object in
                var members = object["members"] as! [[String: Any]]
                members.removeAll { ($0["role"] as? String) == "member" }
                object["members"] = members
            }
        ]
        for mutate in mutations {
            var object = try #require(JSONSerialization.jsonObject(with: original.encoded()) as? [String: Any])
            mutate(&object)
            let tampered = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: NetworkAuthorityError.invalidSignature) { try NetworkManifest.decode(tampered) }
        }
    }

    @Test func canonicalPolicyIgnoresSetOrderingAndJSONFormatting() throws {
        let owner = UserIdentity.ephemeral()
        let alice = UserIdentity.ephemeral()
        let bob = UserIdentity.ephemeral()
        let base = try NetworkManifest.create(name: "Canonical", owner: owner)
        let channel = try NetworkChannel(name: "Private", visibility: .privateMembers,
                                         allowedUserIDs: [bob.publicIdentity.userID, alice.publicIdentity.userID])
        let members = base.members + [NetworkMember(identity: alice.publicIdentity), NetworkMember(identity: bob.publicIdentity)]
        let first = try NetworkManifest.signed(id: base.id, generation: base.generation, revision: 2,
            name: base.name, owner: owner, members: members, channels: [base.mainChannel, channel])
        let second = try NetworkManifest.signed(id: base.id, generation: base.generation, revision: 2,
            name: base.name, owner: owner, members: members.reversed(), channels: [channel, base.mainChannel])
        #expect(try first.canonicalBytes() == second.canonicalBytes())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        #expect(try NetworkManifest.decode(encoder.encode(first)) == first)
    }

    @Test func signedMalformedPoliciesAreRejectedBeforeSigning() throws {
        let owner = UserIdentity.ephemeral()
        let outsider = UserIdentity.ephemeral()
        let base = try NetworkManifest.create(name: "Validation", owner: owner)
        func sign(members: [NetworkMember]? = nil, channels: [NetworkChannel]? = nil,
                  revision: UInt64 = 2) throws -> NetworkManifest {
            try NetworkManifest.signed(id: base.id, generation: base.generation, revision: revision,
                name: base.name, owner: owner, members: members ?? base.members, channels: channels ?? base.channels)
        }
        #expect(throws: NetworkAuthorityError.duplicateMember) { try sign(members: base.members + base.members) }
        #expect(throws: NetworkAuthorityError.invalidOwner) {
            try sign(members: [NetworkMember(identity: owner.publicIdentity)])
        }
        #expect(throws: NetworkAuthorityError.invalidRevision) { try sign(revision: 0) }
        #expect(throws: NetworkAuthorityError.duplicateChannel) { try sign(channels: base.channels + base.channels) }
        #expect(throws: NetworkAuthorityError.invalidMainChannel) {
            try sign(channels: [NetworkChannel(name: "Main", isMain: true)])
        }
        #expect(throws: NetworkAuthorityError.invalidAllowlist) {
            try sign(channels: base.channels + [NetworkChannel(name: "Foreign", visibility: .privateMembers,
                                                               allowedUserIDs: [outsider.publicIdentity.userID])])
        }
        #expect(throws: NetworkAuthorityError.invalidMainChannel) {
            try base.removingChannel(id: base.mainChannel.id, signedBy: owner)
        }
        #expect(throws: NetworkAuthorityError.invalidName) { try NetworkManifest.create(name: " ", owner: owner) }
        #expect(throws: NetworkAuthorityError.invalidName) { try NetworkManifest.create(name: "A\nB", owner: owner) }
        #expect(throws: NetworkAuthorityError.invalidName) {
            try NetworkManifest.create(name: String(repeating: "a", count: 81), owner: owner)
        }
        #expect(throws: NetworkAuthorityError.invalidAllowlist) {
            try NetworkChannel(name: "Public", allowedUserIDs: [owner.publicIdentity.userID])
        }
        #expect(throws: NetworkAuthorityError.invalidAllowlist) {
            try NetworkChannel(name: "Private", visibility: .privateMembers,
                               allowedUserIDs: [owner.publicIdentity.userID, owner.publicIdentity.userID])
        }
    }

    @Test func aggregateAndNumericLimitsAreEnforcedDuringSigning() throws {
        let owner = UserIdentity.ephemeral()
        let base = try NetworkManifest.create(name: "Bounds", owner: owner)
        let identities = (0..<31).map { _ in UserIdentity.ephemeral().publicIdentity }
        let members = base.members + identities.map { NetworkMember(identity: $0) }
        let allowlist = members.map(\.userID)
        let channels = try (0..<100).map { index in
            try NetworkChannel(name: "Private \(index)", visibility: .privateMembers, allowedUserIDs: allowlist)
        }
        #expect(throws: NetworkAuthorityError.limitExceeded) {
            try NetworkManifest.signed(id: base.id, generation: base.generation, revision: 2, name: base.name,
                owner: owner, members: members, channels: base.channels + channels)
        }
        #expect(throws: NetworkAuthorityError.limitExceeded) {
            try NetworkManifest.decode(Data(repeating: 0, count: NetworkManifest.maximumEncodedBytes + 1))
        }
        let atMaximumRevision = try NetworkManifest.signed(id: base.id, generation: base.generation,
            revision: UInt64.max, name: base.name, owner: owner, members: base.members, channels: base.channels)
        #expect(throws: NetworkAuthorityError.invalidRevision) {
            try atMaximumRevision.renamed(to: "Overflow", signedBy: owner)
        }
    }

    @Test func membershipRequestsAndInvitationsContainOnlyPublicIdentityAndRequireRecipientMembership() throws {
        let owner = UserIdentity.ephemeral()
        let member = UserIdentity.ephemeral()
        let outsider = UserIdentity.ephemeral()
        let request = NetworkMembershipRequest(identity: member.publicIdentity)
        #expect(try NetworkMembershipRequest.decode(request.encoded()) == request)
        let requestObject = try #require(JSONSerialization.jsonObject(with: request.encoded()) as? [String: Any])
        #expect(Set(requestObject.keys) == Set(["formatVersion", "identity"]))
        let manifest = try NetworkManifest.create(name: "Invite", owner: owner)
            .addingMember(member.publicIdentity, signedBy: owner)
        let invitation = try NetworkInvitation(manifest: manifest, recipient: member.publicIdentity)
        #expect(try NetworkInvitation.decode(invitation.encoded()) == invitation)
        #expect(throws: NetworkAuthorityError.notMember) {
            try NetworkInvitation(manifest: manifest, recipient: outsider.publicIdentity)
        }
        var object = try #require(JSONSerialization.jsonObject(with: invitation.encoded()) as? [String: Any])
        object["recipient"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(outsider.publicIdentity))
        #expect(throws: NetworkAuthorityError.notMember) {
            try NetworkInvitation.decode(JSONSerialization.data(withJSONObject: object))
        }
    }
}
