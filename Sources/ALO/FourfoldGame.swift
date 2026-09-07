import SwiftUI
import ALOCore

@MainActor
final class FourfoldSession: ObservableObject {
    enum Mode: String, CaseIterable { case solo = "Solo vs bot", local = "Two on this Mac" }
    @Published private(set) var game = FourfoldSimulation()
    @Published var mode: Mode = .solo { didSet { reset() } }
    @Published private(set) var thinking = false
    @Published var subtitle = "A little space to think."
    @Published var accentHex = "B3A3EB"
    private var generation = UUID()
    func reset() { generation = UUID(); thinking = false; game = FourfoldSimulation() }
    func drop(_ column: Int) {
        guard !thinking, game.drop(in: column), mode == .solo, !game.finished else { return }
        thinking = true
        let snapshot = game, token = generation
        Task { [weak self] in
            let column = await Task.detached(priority: .userInitiated) { snapshot.botColumn() }.value
            guard let self, self.generation == token else { return }
            if let column { self.game.drop(in: column) }
            self.thinking = false
        }
    }
}

struct FourfoldPanel: View {
    @ObservedObject var session: FourfoldSession
    var onBack: () -> Void
    var showsHeader = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showHelp = false
    private var lavender: Color {
        let clean = session.accentHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, let value = UInt32(clean, radix: 16) else { return Color(red: 0.70, green: 0.64, blue: 0.92) }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    private let clay = Color(red: 0.91, green: 0.58, blue: 0.43)
    private let charcoal = Color(red: 0.105, green: 0.105, blue: 0.125)
    private var status: String {
        if let winner = session.game.winner {
            return session.mode == .solo ? (winner == 1 ? "You found your four." : "The bot found its four.") : (winner == 1 ? "Lavender wins." : "Clay wins.")
        }
        if session.game.isDraw { return "A full board. A perfect stalemate." }
        if session.thinking { return "The bot is thinking…" }
        return session.mode == .solo ? "Your move. Make a connection." : (session.game.turn == 1 ? "Lavender, your move." : "Clay, your move.")
    }
    var body: some View {
        GeometryReader { geometry in
            let boardWidth = min(560.0, min(max(210, geometry.size.width - 32), max(210, (geometry.size.height - 164) * 7 / 6)))
            ScrollView {
              VStack(spacing: 10) {
                if showsHeader {
                HStack(alignment: .top) {
                    Button(action: onBack) { Image(systemName: "chevron.left"); Text("Games") }.buttonStyle(.plain)
                    Spacer()
                    VStack(spacing: 2) {
                        Text("FOURFOLD").font(.system(size: 18, weight: .black, design: .rounded)).tracking(3)
                        Text(session.subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.52))
                    }
                    Spacer()
                    Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }.buttonStyle(.plain).help("How to play")
                }
                .foregroundStyle(lavender)
                }
                HStack {
                    Picker("Play mode", selection: $session.mode) {
                        ForEach(FourfoldSession.Mode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                    }.pickerStyle(.segmented).frame(maxWidth: 280)
                    Button("New round") { session.reset() }.buttonStyle(.bordered).tint(lavender)
                    if !showsHeader { Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }.buttonStyle(.plain).help("How to play") }
                }
                Text(status).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                if showHelp {
                    Text("Drop a disc into any open column. Connect four horizontally, vertically, or diagonally. Lavender moves first. Two on this Mac shares this keyboard and screen; it does not invite channel members.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { column in
                        Button { session.drop(column) } label: {
                            VStack(spacing: 4) {
                                ForEach((0..<6).reversed(), id: \.self) { row in
                                    let index = row * 7 + column
                                    let value = session.game.cells[index]
                                    Circle()
                                        .fill(value == 1 ? lavender : value == 2 ? clay : charcoal)
                                        .overlay {
                                            if session.game.winningCells.contains(index) {
                                                Circle().strokeBorder(.white.opacity(0.9), lineWidth: 3).padding(3)
                                            } else if session.game.lastDrop == index {
                                                Circle().fill(.white.opacity(0.65)).frame(width: 6, height: 6)
                                            }
                                        }
                                        .aspectRatio(1, contentMode: .fit)
                                }
                            }
                            .padding(3)
                            .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 20))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(session.thinking || !session.game.legalColumns.contains(column))
                        .keyboardShortcut(KeyEquivalent(Character(String(column + 1))), modifiers: [])
                        .accessibilityLabel("Column \(column + 1)")
                        .accessibilityValue(columnDescription(column))
                        .accessibilityHint("Drop your disc; shortcut \(column + 1)")
                    }
                }
                .padding(9)
                .frame(width: boardWidth)
                .background(Color(red: 0.20, green: 0.19, blue: 0.24), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(lavender.opacity(0.18)))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: session.game.cells)
                Text("Click a column or press 1–7 · \(session.mode.rawValue)")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(charcoal)
        }
    }
    private func columnDescription(_ column: Int) -> String {
        let values = (0..<6).map { row in
            let value = session.game.cell(column: column, row: row)
            return value == 0 ? "empty" : value == 1 ? "lavender" : "clay"
        }
        return "Bottom to top: " + values.joined(separator: ", ")
    }
}
