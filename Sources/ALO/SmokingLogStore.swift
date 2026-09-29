import Combine
import CryptoKit
import Foundation

enum SmokingBrand: String, Codable, CaseIterable, Identifiable {
    case classicConnect
    case marlboroCloveMix

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classicConnect: "Classic Connect"
        case .marlboroCloveMix: "Marlboro Clove Mix"
        }
    }
    /// Per-stick price, derived exactly from the pack price.
    var pricePaise: Int { packPricePaise / packCount }
    var packPricePaise: Int {
        switch self {
        case .classicConnect: 43_000
        case .marlboroCloveMix: 24_000
        }
    }
    var packCount: Int {
        switch self {
        case .classicConnect: 20
        case .marlboroCloveMix: 10
        }
    }
}

enum SmokingContext: String, Codable, CaseIterable, Identifiable {
    case withPeople
    case afterFood
    case stress
    case habit

    var id: String { rawValue }
    var title: String {
        switch self {
        case .withPeople: "With people"
        case .afterFood: "After food"
        case .stress: "Stress"
        case .habit: "Habit"
        }
    }
}

struct SmokingEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let userID: String
    var brand: SmokingBrand
    var smokedAt: Date
    /// Price snapshot taken when the entry was logged; later price changes never rewrite history.
    var pricePaise: Int
    var context: SmokingContext?
    let recordedAt: Date
    let timeZoneID: String

    init(id: UUID = UUID(), userID: String, brand: SmokingBrand, smokedAt: Date, pricePaise: Int? = nil,
         context: SmokingContext? = nil, recordedAt: Date = Date(), timeZoneID: String = TimeZone.current.identifier) {
        self.id = id
        self.userID = userID
        self.brand = brand
        self.smokedAt = smokedAt
        self.pricePaise = pricePaise ?? brand.pricePaise
        self.context = context
        self.recordedAt = recordedAt
        self.timeZoneID = timeZoneID
    }
}

struct SmokingDailyTotal: Identifiable, Equatable {
    let day: Date
    /// Logged entries for the day. Zero means nothing was logged, not confirmed abstinence.
    let count: Int
    let costPaise: Int
    var id: Date { day }
}

enum SmokingAnalytics {
    /// Oldest first; identical timestamps fall back to UUID so ordering is stable.
    static func precedes(_ lhs: SmokingEntry, _ rhs: SmokingEntry) -> Bool {
        lhs.smokedAt != rhs.smokedAt ? lhs.smokedAt < rhs.smokedAt : lhs.id.uuidString < rhs.id.uuidString
    }

    /// Entries in the half-open range `[from, to)`.
    static func entries(in entries: [SmokingEntry], from: Date, to: Date) -> [SmokingEntry] {
        entries.filter { $0.smokedAt >= from && $0.smokedAt < to }.sorted(by: precedes)
    }

    /// One bin per calendar day touching `[from, to)`, including days with no entries.
    static func dailyTotals(entries: [SmokingEntry], from: Date, to: Date, calendar: Calendar) -> [SmokingDailyTotal] {
        guard from < to else { return [] }
        let bins = Dictionary(grouping: self.entries(in: entries, from: from, to: to)) { calendar.startOfDay(for: $0.smokedAt) }
        var totals: [SmokingDailyTotal] = []
        var day = calendar.startOfDay(for: from)
        while day < to {
            let rows = bins[day] ?? []
            totals.append(SmokingDailyTotal(day: day, count: rows.count, costPaise: costPaise(entries: rows)))
            // Re-anchor to startOfDay so zones whose midnight is skipped still match the bin keys.
            guard let next = calendar.date(byAdding: .day, value: 1, to: day).map({ calendar.startOfDay(for: $0) }), next > day else { break }
            day = next
        }
        return totals
    }

    /// Median gap between distinct timestamps on the same local calendar day. Overnight gaps never count.
    static func typicalInterval(entries: [SmokingEntry], calendar: Calendar) -> TimeInterval? {
        let days = Dictionary(grouping: entries.map(\.smokedAt)) { calendar.startOfDay(for: $0) }
        let gaps = days.values.flatMap { times -> [TimeInterval] in
            let distinct = Set(times).sorted()
            return zip(distinct, distinct.dropFirst()).map { $1.timeIntervalSince($0) }
        }.sorted()
        guard !gaps.isEmpty else { return nil }
        let middle = gaps.count / 2
        return gaps.count.isMultiple(of: 2) ? (gaps[middle - 1] + gaps[middle]) / 2 : gaps[middle]
    }

    static func costPaise(entries: [SmokingEntry]) -> Int {
        entries.reduce(0) { $0 + $1.pricePaise }
    }

    /// INR with Indian digit grouping, e.g. `₹21.50`, `₹1,00,000.00`.
    static func money(_ paise: Int) -> String {
        let magnitude = paise.magnitude
        var head = String(magnitude / 100)
        var groups = [String(head.suffix(3))]
        head = String(head.dropLast(3))
        while !head.isEmpty {
            groups.insert(String(head.suffix(2)), at: 0)
            head = String(head.dropLast(2))
        }
        let fraction = magnitude % 100
        return (paise < 0 ? "-" : "") + "₹" + groups.joined(separator: ",") + (fraction < 10 ? ".0" : ".") + String(fraction)
    }
}

