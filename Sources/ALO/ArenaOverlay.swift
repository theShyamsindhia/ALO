import SwiftUI
import ALOCore

/// Uses the room's charcoal glass and muted accent language. Player colors are
/// shared by the roster and scene so identity never depends on character choice.
enum ArenaAppearance {
    static let accent = Color(red: 0.55, green: 0.59, blue: 0.75)
    static let surface = Color(red: 0.18, green: 0.18, blue: 0.19)
    static let secondary = Color.white.opacity(0.58)
    static func playerColor(_ slot: Int) -> Color {
        switch slot {
        case 0: accent
        case 1: Color(red: 0.75, green: 0.59, blue: 0.51)
        case 2: Color(red: 0.49, green: 0.69, blue: 0.61)
        default: Color(red: 0.78, green: 0.71, blue: 0.47)
        }
    }
}

/// Can remain visible above the arena while the match is active. Slot labels,
/// names and state supplement color for accessibility and spectator orientation.
struct ArenaPlayerRoster: View {
    @ObservedObject var session: ArenaSession
    var compact = false

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: compact ? 8 : 12), count: compact ? max(1, session.simulation.fighters.count) : min(2, max(1, session.simulation.fighters.count))), spacing: 10) {
            ForEach(Array(session.simulation.fighters.enumerated()), id: \.offset) { index, fighter in
                if compact && session.simulation.fighters.count > 2 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.playerNames.indices.contains(index) ? session.playerNames[index] : "Player \(index + 1)")
                            .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        Text(fighter.stocks == 0 ? "Eliminated" : "P\(index + 1) · \(fighter.stocks) lives · \(Int(fighter.damage))%")
                            .font(.system(size: 9)).monospacedDigit().lineLimit(1)
                            .foregroundStyle(ArenaAppearance.playerColor(index))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(7)
                        .background(ArenaAppearance.playerColor(index).opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                } else { player(index, fighter: fighter) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func player(_ index: Int, fighter: ArenaFighter) -> some View {
        let name = session.playerNames.indices.contains(index) ? session.playerNames[index] : "Player \(index + 1)"
        let isLocal = session.mode != .spectator && session.localIndex == index
        let state = fighter.stocks == 0 ? "Eliminated" : fighter.respawn > 0 ? "Respawning" : "In arena"
        return HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 3) {
                Image(systemName: fighter.kind.arenaSymbol)
                    .font(.system(size: compact ? 12 : 17, weight: .medium))
                    .frame(width: compact ? 27 : 34, height: compact ? 27 : 34)
                    .background(ArenaAppearance.playerColor(index).opacity(0.2), in: RoundedRectangle(cornerRadius: 9))
                Text("P\(index + 1)").font(.system(size: 9, weight: .semibold))
            }.foregroundStyle(ArenaAppearance.playerColor(index))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(name).lineLimit(1).font(.system(size: compact ? 11 : 13, weight: .semibold))
                    if isLocal && name != "You" { Text("You").font(.system(size: 8, weight: .medium)).foregroundStyle(ArenaAppearance.secondary) }
                }
                Text("\(fighter.kind.title) · \(state)")
                    .font(.system(size: compact ? 9 : 10)).foregroundStyle(ArenaAppearance.secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(max(0, fighter.stocks)) lives").font(.system(size: compact ? 9 : 11, weight: .medium))
                    Text("·").foregroundStyle(ArenaAppearance.secondary)
                    Text("\(Int(fighter.damage))% damage")
                        .font(.system(size: compact ? 9 : 11, weight: .medium)).monospacedDigit()
                }
                if !compact && fighter.stocks > 0 {
                    Text("\(fighter.airJumps) air jumps · Recovery \(fighter.recoveryAvailable ? "ready" : "used")")
                        .font(.system(size: 9)).foregroundStyle(ArenaAppearance.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 8 : 11)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ArenaAppearance.playerColor(index).opacity(0.27), lineWidth: 0.7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Player \(index + 1), \(name)\(isLocal ? ", you" : ""), \(fighter.kind.title), \(state), \(fighter.stocks) lives, \(Int(fighter.damage)) percent damage")
    }
}

