import Foundation
import Testing
@testable import ALO

@Suite("Local microphone test clip")
struct MicrophoneTestClipTests {
    @Test func boundsPCMToFiveSecondsAndCompleteSamples() {
        var clip = MicrophoneTestClip()
        clip.append(Data(repeating: 1, count: 3))
        #expect(clip.pcm.count == 2)
        clip.append(Data(repeating: 2, count: MicrophoneTestClip.maximumBytes + 100))
        clip.append(Data(repeating: 3, count: 100))
        #expect(clip.pcm.count == 480_000)
        #expect(clip.duration == 5)
        #expect(clip.wav.count == 480_044)
        #expect(String(data: clip.wav.prefix(4), encoding: .utf8) == "RIFF")
        #expect(String(data: clip.wav.subdata(in: 8..<12), encoding: .utf8) == "WAVE")
    }
}
