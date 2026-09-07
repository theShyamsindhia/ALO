import AppKit
import SpriteKit
import SwiftUI
import ALOCore

struct StickFightPanel: View {
    @ObservedObject var session: StickFightSession
    var onBack: () -> Void
    var showsHeader = true
    @State private var botCount = 3
    @State private var showsControls = false
    @AppStorage("stickFight.soundEnabled") private var soundEnabled = true
    private let accent = Color(red: 0.98, green: 0.77, blue: 0.28)

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack {
                    Button(action: onBack) { Label("Games", systemImage: "chevron.left") }
                    Spacer()
                    Text("STICK FIGHT").font(.system(size: 12, weight: .black)).tracking(2)
                    Spacer()
                    Button { showsControls.toggle(); session.clearInput() } label: { Image(systemName: "questionmark.circle") }
                }.buttonStyle(.plain).padding(12)
            }
            if session.started { game } else { lobby }
        }
        .foregroundStyle(.white.opacity(0.92))
        .background(Color(red: 0.065, green: 0.075, blue: 0.10))
        .tint(accent)
        .onAppear { session.panelAppeared() }
        .onDisappear { session.clearInput(); session.panelDisappeared() }
    }
    private var game: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(session.slots, id: \.index) { slot in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Circle().fill(StickFightPalette.color(slot.index)).frame(width: 5, height: 5)
                            Text(slot.name + (slot.index == session.localIndex && session.mode != .spectator && slot.name != "You" ? " · You" : "")).lineLimit(1)
                            Spacer(minLength: 0)
                            if session.simulation.fighters.indices.contains(slot.index) {
                                Text("\(session.simulation.fighters[slot.index].wins)").fontWeight(.black).monospacedDigit().accessibilityLabel("\(session.simulation.fighters[slot.index].wins) rounds won")
                            }
                        }
                        if session.simulation.fighters.indices.contains(slot.index) {
                            let fighter = session.simulation.fighters[slot.index]
                            GeometryReader { g in
                                Capsule().fill(.white.opacity(0.08))
                                Capsule().fill(StickFightPalette.color(slot.index)).frame(width: g.size.width * max(0, min(1, fighter.health / 100)))
                            }.frame(height: 3).opacity(fighter.alive ? 1 : 0.25)
                            Text(!fighter.alive ? "Out this round" : fighter.weapon.map { "\($0.title) · \(fighter.ammo)" } ?? "Unarmed").font(.system(size: 8)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        }
                    }.font(.system(size: 10, weight: .medium)).padding(8)
                        .frame(maxWidth: .infinity).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                }
            }.padding(8)
            ZStack {
                StickFightSurface(session: session, inputBlocked: session.showsMenu || showsControls, soundEnabled: soundEnabled)
                    .aspectRatio(1000.0 / 600, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if session.showsMenu || showsControls {
                    VStack(spacing: 14) {
                        Text(session.mode == .practice ? "Take a breather" : "Match menu").font(.system(size: 21, weight: .bold))
                        if session.mode != .practice { Text("Match continues. Your controls are released and your fighter can still be hit.").font(.system(size: 11)).foregroundStyle(.secondary) }
                        controls
                        HStack {
                            Button("Leave match") { session.leave(); showsControls = false }
                            Button("Resume") { showsControls = false; if session.showsMenu { session.togglePause() } }.buttonStyle(.borderedProminent)
                        }
                    }.padding(24).frame(maxWidth: 380).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                } else if let winner = session.simulation.winner {
                    VStack(spacing: 12) {
                        Image(systemName: "crown.fill").font(.system(size: 25)).foregroundStyle(accent)
                        Text(winner >= 0 ? "\(name(winner)) wins the match" : "Match drawn").font(.system(size: 20, weight: .bold))
                        HStack {
                            Button("Back to lobby") { session.leave() }
                            if session.isActivityHost || session.mode == .practice {
                                Button("Play again") { session.rematch() }.buttonStyle(.borderedProminent)
                            } else { Text("Waiting for the host’s rematch").font(.system(size: 11)).foregroundStyle(.secondary) }
                        }
                    }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            HStack(spacing: 8) {
                Text(session.mode == .spectator ? "WATCHING · Join when the host reopens the lobby" : "WASD move · Click attack · Right click block · F throw")
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Button { soundEnabled.toggle() } label: { Image(systemName: soundEnabled ? "speaker.wave.2" : "speaker.slash") }.help(soundEnabled ? "Mute game sounds" : "Enable game sounds").accessibilityLabel(soundEnabled ? "Mute game sounds" : "Enable game sounds")
                Button("Menu · Esc") { session.togglePause() }.buttonStyle(.plain)
            }.font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.5)).padding(10)
            if !session.notice.isEmpty { Text(session.notice).font(.system(size: 10)).foregroundStyle(accent).padding(.bottom, 6) }
        }
    }
    private var lobby: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    StickFightPreview().frame(height: 145).clipped()
                    LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("STICK FIGHT").font(.system(size: 26, weight: .black, design: .rounded)).tracking(1)
                        Text("Small fighters. Big trouble.").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    }.padding(16)
                }.frame(height: 145).clipShape(RoundedRectangle(cornerRadius: 13))
                Text("Leap between platforms, grab falling weapons, and knock everyone out. Last fighter standing wins the round. First to five wins the match.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                if session.mode == .picker {
                    HStack {
                        Text("YOUR ARENA").font(.system(size: 10, weight: .bold)).tracking(1.5)
                        Spacer()
                        Text("1–4 fighters").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        ForEach(StickFightMap.allCases, id: \.self) { map in
                            Button { session.selectedMap = map } label: {
                                VStack(spacing: 6) {
                                    StickFightMapDiagram(map: map).frame(height: 32)
                                    Text(map.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                }.padding(10).frame(maxWidth: .infinity)
                                    .background(.white.opacity(session.selectedMap == map ? 0.10 : 0.03), in: RoundedRectangle(cornerRadius: 9))
                                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(session.selectedMap == map ? accent.opacity(0.5) : .clear))
                            }.buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Picker("Bots", selection: $botCount) { ForEach(1...3, id: \.self) { Text("\($0) bot\($0 == 1 ? "" : "s")").tag($0) } }.frame(width: 120)
                        Spacer()
                        Button("Practice") { session.practice(botCount: botCount) }.buttonStyle(.bordered)
                        Button("Host match") { session.host(botCount: 0) }.buttonStyle(.borderedProminent).disabled(!session.roomConnected)
                    }.controlSize(.small)
                    if !session.roomConnected { Text("Practice works offline. Join a channel to fight with friends.").font(.system(size: 10)).foregroundStyle(.secondary) }
                    if session.roomConnected {
                        Text("IN THIS ROOM").font(.system(size: 10, weight: .bold)).tracking(1.5)
                        if session.lobbies.isEmpty { Text("No matches yet. Host one and channel members can join here.").font(.system(size: 11)).foregroundStyle(.secondary) }
                        ForEach(session.lobbies, id: \.sessionID) { match in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(match.started ? "Match in progress" : "Waiting for fighters").font(.system(size: 12, weight: .semibold))
                                    Text("\(match.humanCount) playing · \(match.availableSlots) open slots").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if match.availableSlots > 0 { Button(match.started ? "Watch" : "Join") { session.join(match) }.buttonStyle(.borderedProminent) }
                                Button("Watch") { session.join(match, spectate: true) }.buttonStyle(.bordered)
                            }.controlSize(.small).padding(10).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                } else if session.mode == .joining {
                    HStack { ProgressView().controlSize(.small); Text("Joining match…"); Spacer(); Button("Cancel") { session.leave() } }.font(.system(size: 12))
                } else {
                    Text("MATCH LOBBY").font(.system(size: 10, weight: .bold)).tracking(1.5)
                    ForEach(session.slots, id: \.index) { slot in
                        HStack {
                            Circle().fill(StickFightPalette.color(slot.index)).frame(width: 9, height: 9)
                            Text(slot.name + (slot.index == session.localIndex && session.mode != .spectator && slot.name != "You" ? " · You" : ""))
                            Spacer()
                            Text(slot.isBot ? "Bot · Ready" : slot.ready ? "Ready" : "Not ready").foregroundStyle(slot.ready || slot.isBot ? accent : Color.gray)
                        }.font(.system(size: 12)).padding(10).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("Everyone readies up to begin. Live matches can be watched; join a fighter slot when the host reopens the lobby.").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button("Leave") { session.leave() }
                        if session.isActivityHost { Button("Add bot") { session.addBot() }.disabled(session.slots.count >= 4) }
                        Spacer()
                        if session.mode == .spectator {
                            if session.canJoinCurrentLobby { Button("Join fight") { session.joinCurrentLobby() }.buttonStyle(.borderedProminent) }
                            else { Text("Spectating · waiting for the host").font(.system(size: 11)).foregroundStyle(.secondary) }
                        } else {
                            Button(session.localReady ? "Not ready" : "Ready up") { session.readyUp() }.buttonStyle(.borderedProminent).disabled(!session.canReadyUp)
                        }
                    }
                }
                if !session.notice.isEmpty { Text(session.notice).font(.system(size: 11)).foregroundStyle(accent) }
                DisclosureGroup("Controls & tips", isExpanded: $showsControls) { controls.padding(.top, 8) }.font(.system(size: 11))
            }.padding(14).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("A / D or ← / →   Move").fontWeight(.semibold)
            Text("W / Space / ↑   Jump / double jump")
            Text("Left mouse   Punch / fire · Right mouse   Block")
            Text("Mouse   Aim · F   Throw weapon · J / K / L   Keyboard attacks")
            Text("Weapons are picked up automatically. Blocking drains your shield. Falling into spikes ends your round.").foregroundStyle(.secondary)
            Text("Click the arena to focus. Esc opens the menu.").foregroundStyle(.secondary)
        }.font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func name(_ index: Int) -> String { session.slots.first(where: { $0.index == index })?.name ?? "Player \(index + 1)" }
}

