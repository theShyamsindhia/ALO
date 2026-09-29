import Foundation
import Testing
@testable import ALO

@MainActor
struct SmokingLogStoreTests {
    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SmokingLogStoreTests-\(UUID().uuidString)")
    }

    private func fixtureUser() -> String { "fixture-\(UUID().uuidString)" }

    private func entry(_ at: Date, _ brand: SmokingBrand = .classicConnect, id: UUID = UUID(), userID: String = "fixture") -> SmokingEntry {
        SmokingEntry(id: id, userID: userID, brand: brand, smokedAt: at, recordedAt: at, timeZoneID: "Asia/Kolkata")
    }

    private func storeFile(in directory: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        return try #require(files.first)
    }

    @Test func brandPricesAndTotalsUseExactPaise() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(SmokingBrand.allCases.map(\.title) == ["Classic Connect", "Marlboro Clove Mix"])
        #expect(SmokingBrand.classicConnect.pricePaise == 2150 && SmokingBrand.marlboroCloveMix.pricePaise == 2400)
        #expect(SmokingBrand.allCases.allSatisfy { $0.pricePaise * $0.packCount == $0.packPricePaise })
        #expect(SmokingContext.allCases.map(\.title) == ["With people", "After food", "Stress", "Habit"])

        let now = date(calendar("Asia/Kolkata"), 2026, 9, 29, 22)
        let store = SmokingLogStore(userID: fixtureUser(), directory: directory)
        for minute in 1...20 {
            #expect(store.add(brand: .classicConnect, smokedAt: now.addingTimeInterval(TimeInterval(-60 * minute)), context: nil, now: now) != nil)
        }
        #expect(SmokingAnalytics.money(SmokingAnalytics.costPaise(entries: store.entries)) == "₹430.00")
        for minute in 1...10 {
            #expect(store.add(brand: .marlboroCloveMix, smokedAt: now.addingTimeInterval(TimeInterval(-3600 - 60 * minute)), context: .stress, now: now) != nil)
        }
        let marlboro = store.entries.filter { $0.brand == .marlboroCloveMix }
        #expect(marlboro.count == 10)
        #expect(SmokingAnalytics.money(SmokingAnalytics.costPaise(entries: marlboro)) == "₹240.00")
        #expect(SmokingAnalytics.costPaise(entries: store.entries) == 67_000)
        #expect(SmokingAnalytics.money(67_000) == "₹670.00")

        #expect(SmokingAnalytics.money(2150) == "₹21.50")
        #expect(SmokingAnalytics.money(5) == "₹0.05")
        #expect(SmokingAnalytics.money(0) == "₹0.00")
        #expect(SmokingAnalytics.money(10_000_000) == "₹1,00,000.00")
        #expect(SmokingAnalytics.money(1_234_567_890) == "₹1,23,45,678.90")
        #expect(SmokingAnalytics.money(-2150) == "-₹21.50")
    }

    @Test func insertsAndBackdatesInChronologicalOrderAcrossRestart() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kolkata = calendar("Asia/Kolkata")
        let user = fixtureUser()
        let now = date(kolkata, 2026, 9, 29, 20)
        let store = SmokingLogStore(userID: user, directory: directory)
        let noon = try #require(store.add(brand: .classicConnect, smokedAt: date(kolkata, 2026, 9, 29, 12), context: .afterFood, now: now))
        let backdated = try #require(store.add(brand: .marlboroCloveMix, smokedAt: date(kolkata, 2026, 9, 27, 9), context: .stress, now: now))
        let lateNight = try #require(store.add(brand: .classicConnect, smokedAt: date(kolkata, 2026, 9, 28, 23, 59), context: nil, now: now))
        #expect(store.entries.map(\.id) == [backdated.id, lateNight.id, noon.id])
        #expect(noon.userID == user && noon.recordedAt == now && noon.pricePaise == 2150 && noon.context == .afterFood)
        #expect(backdated.pricePaise == 2400 && backdated.recordedAt == now)

        let tied = try #require(store.add(brand: .classicConnect, smokedAt: noon.smokedAt, context: .habit, now: now))
        #expect(store.entries.suffix(2).map(\.id) == [noon, tied].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id))

        let reopened = SmokingLogStore(userID: user, directory: directory)
        #expect(reopened.errorMessage == nil)
        #expect(reopened.entries == store.entries)
    }

    @Test func editDeleteAndUndoPersistAcrossRestart() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kolkata = calendar("Asia/Kolkata")
        let user = fixtureUser()
        let now = date(kolkata, 2026, 9, 29, 20)
        let store = SmokingLogStore(userID: user, directory: directory)
        let current = try #require(store.add(brand: .classicConnect, smokedAt: date(kolkata, 2026, 9, 29, 10), context: nil, now: now))
        // An entry logged when the pack cost less keeps its original snapshot.
        let legacy = SmokingEntry(userID: user, brand: .classicConnect, smokedAt: date(kolkata, 2026, 9, 29, 8), pricePaise: 2000,
                                  context: .habit, recordedAt: date(kolkata, 2026, 9, 29, 8), timeZoneID: "Asia/Kolkata")
        #expect(store.restore(legacy))

        #expect(store.update(id: legacy.id, brand: .classicConnect, smokedAt: date(kolkata, 2026, 9, 29, 11), context: .withPeople, now: now))
        var edited = try #require(store.entries.first { $0.id == legacy.id })
        #expect(edited.pricePaise == 2000 && edited.context == .withPeople && edited.recordedAt == legacy.recordedAt)
        #expect(store.entries.map(\.id) == [current.id, legacy.id])
        #expect(store.update(id: legacy.id, brand: .marlboroCloveMix, smokedAt: edited.smokedAt, context: nil, now: now))
        edited = try #require(store.entries.first { $0.id == legacy.id })
        #expect(edited.pricePaise == 2400 && edited.brand == .marlboroCloveMix && edited.context == nil)
        #expect(store.update(id: legacy.id, brand: .classicConnect, smokedAt: edited.smokedAt, context: nil, now: now))
        #expect(store.entries.first { $0.id == legacy.id }?.pricePaise == 2150)
        #expect(!store.update(id: UUID(), brand: .classicConnect, smokedAt: edited.smokedAt, context: nil, now: now))
        #expect(store.errorMessage != nil)

        #expect(store.remove(id: current.id))
        #expect(!store.remove(id: current.id))
        #expect(SmokingLogStore(userID: user, directory: directory).entries.map(\.id) == [legacy.id])
        #expect(store.restore(current))
        #expect(!store.restore(current))
        #expect(store.errorMessage != nil)

        let reopened = SmokingLogStore(userID: user, directory: directory)
        #expect(reopened.entries == store.entries)
        #expect(reopened.entries.map(\.id) == [current.id, legacy.id])
        #expect(reopened.entries.first?.pricePaise == 2150)
    }

    @Test func rejectsFutureNonfiniteForeignAndInvalidEntries() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = fixtureUser()
        let now = date(calendar("Asia/Kolkata"), 2026, 9, 29, 12)
        let store = SmokingLogStore(userID: user, directory: directory)
        #expect(store.add(brand: .classicConnect, smokedAt: now.addingTimeInterval(3600), context: nil, now: now) == nil)
        #expect(store.errorMessage != nil)
        #expect(store.add(brand: .classicConnect, smokedAt: Date(timeIntervalSinceReferenceDate: .infinity), context: nil, now: now) == nil)
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        let saved = try #require(store.add(brand: .classicConnect, smokedAt: now, context: nil, now: now))
        #expect(store.errorMessage == nil)
        #expect(!store.update(id: saved.id, brand: .classicConnect, smokedAt: now.addingTimeInterval(1), context: nil, now: now))
        #expect(!store.update(id: saved.id, brand: .classicConnect, smokedAt: Date(timeIntervalSinceReferenceDate: .nan), context: nil, now: now))

        let earlier = now.addingTimeInterval(-60)
        #expect(!store.restore(entry(earlier, userID: fixtureUser())))
        #expect(!store.restore(SmokingEntry(userID: user, brand: .classicConnect, smokedAt: earlier, pricePaise: -1, recordedAt: now)))
        #expect(!store.restore(SmokingEntry(userID: user, brand: .classicConnect, smokedAt: earlier,
                                            pricePaise: SmokingLogStore.maximumPricePaise + 1, recordedAt: now)))
        #expect(!store.restore(entry(Date(timeIntervalSinceReferenceDate: .nan), userID: user)))
        #expect(!store.restore(SmokingEntry(userID: user, brand: .classicConnect, smokedAt: earlier, recordedAt: now, timeZoneID: "")))
        #expect(store.errorMessage != nil)
        #expect(store.entries == [saved])
        #expect(SmokingLogStore(userID: user, directory: directory).entries == [saved])
    }

    @Test func unreadableFilesAreNeverOverwrittenAndReloadRecovers() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = fixtureUser()
        let now = date(calendar("Asia/Kolkata"), 2026, 9, 29, 12)
        let store = SmokingLogStore(userID: user, directory: directory)
        let saved = try #require(store.add(brand: .classicConnect, smokedAt: now, context: .habit, now: now))
        let file = try storeFile(in: directory)
        let good = try Data(contentsOf: file)
        let text = try #require(String(data: good, encoding: .utf8))
        var object = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
        let rows = try #require(object["entries"] as? [Any])
        object["entries"] = rows + rows
        let variants = [
            Data("not json".utf8),
            Data(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8),
            Data(text.replacingOccurrences(of: "classicConnect", with: "unknownBrand").utf8),
            Data(text.replacingOccurrences(of: "\"habit\"", with: "\"unknownContext\"").utf8),
            Data(text.replacingOccurrences(of: "\"pricePaise\":2150", with: "\"pricePaise\":-2150").utf8),
            Data(text.replacingOccurrences(of: user, with: fixtureUser()).utf8),
            try JSONSerialization.data(withJSONObject: object)
        ]

        for variant in variants {
            #expect(variant != good)
            try variant.write(to: file)
            let blocked = SmokingLogStore(userID: user, directory: directory)
            #expect(blocked.entries.isEmpty)
            #expect(blocked.errorMessage != nil)
            #expect(blocked.add(brand: .classicConnect, smokedAt: now, context: nil, now: now) == nil)
            #expect(!blocked.restore(saved))
            blocked.reload()
            #expect(blocked.errorMessage != nil)
            #expect(try Data(contentsOf: file) == variant)
        }

        // A healthy store keeps showing its last good state but refuses writes once the file goes bad.
        try Data("{".utf8).write(to: file)
        store.reload()
        #expect(store.entries == [saved])
        #expect(store.errorMessage != nil)
        #expect(!store.remove(id: saved.id))
        #expect(try Data(contentsOf: file) == Data("{".utf8))

        try good.write(to: file)
        store.reload()
        #expect(store.errorMessage == nil)
        #expect(store.entries == [saved])
        #expect(store.add(brand: .marlboroCloveMix, smokedAt: now, context: nil, now: now) != nil)
        #expect(SmokingLogStore(userID: user, directory: directory).entries.count == 2)
    }

    @Test func accountsAreIsolatedInSeparateOpaqueFiles() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = date(calendar("Asia/Kolkata"), 2026, 9, 29, 12)
        let alice = fixtureUser()
        let bob = fixtureUser()
        let aliceStore = SmokingLogStore(userID: alice, directory: directory)
        let bobStore = SmokingLogStore(userID: bob, directory: directory)
        #expect(aliceStore.add(brand: .classicConnect, smokedAt: now.addingTimeInterval(-120), context: nil, now: now) != nil)
        #expect(aliceStore.add(brand: .classicConnect, smokedAt: now.addingTimeInterval(-60), context: nil, now: now) != nil)
        #expect(bobStore.add(brand: .marlboroCloveMix, smokedAt: now, context: nil, now: now) != nil)
        #expect(!bobStore.restore(aliceStore.entries[0]))

        let aliceAgain = SmokingLogStore(userID: alice, directory: directory)
        let bobAgain = SmokingLogStore(userID: bob, directory: directory)
        #expect(aliceAgain.entries == aliceStore.entries && aliceAgain.entries.count == 2)
        #expect(aliceAgain.entries.allSatisfy { $0.userID == alice })
        #expect(bobAgain.entries == bobStore.entries && bobAgain.entries.count == 1)
        #expect(bobAgain.entries.allSatisfy { $0.userID == bob })

        let anonymous = SmokingLogStore(userID: "", directory: directory)
        #expect(anonymous.errorMessage != nil)
        #expect(anonymous.add(brand: .classicConnect, smokedAt: now, context: nil, now: now) == nil)

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.count == 2)
        #expect(names.allSatisfy { !$0.contains(alice) && !$0.contains(bob) })
    }

    @Test func failedSavesLeaveInMemoryStateUnchanged() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let user = fixtureUser()
        let now = date(calendar("Asia/Kolkata"), 2026, 9, 29, 12)
        let store = SmokingLogStore(userID: user, directory: directory)
        let first = try #require(store.add(brand: .classicConnect, smokedAt: now.addingTimeInterval(-60), context: nil, now: now))

        // A plain file where the log folder belongs makes every write fail.
        try FileManager.default.removeItem(at: directory)
        #expect(FileManager.default.createFile(atPath: directory.path, contents: Data()))
        #expect(store.add(brand: .classicConnect, smokedAt: now, context: nil, now: now) == nil)
        #expect(store.errorMessage != nil)
        #expect(!store.update(id: first.id, brand: .marlboroCloveMix, smokedAt: now, context: .stress, now: now))
        #expect(!store.remove(id: first.id))
        #expect(!store.restore(entry(now, userID: user)))
        #expect(store.entries == [first])

        try FileManager.default.removeItem(at: directory)
        #expect(store.add(brand: .classicConnect, smokedAt: now, context: nil, now: now) != nil)
        #expect(store.errorMessage == nil)
        #expect(store.entries.count == 2)
        #expect(SmokingLogStore(userID: user, directory: directory).entries == store.entries)
    }

    @Test func dayAndMonthBinsRespectHalfOpenBoundaries() {
        let kolkata = calendar("Asia/Kolkata")
        let from = date(kolkata, 2028, 2, 1, 0)
        let to = date(kolkata, 2028, 3, 1, 0)
        let rows = [
            entry(from.addingTimeInterval(-1)),
            entry(from),
            entry(date(kolkata, 2028, 2, 1, 23, 59), .marlboroCloveMix),
            entry(date(kolkata, 2028, 2, 29, 23, 59)),
            entry(to)
        ]
        let month = SmokingAnalytics.dailyTotals(entries: rows, from: from, to: to, calendar: kolkata)
        #expect(month.count == 29)
        #expect(month.first?.day == from && month.last?.day == date(kolkata, 2028, 2, 29, 0))
        #expect(month[0].count == 2 && month[0].costPaise == 4550)
        #expect(month[28].count == 1 && month[28].costPaise == 2150)
        #expect(month[1..<28].allSatisfy { $0.count == 0 && $0.costPaise == 0 })
        #expect(SmokingAnalytics.entries(in: rows, from: from, to: to).map(\.id) == rows[1...3].map(\.id))

        let partial = SmokingAnalytics.dailyTotals(entries: rows, from: date(kolkata, 2028, 2, 1, 12), to: date(kolkata, 2028, 2, 2, 6), calendar: kolkata)
        #expect(partial.map(\.day) == [from, date(kolkata, 2028, 2, 2, 0)])
        #expect(partial.map(\.count) == [1, 0])

        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let high = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let tied = [entry(from, id: high), entry(from, id: low)]
        #expect(SmokingAnalytics.entries(in: tied, from: .distantPast, to: .distantFuture).map(\.id) == [low, high])
    }

    @Test func daylightSavingDaysBinByLocalCalendarDay() {
        let newYork = calendar("America/New_York")
        let spring = SmokingAnalytics.dailyTotals(entries: [entry(date(newYork, 2026, 3, 8, 23, 30))],
                                                  from: date(newYork, 2026, 3, 7, 0), to: date(newYork, 2026, 3, 10, 0), calendar: newYork)
        #expect(spring.map(\.count) == [0, 1, 0])
        #expect(spring[2].day.timeIntervalSince(spring[1].day) == 23 * 3600)

        let repeatedHour = date(newYork, 2026, 11, 1, 1, 30)
        let rows = [entry(repeatedHour), entry(repeatedHour.addingTimeInterval(3600)),
                    entry(date(newYork, 2026, 11, 1, 23, 30)), entry(date(newYork, 2026, 11, 2, 0))]
        let fall = SmokingAnalytics.dailyTotals(entries: rows, from: date(newYork, 2026, 10, 31, 0), to: date(newYork, 2026, 11, 3, 0), calendar: newYork)
        #expect(fall.map(\.count) == [0, 3, 1])
        #expect(fall[2].day.timeIntervalSince(fall[1].day) == 25 * 3600)
    }

    @Test func typicalIntervalIgnoresOvernightAndDuplicateTimestamps() {
        let kolkata = calendar("Asia/Kolkata")
        let rows = [
            entry(date(kolkata, 2026, 9, 1, 8)), entry(date(kolkata, 2026, 9, 1, 9)),
            entry(date(kolkata, 2026, 9, 1, 9), .marlboroCloveMix), entry(date(kolkata, 2026, 9, 1, 11)),
            entry(date(kolkata, 2026, 9, 2, 7)), entry(date(kolkata, 2026, 9, 2, 10)),
            entry(date(kolkata, 2026, 9, 3, 23, 50)), entry(date(kolkata, 2026, 9, 4, 0, 10))
        ]
        // Same-day gaps are 1h, 2h and 3h; the 20h overnight and 20m cross-midnight gaps must not count.
        #expect(SmokingAnalytics.typicalInterval(entries: rows.reversed(), calendar: kolkata) == 2 * 3600)

        let even = [entry(date(kolkata, 2026, 9, 1, 8)), entry(date(kolkata, 2026, 9, 1, 9)),
                    entry(date(kolkata, 2026, 9, 2, 7)), entry(date(kolkata, 2026, 9, 2, 11))]
        #expect(SmokingAnalytics.typicalInterval(entries: even, calendar: kolkata) == 2.5 * 3600)

        let noon = date(kolkata, 2026, 9, 1, 12)
        #expect(SmokingAnalytics.typicalInterval(entries: [entry(noon)], calendar: kolkata) == nil)
        #expect(SmokingAnalytics.typicalInterval(entries: [entry(noon), entry(noon)], calendar: kolkata) == nil)
        #expect(SmokingAnalytics.typicalInterval(entries: Array(rows.suffix(2)), calendar: kolkata) == nil)
    }

    @Test func emptyDataProducesExplicitZerosAndNoFiles() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kolkata = calendar("Asia/Kolkata")
        let from = date(kolkata, 2026, 9, 21, 0)
        let to = date(kolkata, 2026, 9, 28, 0)
        let week = SmokingAnalytics.dailyTotals(entries: [], from: from, to: to, calendar: kolkata)
        #expect(week.count == 7 && week.allSatisfy { $0.count == 0 && $0.costPaise == 0 })
        #expect(SmokingAnalytics.dailyTotals(entries: [], from: to, to: from, calendar: kolkata).isEmpty)
        #expect(SmokingAnalytics.dailyTotals(entries: [], from: from, to: from, calendar: kolkata).isEmpty)
        let noon = from.addingTimeInterval(12 * 3600)
        #expect(SmokingAnalytics.dailyTotals(entries: [], from: noon, to: noon, calendar: kolkata).isEmpty)
        #expect(SmokingAnalytics.entries(in: [], from: .distantPast, to: .distantFuture).isEmpty)
        #expect(SmokingAnalytics.costPaise(entries: []) == 0)
        #expect(SmokingAnalytics.typicalInterval(entries: [], calendar: kolkata) == nil)

        let store = SmokingLogStore(userID: fixtureUser(), directory: directory)
        #expect(store.entries.isEmpty && store.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