/// Opening this menu pauses local practice only. Network matches continue while
/// a player inspects controls/settings; the owning session must clear their input.
struct ArenaMenuOverlay: View {
    @ObservedObject var session: ArenaSession
    var detached = false
    @Binding var effectsEnabled: Bool
    var initialSection = "Overview"
    let onResume: () -> Void
    let onLeave: () -> Void
    @State private var tab: Section = .overview
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private enum Section: String, CaseIterable {
        case overview = "Overview", controls = "Controls", settings = "Settings"
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 550 || geometry.size.height < 400
            ZStack {
                Color.black.opacity(0.35)
                VStack(spacing: 0) {
                    header(compact: compact)
                    Picker("Game menu", selection: $tab) {
                        ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).padding(.horizontal, 14).padding(.bottom, 10)
                    Divider().opacity(0.35)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 13) {
                            switch tab {
                            case .overview: overview(compact: compact)
                            case .controls: controls
                            case .settings: settings
                            }
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollIndicators(.automatic)
                    Divider().opacity(0.35)
                    HStack(spacing: 10) {
                        Button("Leave activity", action: onLeave)
                            .buttonStyle(.plain).foregroundStyle(ArenaAppearance.secondary)
                            .help(session.networked ? "Leave the session. If you are hosting, the match ends for everyone." : "Return to the activity library")
                        Spacer(minLength: 0)
                        Button(session.simulation.winner == nil ? "Resume" : "Return to arena", action: onResume)
                            .buttonStyle(.borderedProminent).tint(ArenaAppearance.accent)
                            .keyboardShortcut(.cancelAction)
                    }.font(.system(size: 11, weight: .medium)).padding(12)
                }
                .frame(maxWidth: compact ? 520 : 590)
                .frame(maxHeight: max(0, geometry.size.height - (compact ? 12 : 36)))
                .background(ArenaAppearance.surface.opacity(0.90))
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 14 : 19))
                .overlay(RoundedRectangle(cornerRadius: compact ? 14 : 19).strokeBorder(.white.opacity(0.14), lineWidth: 0.8))
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                .padding(.horizontal, compact ? 6 : 18)
            }
        }
        .foregroundStyle(.white.opacity(0.9))
        .onAppear { tab = Section(rawValue: initialSection) ?? .overview }
    }

    private func header(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "gamecontroller").foregroundStyle(ArenaAppearance.accent)
                .font(.system(size: compact ? 18 : 23, weight: .regular))
            VStack(alignment: .leading, spacing: 3) {
                Text(session.mode == .practice && session.paused ? "Practice paused" : "Arena menu")
                    .font(.system(size: compact ? 14 : 18, weight: .semibold))
                Text(session.networked && session.simulation.winner == nil
                     ? "The room match continues while this menu is open."
                     : "Your controls, players and game settings.")
                    .font(.system(size: compact ? 9 : 11)).foregroundStyle(ArenaAppearance.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: onResume) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28) }
                .buttonStyle(.plain).foregroundStyle(ArenaAppearance.secondary).help("Close menu and return to arena")
        }.padding(compact ? 12 : 16)
    }

    private func overview(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ArenaPlayerRoster(session: session, compact: compact)
            Text("Build damage, then launch your opponent beyond the arena. The last player with lives remaining wins.")
                .font(.system(size: 11)).foregroundStyle(ArenaAppearance.secondary)
            if !session.notice.isEmpty {
                Label(session.notice, systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(ArenaAppearance.accent)
            }
            HStack(spacing: 8) {
                if session.mode == .practice {
                    Button("Restart practice", systemImage: "arrow.counterclockwise") { session.practice(); onResume() }
                        .buttonStyle(.bordered)
                } else if session.simulation.winner != nil && session.mode != .spectator {
                    Button("Request rematch", systemImage: "arrow.counterclockwise") { session.rematch(); onResume() }
                        .buttonStyle(.bordered)
                }
                if detached {
                    Button("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") { session.fullscreen() }.buttonStyle(.bordered)
                } else {
                    Button("Expand arena", systemImage: "arrow.up.left.and.arrow.down.right") { onResume(); session.openExpanded() }.buttonStyle(.bordered)
                }
            }.font(.system(size: 10)).controlSize(.small)
            if detached {
                Button("Return game to room", systemImage: "rectangle.inset.filled") { onResume(); session.closeExpanded() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(ArenaAppearance.accent)
            }
            if session.networked {
                Text("Four player slots · \(session.spectatorCount) watching. Join mid-match by taking a live bot’s slot; otherwise spectate. The match ends if its host leaves.")
                    .font(.system(size: 10)).foregroundStyle(ArenaAppearance.secondary)
            }
        }
    }

    private var controlsFighter: ArenaFighterKind {
        session.simulation.fighters.indices.contains(session.localIndex) ? session.simulation.fighters[session.localIndex].kind : session.selected
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The arena takes focus when play starts or resumes. Click it to refocus after using other controls. J/K/L and Z/X/C are interchangeable; these are Rift Arena controls.")
                .font(.system(size: 11)).foregroundStyle(ArenaAppearance.secondary)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                GridRow {
                    Text("Action").fontWeight(.semibold)
                    Text("Keyboard").fontWeight(.semibold)
                    Text("Controller").fontWeight(.semibold)
                }.foregroundStyle(ArenaAppearance.secondary)
                controlRow("Move", "A / D or ← / →", "Left stick / D-pad")
                controlRow("Aim attack", "W / S or ↑ / ↓", "Stick up / down")
                controlRow("Jump / air jump", "Space", "A / Cross")
                controlRow("Light attack", "J / Z", "X / Square")
                controlRow("Signature / aerial heavy", "K / X", "Y / Triangle")
                controlRow("Dodge", "L / C", "RB / R1")
                controlRow("Drop through", "S or ↓", "Stick down")
                controlRow("Recovery", "W + K / X", "Up + Y / Triangle")
                controlRow("Game menu", "P / Esc", "Menu / Options")
            }.font(.system(size: 10)).frame(maxWidth: .infinity, alignment: .leading)
            Text("You have two air jumps and one recovery before landing. Higher damage means stronger knockback. Use dodge to avoid a hit, then recover toward a platform.")
                .font(.system(size: 11)).foregroundStyle(ArenaAppearance.secondary)
            Divider()
            Text("\(controlsFighter.title) move list").font(.system(size: 12, weight: .semibold))
            Text("Tap an attack while aiming. Ground and aerial moves differ; heavy attacks have longer openings if you miss.")
                .font(.system(size: 10)).foregroundStyle(ArenaAppearance.secondary)
            ForEach([false, true], id: \.self) { aerial in
                Text(aerial ? "In the air" : "On the ground").font(.system(size: 11, weight: .semibold))
                ForEach([0, 1, -1], id: \.self) { direction in
                    let aim = direction == 0 ? "Forward" : direction == 1 ? "Up" : "Down"
                    let light = ArenaAttackProfile.resolve(kind: controlsFighter, heavy: false, direction: direction, aerial: aerial)
                    let heavy = ArenaAttackProfile.resolve(kind: controlsFighter, heavy: true, direction: direction, aerial: aerial)
                    HStack(alignment: .top) {
                        Text(aim).frame(width: 48, alignment: .leading)
                        Text("J · \(light.title)").frame(maxWidth: .infinity, alignment: .leading)
                        Text("K · \(heavy.title)").frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 10)).foregroundStyle(ArenaAppearance.secondary)
                }
            }
            Text("Controller button names depend on the connected gamepad. macOS must recognize an extended gamepad.")
                .font(.system(size: 9)).foregroundStyle(ArenaAppearance.secondary)
        }
    }

    private func controlRow(_ action: String, _ keyboard: String, _ controller: String) -> some View {
        GridRow {
            Text(action).foregroundStyle(.white.opacity(0.86))
            Text(keyboard).foregroundStyle(ArenaAppearance.accent)
            Text(controller).foregroundStyle(ArenaAppearance.secondary)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Game volume", systemImage: session.gameVolume == 0 ? "speaker.slash" : "speaker.wave.2")
                Spacer()
                Text("\(Int(session.gameVolume * 100))%")
                    .monospacedDigit().foregroundStyle(ArenaAppearance.secondary)
            }.font(.system(size: 12, weight: .medium))
            Slider(value: $session.gameVolume, in: 0...1).tint(ArenaAppearance.accent)
                .accessibilityLabel("Game volume")
            Text("Music and voice keep their separate room audio controls.")
                .font(.system(size: 10)).foregroundStyle(ArenaAppearance.secondary)
            Divider().opacity(0.3)
            Toggle("Impact effects", isOn: $effectsEnabled).toggleStyle(.switch).controlSize(.small)
                .font(.system(size: 12, weight: .medium)).tint(ArenaAppearance.accent)
            Text("Turn off decorative impact impact particles. Attacks, hit detection and player visibility stay the same.")
                .font(.system(size: 10)).foregroundStyle(ArenaAppearance.secondary)
            if systemReduceMotion {
                Label("Reduce Motion is enabled in macOS.", systemImage: "accessibility")
                    .font(.system(size: 10)).foregroundStyle(ArenaAppearance.accent)
            }
        }
    }
}

/// Crop a portrait sheet at display time; each pack image is decoded once.
struct ArenaFighterPortrait: View {
    let image: NSImage?
    let kind: ArenaFighterKind
    private var columns: CGFloat { kind == .nova || kind == .atlas ? 2 : 3 }
    private var column: CGFloat {
        switch kind { case .nova, .ember: 0; case .atlas, .wisp: 1; case .rook: 2 }
    }
    var body: some View {
        GeometryReader { geometry in
            if let image {
                Image(nsImage: image).resizable()
                    .frame(width: geometry.size.width * columns, height: geometry.size.height)
                    .offset(x: -geometry.size.width * column)
            } else {
                Image(systemName: kind.arenaSymbol)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }.clipped().accessibilityLabel(kind.title)
    }
}

extension ArenaFighterKind {
    var arenaSymbol: String {
        switch self {
        case .nova: "bolt.fill"
        case .atlas: "shield.lefthalf.filled"
        case .ember: "flame.fill"
        case .wisp: "sparkles"
        case .rook: "hammer.fill"
        }
    }
}