enum StickFightPalette {
    static func color(_ index: Int) -> Color { Color(nsColor: native(index)) }
    static func native(_ index: Int) -> NSColor {
        [NSColor(calibratedRed: 1, green: 0.79, blue: 0.24, alpha: 1),
         NSColor(calibratedRed: 0.94, green: 0.37, blue: 0.40, alpha: 1),
         NSColor(calibratedRed: 0.37, green: 0.73, blue: 0.92, alpha: 1),
         NSColor(calibratedRed: 0.57, green: 0.80, blue: 0.40, alpha: 1)][max(0, index) % 4]
    }
}

private struct StickFightMapDiagram: View {
    let map: StickFightMap
    var body: some View {
        Canvas { context, size in
            for p in map.platforms {
                context.fill(Path(CGRect(x: p.left / 1000 * size.width, y: (600 - p.top) / 600 * size.height, width: (p.right - p.left) / 1000 * size.width, height: 3)), with: .color(.white.opacity(0.55)))
            }
        }.accessibilityHidden(true)
    }
}

private struct StickFightPreview: View {
    var body: some View {
        Canvas { c, s in
            c.fill(Path(CGRect(origin: .zero, size: s)), with: .color(Color(red: 0.24, green: 0.25, blue: 0.23)))
            for i in 0..<5 {
                let x: CGFloat = CGFloat(i) * s.width / 4
                let y: CGFloat = 5 + CGFloat(i % 2) * 40
                var p = Path()
                p.move(to: CGPoint(x: x - 70, y: s.height))
                p.addLine(to: CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x + 150, y: s.height))
                p.closeSubpath()
                c.fill(p, with: .color(.black.opacity(0.09)))
            }
            for i in 0..<4 {
                let x = s.width * (0.2 + CGFloat(i) * 0.20), y = s.height * (i % 2 == 0 ? 0.48 : 0.35)
                var p = Path(); p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x - 2, y: y + 19)); p.addLine(to: CGPoint(x: x - 15, y: y + 34)); p.move(to: CGPoint(x: x - 2, y: y + 19)); p.addLine(to: CGPoint(x: x + 16, y: y + 26)); p.move(to: CGPoint(x: x, y: y + 6)); p.addLine(to: CGPoint(x: x - 16, y: y - 2)); p.move(to: CGPoint(x: x, y: y + 6)); p.addLine(to: CGPoint(x: x + 13, y: y + 4))
                c.stroke(p, with: .color(StickFightPalette.color(i)), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                c.fill(Path(ellipseIn: CGRect(x: x - 5, y: y - 10, width: 10, height: 10)), with: .color(StickFightPalette.color(i)))
            }
        }.accessibilityHidden(true)
    }
}
