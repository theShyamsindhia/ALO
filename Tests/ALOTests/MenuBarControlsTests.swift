import AppKit
import Testing
import ALOCore
@testable import ALO

extension NativePresentationTests {
    @Suite(.serialized) @MainActor
    struct MenuBarControlsTests {
        @Test func preferencesPersistAndDiscIsOptional() throws {
            let name = "alo-menu-tests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let preferences = ALOMenuBarPreferences(defaults: defaults)
            #expect(preferences.controls == [.record])
            preferences.setPinned(.chat, true)
            preferences.setPinned(.playback, true)
            preferences.setPinned(.record, false)
            #expect(ALOMenuBarPreferences(defaults: defaults).controls == [.chat, .playback])
            preferences.setPinned(.chat, false)
            preferences.setPinned(.playback, false)
            #expect(ALOMenuBarPreferences(defaults: defaults).controls.isEmpty)
            defaults.set(["unknown-future-control", "people"], forKey: ALOMenuBarPreferences.storageKey)
            #expect(ALOMenuBarPreferences(defaults: defaults).controls == [.people])
        }

        @Test func controlsRespectRoomAndPlaybackAvailability() {
            var state = ALOMenuBarControlState(live: false, playbackAvailable: true, playing: true,
                broadcaster: true, busy: false, videoAvailable: true, hasVideo: false, muted: false, unread: 0)
            for control in ALOMenuBarControl.allCases where control != .record {
                #expect(!state.enabled(control))
            }
            #expect(state.enabled(.record))
            state.live = true
            #expect(state.enabled(.playback))
            #expect(state.symbol(.playback) == "pause.fill")
            state.playing = false
            #expect(state.symbol(.playback) == "play.fill")
            state.playbackAvailable = false
            #expect(!state.enabled(.playback))
            #expect(!state.enabled(.next))
            state.broadcaster = false
            #expect(!state.enabled(.sync))
            state.broadcaster = true
            state.busy = true
            #expect(!state.enabled(.sync))
            #expect(state.enabled(.screen), "Keep screen selection cancellable")
            #expect(state.help(.screen).contains("Cancel"))
            #expect(state.enabled(.chat))
            state.muted = true
            #expect(state.symbol(.mute) == "speaker.slash.fill")
            #expect(state.help(.mute).contains("room media on this Mac"))
        }

        @Test func navigationNeverMirrorsOrEnablesAnotherSurface() {
            let model = ALOViewModel(discoverRooms: false)
            model.currentParticipantID = "local"
            model.participants = [RoomParticipant(id: "local", name: "You"),
                                  RoomParticipant(id: "peer-a", name: "Peer A"),
                                  RoomParticipant(id: "peer-b", name: "Peer B")]
            model.floatingBarHidden = true
            model.floatingSection = .queue
            let floatingHeight = model.floatingPanelHeight
            model.setMenuBarPopoverVisible(true)
            model.toggleSection(.chat, in: .menuBar)
            #expect(model.menuBarSection == .chat)
            #expect(model.floatingSection == .queue)
            #expect(model.floatingPanelHeight == floatingHeight)
            #expect(model.floatingBarHidden)
            model.toggleSection(.people, in: .menuBar)
            #expect(model.menuBarSection == .people)
            model.toggleSection(.people, in: .menuBar)
            #expect(model.menuBarSection == .collapsed)

            model.floatingBarHidden = false
            model.setSection(.video, in: .menuBar)
            let menuHeight = model.panelHeight(for: .menuBar)
            model.toggleSection(.people, in: .floating)
            #expect(model.menuBarSection == .video)
            #expect(model.panelHeight(for: .menuBar) == menuHeight)
            #expect(model.floatingSection == .people)
            #expect(model.participants.map(\.id) == ["local", "peer-a", "peer-b"], "People navigation must not prune the roster")
            model.setMenuBarPopoverVisible(false)
            #expect(model.menuBarSection == .collapsed)
            #expect(model.floatingSection == .people)
        }

        @Test func popoverResizesOnlyForItsOwnNavigation() async throws {
            _ = NSApplication.shared
            let model = ALOViewModel(discoverRooms: false)
            let name = "alo-menu-sizing-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }
            let controller = ALOStatusMenuController(model: model,
                menuBarPreferences: ALOMenuBarPreferences(defaults: defaults), toggleMainWindow: {})
            let collapsed = controller.contentSize
            model.setSection(.chat, in: .floating)
            try await Task.sleep(for: .milliseconds(30))
            #expect(controller.contentSize == collapsed)
            model.setSection(.chat, in: .menuBar)
            try await Task.sleep(for: .milliseconds(30))
            #expect(controller.contentSize.height > collapsed.height)
            model.setSection(.collapsed, in: .menuBar)
            try await Task.sleep(for: .milliseconds(30))
            #expect(controller.contentSize == collapsed)
        }

        @Test("Pinned icons render real glyphs and album accents", arguments: [false, true])
        func nativeIcons(dark: Bool) throws {
            _ = NSApplication.shared
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            let palette = ArtworkPalette(accentHex: "EE7733", secondaryHex: "8855DD", tertiaryHex: "44BBAA")
            for control in ALOMenuBarControl.allCases where control != .record {
                for artwork in [nil, palette] {
                    let image = ALOMenuBarControlImage.make(symbol: control.symbol, palette: artwork, appearance: appearance)
                    #expect(!image.isTemplate)
                    #expect(image.size == NSSize(width: 24, height: 24))
                    let data = try #require(image.tiffRepresentation)
                    let bitmap = try #require(NSBitmapImageRep(data: data))
                    var glyphPixels = 0
                    var clearPixels = 0
                    for y in 3..<(bitmap.pixelsHigh * 2 / 3) {
                        for x in 3..<(bitmap.pixelsWide - 3) {
                            let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            if color.alphaComponent > 0.5 { glyphPixels += 1 }
                            if color.alphaComponent < 0.05 { clearPixels += 1 }
                        }
                    }
                    #expect(glyphPixels > 5, "Must contain the SF Symbol")
                    #expect(clearPixels > 5, "Must not render a solid black block")
                    let scale = bitmap.pixelsWide / 24
                    let belowGlyph = try #require(bitmap.colorAt(x: 12 * scale, y: 21 * scale))
                    #expect(belowGlyph.alphaComponent < 0.01, "No coloured underline beneath the icon")
                }
            }
        }

        @Test("Artwork tints remain legible", arguments: [false, true])
        func artworkTintContrast(dark: Bool) throws {
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            var background = NSColor.white
            appearance.performAsCurrentDrawingAppearance {
                background = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .white
            }
            for hex in ["000000", "FFFFFF", "EE7733", "225544", "00FF00", "0000FF"] {
                let palette = ArtworkPalette(accentHex: hex, secondaryHex: hex, tertiaryHex: hex)
                let color = ALOMenuBarControlImage.tint(palette: palette, appearance: appearance)
                #expect(ALOMenuBarControlImage.contrast(color, background) >= 4.5)
            }
            let warm = ALOMenuBarControlImage.tint(palette: .init(accentHex: "EE7733", secondaryHex: "EE7733", tertiaryHex: "EE7733"), appearance: appearance)
            let cool = ALOMenuBarControlImage.tint(palette: .init(accentHex: "3366DD", secondaryHex: "3366DD", tertiaryHex: "3366DD"), appearance: appearance)
            #expect(warm != cool, "The glyph tint must follow album changes")
        }
    }
}
