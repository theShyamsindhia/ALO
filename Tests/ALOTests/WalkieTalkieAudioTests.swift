import AVFoundation
import Foundation
import Testing
@testable import ALO
import ALOCore

// These lifecycle tests acquire real Core Audio graphs. Do not race their
// hardware starts/stops and configuration notifications within this suite.
@Suite(.serialized)
struct WalkieTalkieAudioTests {
    @Test("Talk and Open Line preserve full-band 48 kHz voice")
    func fullBandVoiceFormat() {
        #expect(WalkieTalkieMicrophone.sampleRate == 48_000)
        #expect(WalkieTalkieMicrophone.packetFrames == 960)
        #expect(WalkieTalkiePlayer.playbackFormat.sampleRate == 48_000)
    }

    @Test("Walkie-talkie playback uses an AVAudioEngine-compatible format")
    func playerConstructionUsesSupportedFormat() {
        let player = WalkieTalkiePlayer()

        withExtendedLifetime(player) {}
    }

    @Test("Voice and media share one hardware output graph")
    func voiceAndMediaShareOneHardwareOutputGraph() throws {
        let output = RoomAudioOutputEngine()
        let voice = WalkieTalkiePlayer(audioOutput: output)
        let media = try SynchronizedPlayer(audioOutput: output)

        #expect(voice.outputEngineIdentityForTesting == media.outputEngineIdentityForTesting)
    }

    @Test("A room can be constructed without configuring walkie-talkie audio")
    @MainActor
    func roomConstructionDoesNotStartAudioPlayback() {
        let session = MeshSession(
            room: RoomConfiguration(name: "Construction test"),
            nodeID: "local",
            displayName: "Local Mac",
            statusHandler: { _ in },
            identityHandler: { _, _ in },
            participantsHandler: { _ in },
            mediaStateHandler: { _ in },
            nowPlayingHandler: { _ in },
            chatHandler: { _, _, _, _, _ in },
            queueHandler: { _ in },
            videoHandler: { _ in }
        )

        withExtendedLifetime(session) {}
    }

    @Test("Wire PCM converts to the Float32 format required by AVAudioEngine")
    func pcm16Conversion() throws {
        let wireBytes = Data([
            0x00, 0x80,
            0x00, 0x00,
            0xFF, 0x7F,
        ])
        let buffer = try #require(
            WalkieTalkiePlayer.makePlaybackBuffer(fromPCM16Mono: wireBytes)
        )
        let samples = try #require(buffer.floatChannelData?[0])