/// One local, per-account smoking log file. A file that cannot be read is never
/// overwritten: mutations stay blocked until `reload()` reads it successfully.
@MainActor
final class SmokingLogStore: ObservableObject {
    private struct Archive: Codable {
        static let currentVersion = 1
        let version: Int
        let userID: String
        let entries: [SmokingEntry]
    }

    static let maximumPricePaise = 1_000_000
    private static let unreadableMessage = "Your saved log couldn't be read. It has been kept unchanged."
    private static let unsavedMessage = "This change couldn't be saved on this Mac."
    private static let invalidMessage = "That entry isn't valid."
    private static let missingMessage = "That entry no longer exists."
    private static let futureMessage = "Choose a time that isn't in the future."

    @Published private(set) var entries: [SmokingEntry] = []
    @Published private(set) var errorMessage: String?
    let userID: String
    private let url: URL
    @Published private(set) var isReadable = false

    init(userID: String, directory: URL? = nil) {
        self.userID = userID
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier == "in.werai.audio.dev" ? "ALO-Dev" : "ALO", isDirectory: true)
            .appendingPathComponent("SmokingLog", isDirectory: true)
        let digest = SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined()
        url = folder.appendingPathComponent("\(digest).json")
        reload()
    }

    /// Re-reads the file. Current entries are replaced only after a successful read.
    func reload() {
        guard let loaded = read() else {
            isReadable = false
            errorMessage = Self.unreadableMessage
            return
        }
        entries = loaded
        isReadable = true
        errorMessage = nil
    }

    @discardableResult
    func add(brand: SmokingBrand, smokedAt: Date, context: SmokingContext?, now: Date = Date()) -> SmokingEntry? {
        guard isReadable else { return reject(Self.unreadableMessage) }
        guard smokedAt.timeIntervalSinceReferenceDate.isFinite, now.timeIntervalSinceReferenceDate.isFinite else { return reject(Self.invalidMessage) }
        guard smokedAt <= now else { return reject(Self.futureMessage) }
        let entry = SmokingEntry(userID: userID, brand: brand, smokedAt: smokedAt, context: context, recordedAt: now)
        return commit(entries + [entry]) ? entry : nil
    }

    /// Keeps the original price snapshot unless the brand changes.
    @discardableResult
    func update(id: UUID, brand: SmokingBrand, smokedAt: Date, context: SmokingContext?, now: Date = Date()) -> Bool {
        guard isReadable else { return reject(Self.unreadableMessage) }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return reject(Self.missingMessage) }
        guard smokedAt.timeIntervalSinceReferenceDate.isFinite, now.timeIntervalSinceReferenceDate.isFinite else { return reject(Self.invalidMessage) }
        guard smokedAt <= now else { return reject(Self.futureMessage) }
        var next = entries
        if next[index].brand != brand { next[index].pricePaise = brand.pricePaise }
        next[index].brand = brand
        next[index].smokedAt = smokedAt
        next[index].context = context
        return commit(next)
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        guard isReadable else { return reject(Self.unreadableMessage) }
        guard entries.contains(where: { $0.id == id }) else { return reject(Self.missingMessage) }
        return commit(entries.filter { $0.id != id })
    }

    /// Undo for `remove(id:)`: the entry must belong to this account and not already exist.
    @discardableResult
    func restore(_ entry: SmokingEntry) -> Bool {
        guard isReadable else { return reject(Self.unreadableMessage) }
        guard isValid(entry), !entries.contains(where: { $0.id == entry.id }) else { return reject(Self.invalidMessage) }
        return commit(entries + [entry])
    }

    private func isValid(_ entry: SmokingEntry) -> Bool {
        entry.userID == userID && (0...Self.maximumPricePaise).contains(entry.pricePaise) && !entry.timeZoneID.isEmpty
            && entry.smokedAt.timeIntervalSinceReferenceDate.isFinite && entry.recordedAt.timeIntervalSinceReferenceDate.isFinite
    }

    private func read() -> [SmokingEntry]? {
        guard !userID.isEmpty else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            return nil
        }
        guard let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.version == Archive.currentVersion, archive.userID == userID,
              Set(archive.entries.map(\.id)).count == archive.entries.count,
              archive.entries.allSatisfy(isValid) else { return nil }
        return archive.entries.sorted(by: SmokingAnalytics.precedes)
    }

    /// Writes first and publishes only after the file is safely replaced.
    private func commit(_ unsorted: [SmokingEntry]) -> Bool {
        let next = unsorted.sorted(by: SmokingAnalytics.precedes)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(Archive(version: Archive.currentVersion, userID: userID, entries: next))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
        } catch {
            return reject(Self.unsavedMessage)
        }
        entries = next
        errorMessage = nil
        return true
    }

    private func reject(_ message: String) -> Bool {
        errorMessage = message
        return false
    }

    private func reject(_ message: String) -> SmokingEntry? {
        errorMessage = message
        return nil
    }
}