        #expect(buffer.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer.frameLength == 3)
        #expect(samples[0] == -1)
        #expect(samples[1] == 0)
        #expect(abs(samples[2] - (32_767 / 32_768)) < 0.000_001)
    }

    @Test("Voice playback reaches media-compatible loudness without clipping")
    func voicePlaybackLeveling() throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let quiet = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        quiet.frameLength = 960
        let quietSamples = try #require(quiet.floatChannelData?[0])

        var leveler = VoicePlaybackLeveler()
        for _ in 0..<20 {
            // Feed fresh raw microphone samples on each 20 ms callback. Reusing
            // the already-amplified output would hide attack/smoothing bugs.
            for index in 0..<960 {
                quietSamples[index] = index.isMultiple(of: 2) ? 0.025 : -0.025
            }
            leveler.process(quiet)
        }
        var quietEnergy: Float = 0
        for index in 0..<960 { quietEnergy += quietSamples[index] * quietSamples[index] }
        #expect(sqrt(quietEnergy / 960) >= 0.14)

        let loud = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        loud.frameLength = 960
        let loudSamples = try #require(loud.floatChannelData?[0])
        for index in 0..<960 {
            loudSamples[index] = 0.98 * sin(Float(index) * 2 * .pi / 48)
        }
        leveler.process(loud)
        let peak = (0..<960).map { abs(loudSamples[$0]) }.max() ?? 0
        let flattenedSamples = (0..<960).filter {
            abs(loudSamples[$0]) >= VoicePlaybackLeveler.peakCeiling - 0.001
        }.count
        #expect(peak <= VoicePlaybackLeveler.peakCeiling)
        // A one-millisecond de-zipper may briefly touch the ceiling, but must
        // not flatten most of the 20 ms speech packet.
        #expect(flattenedSamples < 100)

        let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        silence.frameLength = 960
        leveler.process(silence)
        let silenceSamples = try #require(silence.floatChannelData?[0])
        #expect((0..<960).allSatisfy { silenceSamples[$0] == 0 })
    }

    @Test("Voice gain changes are ramped and do not amplify room noise")
    func voicePlaybackGainIsContinuousAndNoiseGated() throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        var leveler = VoicePlaybackLeveler()

        let first = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        first.frameLength = 960
        let firstSamples = try #require(first.floatChannelData?[0])
        for index in 0..<960 { firstSamples[index] = 0.025 }
        leveler.process(first)

        let second = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        second.frameLength = 960
        let secondSamples = try #require(second.floatChannelData?[0])
        for index in 0..<960 { secondSamples[index] = 0.025 }
        leveler.process(second)
        #expect(abs(secondSamples[0] - firstSamples[959]) < 0.01)

        // Raise the makeup gain far enough that returning early at the noise
        // gate would leave stale state and cause a click at the next onset.
        for _ in 0..<20 {
            for index in 0..<960 { secondSamples[index] = 0.025 }
            leveler.process(second)
        }
        #expect(leveler.gain > 4)

        let noise = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        noise.frameLength = 960
        let noiseSamples = try #require(noise.floatChannelData?[0])
        for index in 0..<960 { noiseSamples[index] = 0.0095 }
        leveler.process(noise)

        // A gated callback must ramp the existing gain down over the buffer,
        // finish at unity, and leave the next speech onset with coherent state.
        #expect(noiseSamples[0] > 0.02)
        #expect(abs(noiseSamples[959] - 0.0095) < 0.001)
        #expect(leveler.gain == 1)
    }

    @Test("Packet-loss concealment does not reset the active voice gain")
    func concealmentSilencePreservesVoiceGain() throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 48_000,
            channels: 1
        ))
        let speech = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        speech.frameLength = 960
        let speechSamples = try #require(speech.floatChannelData?[0])
        var leveler = VoicePlaybackLeveler()
        for _ in 0..<20 {
            for index in 0..<960 { speechSamples[index] = 0.025 }
            leveler.process(speech)
        }
        let activeGain = leveler.gain
        #expect(activeGain > 4)

        let concealment = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        concealment.frameLength = 960
        leveler.process(concealment, isConcealment: true)

        #expect(leveler.gain == activeGain)
    }

    @Test("The voice de-zipper stays one millisecond at legacy sample rates")
    func voiceGainRampUsesTheBufferSampleRate() {
        #expect(VoicePlaybackLeveler.downwardRampFrameCount(
            sampleRate: 16_000,
            bufferFrameCount: 320
        ) == 16)
        #expect(VoicePlaybackLeveler.downwardRampFrameCount(
            sampleRate: 48_000,
            bufferFrameCount: 960
        ) == 48)
    }

    @Test("Microphone route validity rejects a missing hardware format")
    func invalidMicrophoneHardwareFormatIsRejected() {
        #expect(!VoiceInputCatalog.isUsableInputFormat(sampleRate: 0, channelCount: 0))
        #expect(!VoiceInputCatalog.isUsableInputFormat(sampleRate: 48_000, channelCount: 0))
        #expect(VoiceInputCatalog.isUsableInputFormat(sampleRate: 48_000, channelCount: 1))
    }

    @Test("Shared output stops when idle and records every hardware restart")
    func sharedOutputIdleLifecycle() throws {
        let output = RoomAudioOutputEngine(idleStopDelay: .milliseconds(10))
        var firstPlayer: SynchronizedPlayer? = try SynchronizedPlayer(audioOutput: output)
        let firstGeneration = output.startGeneration
        #expect(firstGeneration > 0)
        #expect(output.isRunning)

        firstPlayer?.stop()
        firstPlayer = nil
        #expect(waitUntil(timeout: 1) { !output.isRunning })

        var secondPlayer: SynchronizedPlayer? = try SynchronizedPlayer(audioOutput: output)
        #expect(output.startGeneration > firstGeneration)
        secondPlayer?.stop()
        secondPlayer = nil
    }

    @Test("An idle voice route notification does not start audio hardware")
    func idleVoiceRecoveryDoesNotAcquireTheOutput() {
        let output = RoomAudioOutputEngine(idleStopDelay: .milliseconds(10))
        let player = WalkieTalkiePlayer(audioOutput: output)
        #expect(!output.isRunning)

        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: output.engine
        )

        Thread.sleep(forTimeInterval: 0.45)
        #expect(!output.isRunning)
        withExtendedLifetime(player) {}
    }

    @Test("Destroying voice playback detaches its nodes from the shared graph")
    func voicePlayerDeinitDetachesSessionNodes() throws {
        let output = RoomAudioOutputEngine(idleStopDelay: .milliseconds(10))
        var player: WalkieTalkiePlayer? = WalkieTalkiePlayer(audioOutput: output)
        player?.accept(WalkieTalkieMessage(
            kind: .began,
            senderID: "sender",
            senderName: "Sender",
            targetID: "listener",
            sessionID: "deinit-session",
            sequence: 0,
            sampleRate: 48_000
        ))
        var voiceNodeID: ObjectIdentifier?
        #expect(waitUntil(timeout: 1) {
            voiceNodeID = output.withGraph { engine in
                engine.attachedNodes
                    .first(where: { $0 is AVAudioPlayerNode })
                    .map(ObjectIdentifier.init)
            }
            return voiceNodeID != nil
        })

        weak var releasedPlayer = player
        player = nil
        #expect(waitUntil(timeout: 1) { releasedPlayer == nil })
        #expect(waitUntil(timeout: 1) {
            output.withGraph { engine in
                !engine.attachedNodes.contains { ObjectIdentifier($0) == voiceNodeID }
            }
        })
    }

    @Test("Microphone conversion follows the tap buffer after a route switch")
    func microphoneConverterUsesDeliveredHardwareFormat() throws {
        let output = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let input = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 320))
        buffer.frameLength = 320
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<320 { samples[index] = 0.25 }

        let converter = VoicePCMConverter(outputFormat: output)
        let converted = try #require(converter.convert(buffer))
        // The stateful sample-rate converter retains a small priming tail for
        // the next callback, but still produces a full-band chunk immediately.
        #expect(converted.count >= 1_800)
        #expect(converted.count <= 1_936)

        var continuousBytes = converted.count
        for _ in 0..<9 {
            continuousBytes += try #require(converter.convert(buffer)).count
        }
        #expect(continuousBytes >= 18_900)
        #expect(continuousBytes <= 19_360)

        let switchedInput = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let switchedBuffer = try #require(AVAudioPCMBuffer(
            pcmFormat: switchedInput,
            frameCapacity: 960
        ))
        switchedBuffer.frameLength = 960
        #expect(try #require(converter.convert(switchedBuffer)).count == 1_920)
    }

    @Test("Microphones are ordered with the default first and stable name ties")
    func microphoneOrdering() {
        let devices = VoiceInputCatalog.sorted([
            VoiceInputDevice(id: "z", name: "Studio Mic", isSystemDefault: false),
            VoiceInputDevice(id: "b", name: "Built-in Mic", isSystemDefault: true),
            VoiceInputDevice(id: "a", name: "studio mic", isSystemDefault: false),
        ])

        #expect(devices.map(\.id) == ["b", "a", "z"])
    }

    @Test("CoreAudio input catalog has unique live device identifiers")
    func microphoneCatalogIdentifiersAreUnique() {
        let devices = VoiceInputCatalog.availableDevices()

        #expect(Set(devices.map(\.id)).count == devices.count)
        #expect(devices.filter(\.isSystemDefault).count <= 1)
        #expect(!devices.contains { $0.id == VirtualAudioDevice.uid })
        #expect(VoiceInputCatalog.usesSystemDefault(nil))
        if let systemDefault = devices.first(where: \.isSystemDefault) {
            #expect(VoiceInputCatalog.usesSystemDefault(systemDefault.id))
        }
    }

    @Test("Automatic input avoids the Bluetooth headset microphone")
    func automaticInputPrefersBuiltInMicrophoneForBluetoothOutputQuality() {
        let devices = [
            VoiceInputDevice(
                id: "airpods",
                name: "AirPods Microphone",
                isSystemDefault: true,
                isBluetooth: true
            ),
            VoiceInputDevice(
                id: "mac-mic",
                name: "MacBook Pro Microphone",
                isSystemDefault: false,
                isBuiltIn: true
            ),
        ]

        #expect(VoiceInputCatalog.automaticInputUID(in: devices) == "mac-mic")
        #expect(VoiceInputCatalog.automaticInputUID(in: [
            VoiceInputDevice(
                id: "mac-mic",
                name: "MacBook Pro Microphone",
                isSystemDefault: true,
                isBuiltIn: true
            ),
        ]) == nil)

        #expect(VoiceInputCatalog.automaticInputUID(in: [
            VoiceInputDevice(
                id: "airpods",
                name: "AirPods Microphone",
                isSystemDefault: true,
                isBluetooth: true
            ),
            VoiceInputDevice(
                id: "usb-mic",
                name: "USB Microphone",
                isSystemDefault: false
            ),
        ]) == "usb-mic")
    }

    @Test("Concurrent talkers receive independent Float32 playback buffers")
    func concurrentTalkerBuffersAreIndependent() throws {
        let alice = try #require(WalkieTalkiePlayer.makePlaybackBuffer(
            fromPCM16Mono: Data([0x00, 0x40])
        ))
        let bob = try #require(WalkieTalkiePlayer.makePlaybackBuffer(
            fromPCM16Mono: Data([0x00, 0xC0])
        ))
        let aliceSamples = try #require(alice.floatChannelData?[0])
        let bobSamples = try #require(bob.floatChannelData?[0])

        #expect(alice.format.commonFormat == .pcmFormatFloat32)
        #expect(bob.format.commonFormat == .pcmFormatFloat32)
        #expect(aliceSamples[0] == 0.5)
        #expect(bobSamples[0] == -0.5)
    }

    @Test("Voice metering follows PCM amplitude without reacting to silence")
    func voiceLevelMetering() {
        let silence = Data(repeating: 0, count: 640)
        let quiet = Data(Array(repeating: [UInt8(0xCD), UInt8(0x0C)], count: 320).flatMap { $0 })
        let loud = Data(Array(repeating: [UInt8(0x00), UInt8(0x40)], count: 320).flatMap { $0 })

        let silenceLevel = VoiceLevelMeter.normalizedLevel(fromPCM16Mono: silence)
        let quietLevel = VoiceLevelMeter.normalizedLevel(fromPCM16Mono: quiet)
        let loudLevel = VoiceLevelMeter.normalizedLevel(fromPCM16Mono: loud)

        #expect(silenceLevel == 0)
        #expect(quietLevel > 0)
        #expect(loudLevel > quietLevel)
        #expect(loudLevel <= 1)
    }

    @Test("Voice level envelope rises faster than it falls")
    func voiceLevelEnvelope() {
        var envelope = VoiceLevelEnvelope()
        let attack = envelope.update(target: 1)
        let release = envelope.update(target: 0)

        #expect(attack == 0.5)
        #expect(release > 0)
        #expect(release < attack)
        envelope.reset()
        #expect(envelope.level == 0)
    }

    @Test("Interleaved talkers keep independent sequence state")
    func independentTalkerSequences() {
        var tracker = WalkieTalkiePlaybackTracker()
        tracker.begin("alice")
        tracker.begin("bob")

        let aliceFirst = tracker.accepts(sessionID: "alice", sequence: 1)
        let bobFirst = tracker.accepts(sessionID: "bob", sequence: 1)
        let aliceSecond = tracker.accepts(sessionID: "alice", sequence: 2)
        let bobDuplicate = tracker.accepts(sessionID: "bob", sequence: 1)
        #expect(aliceFirst)
        #expect(bobFirst)
        #expect(aliceSecond)
        #expect(!bobDuplicate)

        tracker.end("alice")
        #expect(tracker.lastSequences["alice"] == nil)
        #expect(tracker.lastSequences["bob"] == 1)
    }

    @Test("Incoming voice is dropped before queued audio becomes stale")
    func boundedVoiceBacklog() {
        #expect(!WalkieTalkiePlaybackTracker.shouldDropIncomingBuffer(
            scheduledFrames: 2_000,
            incomingFrames: 640,
            maximumFrames: 2_880
        ))
        #expect(WalkieTalkiePlaybackTracker.shouldDropIncomingBuffer(
            scheduledFrames: 2_500,
            incomingFrames: 640,
            maximumFrames: 2_880
        ))
    }

    @Test("A rapid began after ended replaces the draining receiver session")
    func endedSessionRequiresFreshReceiverState() {
        var lifecycle = VoicePlaybackSessionLifecycle()

        let initialBeginNeedsReplacement = lifecycle.beginRequiresReplacement()
        #expect(!initialBeginNeedsReplacement)
        lifecycle.markEnding()
        #expect(lifecycle.isEnding)
        #expect(lifecycle.shouldDropAudio)
        let revivedBeginNeedsReplacement = lifecycle.beginRequiresReplacement()
        #expect(revivedBeginNeedsReplacement)
        #expect(!lifecycle.isEnding)
        #expect(!lifecycle.shouldDropAudio)
    }

    @Test("Microphone chunks are packetized into exact 20 ms frames")
    func exactVoicePacketization() throws {
        let packetizer = VoicePacketizer()
        let source = Data((0..<(packetizer.bytesPerPacket * 2)).map { UInt8($0 % 251) })
        let firstBoundary = packetizer.bytesPerPacket + 150

        #expect(packetizer.append(source.prefix(117)).isEmpty)
        let first = packetizer.append(source[117..<firstBoundary])
        let second = packetizer.append(source[firstBoundary...])

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(first[0].count == packetizer.bytesPerPacket)
        #expect(second[0].count == packetizer.bytesPerPacket)
        #expect(first[0] + second[0] == source)
        #expect(packetizer.pendingByteCount == 0)
    }

    @Test("Voice jitter buffer waits 80 ms and restores packet order")
    func jitterBufferStartupAndOrdering() {
        var jitter = VoiceJitterBuffer()
        let p1 = Data([1, 0])
        let p2 = Data([2, 0])
        let p3 = Data([3, 0])
        let p4 = Data([4, 0])

        #expect(jitter.insert(sequence: 2, data: p2).isEmpty)
        #expect(jitter.insert(sequence: 1, data: p1).isEmpty)
        #expect(jitter.insert(sequence: 4, data: p4).isEmpty)
        let output = jitter.insert(sequence: 3, data: p3)

        #expect(output == [.audio(p1), .audio(p2), .audio(p3), .audio(p4)])
        #expect(jitter.isStarted)
        #expect(jitter.expectedSequence == 5)
    }

    @Test("Voice jitter buffer conceals a small gap and rejects its late packet")
    func jitterBufferGapConcealment() {
        var jitter = VoiceJitterBuffer(startupPacketCount: 1)
        let packet = Data([1, 0])

        #expect(jitter.insert(sequence: 1, data: packet) == [.audio(packet)])
        #expect(jitter.insert(sequence: 3, data: packet).isEmpty)
        #expect(jitter.insert(sequence: 4, data: packet) == [
            .silence(frames: WalkieTalkieMicrophone.packetFrames),
            .audio(packet),
            .audio(packet),
        ])
        #expect(jitter.concealedPacketCount == 1)
        #expect(jitter.insert(sequence: 2, data: packet).isEmpty)
        #expect(jitter.lateDropCount == 1)
    }

    @Test("A route change rebuilds the voice startup cushion")
    func routeChangeReprimesVoiceJitterBuffer() {
        let packet = Data([0, 0])
        var jitter = VoiceJitterBuffer(startupPacketCount: 4)
        #expect(jitter.insert(sequence: 1, data: packet).isEmpty)
        #expect(jitter.insert(sequence: 2, data: packet).isEmpty)
        #expect(jitter.insert(sequence: 3, data: packet).isEmpty)
        #expect(jitter.insert(sequence: 4, data: packet).count == 4)

        jitter.resetForRouteChange()
        #expect(jitter.insert(sequence: 5, data: packet).isEmpty)
        #expect(jitter.insert(sequence: 6, data: packet).isEmpty)
        #expect(jitter.insert(sequence: 7, data: packet).isEmpty)
        #expect(jitter.insert(sequence: 8, data: packet).count == 4)
    }

    @Test("Voice jitter buffer bounds a session that never becomes contiguous")
    func jitterBufferPendingBound() {
        var jitter = VoiceJitterBuffer(startupPacketCount: 4, maximumPendingPackets: 4)
        for sequence in stride(from: UInt64(1), through: 11, by: 2) {
            _ = jitter.insert(sequence: sequence, data: Data([UInt8(sequence), 0]))
        }

        #expect(jitter.pending.count == 4)
        #expect(jitter.pending.keys.min() == 5)
        #expect(jitter.lateDropCount == 2)
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.010)
        }
        return condition()
    }
}
