import AppKit
import Charts
import Combine
import SwiftUI
import ALOCore

/// Personal records never enter the room transport. Sharing sends only a reviewed text summary.
@MainActor
final class SmokingLogController {
    private weak var model: ALOViewModel?
    private var store: SmokingLogStore?
    private var window: NSWindow?
    private var popover: NSPopover?
    private var identityObserver: AnyCancellable?

    init(model: ALOViewModel) {
        self.model = model
        identityObserver = model.account.$identityReady.combineLatest(model.account.$identity)
            .map { ready, identity in ready ? identity?.publicIdentity.userID : nil }
            .removeDuplicates().sink { [weak self] root in
                guard let self, self.store?.userID != root else { return }
                self.popover?.close(); self.window?.close()
                self.popover = nil; self.window = nil; self.store = nil
            }
    }

    private func personalStore() -> SmokingLogStore? {
        guard let model, model.account.identityReady,
              let root = model.account.identity?.publicIdentity.userID else {
            let alert = NSAlert()
            alert.messageText = "Set up your ALO profile first"
            alert.informativeText = "The smoking log belongs to your personal profile. Finish setup in Networks, then open it again."
            alert.runModal()
            return nil
        }
        if store?.userID != root { store = SmokingLogStore(userID: root) }
        return store
    }

    func showQuickLog(from anchor: NSView?) {
        guard let anchor else { showHistory(); return }
        if popover?.isShown == true { popover?.close(); return }
        guard let store = personalStore() else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SmokingQuickLogView(store: store) { [weak self] in
            self?.showHistory()
        })
        self.popover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func showHistory() {
        guard let model, let store = personalStore() else { return }
        popover?.close()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 560, height: 600)
            window.setFrameAutosaveName("ALO.SmokingLog")
            window.center()
            self.window = window
        }
        if window?.isVisible != true {
            window?.title = "\(model.account.displayName) · Smoking log"
            window?.contentView = NSHostingView(rootView: SmokingHistoryView(store: store,
                profileName: model.account.displayName,
                shareAction: AnyView(SmokingShareButton(store: store, model: model))))
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SmokingQuickLogView: View {
    @ObservedObject var store: SmokingLogStore
    let onHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Smoking log").font(.headline)
                Spacer()
                Label("Private", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
            }
            SmokingEntryForm(store: store)
            Divider()
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                let day = Calendar.current.startOfDay(for: timeline.date)
                let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: day)!
                let today = SmokingAnalytics.entries(in: store.entries, from: day, to: nextDay)
                HStack {
                    Text("Today · \(today.count) logged").foregroundStyle(.secondary)
                    Spacer()
                    Text(SmokingAnalytics.money(SmokingAnalytics.costPaise(entries: today))).monospacedDigit()
                }.font(.callout)
            }
            Button("View history & stats", action: onHistory).buttonStyle(.link)
        }.padding(20).frame(width: 340)
    }
}

struct SmokingEntryForm: View {
    @ObservedObject var store: SmokingLogStore
    var entry: SmokingEntry?
    var onSaved: () -> Void = {}
    @State private var brand = SmokingBrand.classicConnect
    @State private var context: SmokingContext?
    @State private var earlier = false
    @State private var time = Date()
    @State private var lastAdded: SmokingEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Cigarette", selection: $brand) {
                ForEach(SmokingBrand.allCases) { brand in
                    Text("\(brand.title) · \(SmokingAnalytics.money(brand.pricePaise))").tag(brand)
                }
            }.accessibilityIdentifier("ALO.Smoking.Brand")
            Text("\(SmokingAnalytics.money(brand.packPricePaise)) per pack of \(brand.packCount)")
                .font(.caption).foregroundStyle(.secondary)
            if entry == nil { Toggle("Log an earlier time", isOn: $earlier) }
            if earlier || entry != nil {
                DatePicker("Smoked at", selection: $time, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    .accessibilityIdentifier("ALO.Smoking.Time")
            } else {
                Label("Time · Now", systemImage: "clock").foregroundStyle(.secondary)
            }
            Picker("Context · optional", selection: $context) {
                Text("Not specified").tag(Optional<SmokingContext>.none)
                ForEach(SmokingContext.allCases) { Text($0.title).tag(Optional($0)) }
            }
            if let error = store.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                if !store.isReadable { Button("Reload saved log") { store.reload() } }
            }
            HStack {
                if lastAdded != nil {
                    Text("Logged").font(.callout).foregroundStyle(.secondary)
                    Button("Undo") {
                        if let lastAdded, store.remove(id: lastAdded.id) { self.lastAdded = nil }
                    }.accessibilityIdentifier("ALO.Smoking.Undo")
                }
                Spacer()
                Button(entry == nil ? "Log cigarette" : "Save changes", action: save)
                    .buttonStyle(.borderedProminent).disabled(!store.isReadable)
                    .accessibilityIdentifier("ALO.Smoking.Save")
            }
        }
        .onAppear {
            if let entry { brand = entry.brand; context = entry.context; time = entry.smokedAt }
            else if let latest = store.entries.last { brand = latest.brand }
        }
    }

    private func save() {
        if let entry {
            if store.update(id: entry.id, brand: brand, smokedAt: time, context: context) { onSaved() }
        } else if let added = store.add(brand: brand, smokedAt: earlier ? time : Date(), context: context) {
            lastAdded = added
            onSaved()
        }
    }
}

enum SmokingPeriod: String, CaseIterable {
    case day = "Day", week = "Week", month = "Month"
    func range(endingOn date: Date, calendar: Calendar) -> DateInterval {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        let days = self == .day ? 1 : self == .week ? 7 : 30
        return DateInterval(start: calendar.date(byAdding: .day, value: -days, to: end)!, end: end)
    }
}

struct SmokingHistoryView: View {
    @ObservedObject var store: SmokingLogStore
    let profileName: String
    var shareAction: AnyView? = nil
    @State private var period = SmokingPeriod.week
    @State private var anchor = Date()
    @State private var showCost = false
    @State private var selectedTime: Date?
    @State private var editing: SmokingEntry?
    @State private var adding = false
    @State private var removed: SmokingEntry?

    init(store: SmokingLogStore, profileName: String, shareAction: AnyView? = nil, period: SmokingPeriod = .week) {
        self.store = store
        self.profileName = profileName
        self.shareAction = shareAction
        _period = State(initialValue: period)
    }

    private var calendar: Calendar { .current }
    private var range: DateInterval { period.range(endingOn: anchor, calendar: calendar) }
    private var entries: [SmokingEntry] {
        SmokingAnalytics.entries(in: store.entries, from: range.start, to: range.end)
    }
    private var selectedEntry: SmokingEntry? {
        guard let selectedTime else { return nil }
        return entries.min { abs($0.smokedAt.timeIntervalSince(selectedTime)) < abs($1.smokedAt.timeIntervalSince(selectedTime)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                periodControls
                metrics
                graph
                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.red)
                    if !store.isReadable { Button("Reload saved log") { store.reload() } }
                }
                if period == .day, let entry = selectedEntry {
                    entryRow(entry)
                }
                Divider()
                history
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("Your timeline stays on this Mac", systemImage: "lock").font(.callout.weight(.medium))
                    Text("Linked to your ALO profile. Times and context tags are never shared automatically. Other Macs do not sync this log.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let shareAction { shareAction }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Log cigarette").font(.title3.weight(.semibold))
                SmokingEntryForm(store: store) { adding = false }
                HStack { Spacer(); Button("Cancel") { adding = false }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 380)
        }
        .sheet(item: $editing) { entry in
            VStack(alignment: .leading, spacing: 20) {
                Text("Edit entry").font(.title3.weight(.semibold))
                SmokingEntryForm(store: store, entry: entry) { editing = nil }
                HStack { Spacer(); Button("Cancel") { editing = nil }.keyboardShortcut(.cancelAction) }
            }.padding(24).frame(width: 380)
        }
        .onChange(of: period) { _, _ in selectedTime = nil }
        .onChange(of: anchor) { _, _ in selectedTime = nil }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(profileName) / Stats").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text("Smoking log").font(.title2.weight(.semibold))
                Text("Notice the pattern, without judging it.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Log cigarette", systemImage: "plus") { adding = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var periodControls: some View {
        HStack(spacing: 12) {
            Picker("Period", selection: $period) {
                ForEach(SmokingPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
            Spacer()
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }.help("Previous period")
                .accessibilityLabel("Previous period")
            Text(anchor, format: .dateTime.day().month().year()).font(.callout).monospacedDigit()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }.help("Next period")
                .accessibilityLabel("Next period").disabled(calendar.isDateInToday(anchor))
        }.buttonStyle(.borderless)
    }

    private var metrics: some View {
        HStack(alignment: .top, spacing: 32) {
            metric("Logged", value: "\(entries.count)")
            metric("Estimated cost", value: SmokingAnalytics.money(SmokingAnalytics.costPaise(entries: entries)))
            metric("Typical gap", value: SmokingPresentation.interval(SmokingAnalytics.typicalInterval(entries: entries, calendar: calendar)))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.medium)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var graph: some View {
        VStack(alignment: .leading, spacing: 12) {
            if period == .day {
                Chart(entries) { entry in
                    PointMark(x: .value("Time", entry.smokedAt), y: .value("Brand", entry.brand.title))
                        .symbol(by: .value("Brand", entry.brand.title))
                        .foregroundStyle(Color.accentColor).symbolSize(65)
                        .accessibilityLabel("\(entry.brand.title), \(entry.smokedAt.formatted(date: .omitted, time: .shortened))")
                        .accessibilityValue(SmokingAnalytics.money(entry.pricePaise))
                }
                .chartXScale(domain: range.start...range.end)
                .chartYScale(domain: SmokingBrand.allCases.map(\.title))
                .chartXSelection(value: $selectedTime)
                .chartLegend(.hidden).frame(height: 150)
                Text("Select a dot for details. Each dot is one logged cigarette.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                let totals = SmokingAnalytics.dailyTotals(entries: entries, from: range.start, to: range.end, calendar: calendar)
                let countStep = max(1, ceil(Double(totals.map(\.count).max() ?? 0) / 5))
                HStack {
                    Text("\(range.start.formatted(.dateTime.day().month())) – \(anchor.formatted(.dateTime.day().month()))")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Picker("Measure", selection: $showCost) {
                        Text("Cigarettes").tag(false)
                        Text("Cost (₹)").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                }
                Chart(totals) { day in
                    BarMark(x: .value("Day", day.day, unit: .day),
                            y: .value(showCost ? "Cost (₹)" : "Cigarettes", showCost ? Double(day.costPaise) / 100 : Double(day.count)))
                        .foregroundStyle(Color.accentColor).cornerRadius(3)
                        .accessibilityLabel(day.day.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(day.count) logged, \(SmokingAnalytics.money(day.costPaise))")
                }
                .chartXScale(domain: range.start...range.end)
                .chartYAxis {
                    if showCost { AxisMarks() }
                    else { AxisMarks(values: .stride(by: countStep)) }
                }
                .frame(height: 170)
            }
            Text("Cost estimates cigarettes smoked, not pack purchases. Typical gap is the median within-day interval; overnight gaps are excluded. Empty days mean no entries, not confirmed smoke-free days.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Entries").font(.headline)
                Spacer()
                if let removed {
                    Button("Undo deletion") {
                        if store.restore(removed) { self.removed = nil }
                    }
                }
            }
            if entries.isEmpty {
                Text("No cigarettes logged in this period.").foregroundStyle(.secondary)
                Text("Log now, or add an earlier time if you forgot.").font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(entries.reversed()) { entry in entryRow(entry) }
                }
            }
        }
    }

    private func entryRow(_ entry: SmokingEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.brand.title).font(.callout.weight(.medium))
                Text(entry.smokedAt, format: .dateTime.day().month().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                if let context = entry.context { Text(context.title).font(.caption).foregroundStyle(.secondary) }
                if let gap = SmokingPresentation.previousGap(for: entry, entries: store.entries) {
                    Text("\(SmokingPresentation.interval(gap)) since previous entry").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(SmokingAnalytics.money(entry.pricePaise)).font(.callout).monospacedDigit()
            Menu {
                Button("Edit…") { editing = entry }
                Button("Delete entry", role: .destructive) {
                    if store.remove(id: entry.id) { removed = entry }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Entry options for \(entry.brand.title) at \(entry.smokedAt.formatted())")
        }.padding(.vertical, 4)
    }

    private func shift(_ direction: Int) {
        let days = period == .day ? 1 : period == .week ? 7 : 30
        anchor = min(Date(), calendar.date(byAdding: .day, value: days * direction, to: anchor)!)
    }
}

enum SmokingPresentation {
    static func interval(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "—" }
        let minutes = Int(seconds / 60)
        if minutes == 0 { return "<1 min" }
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m"
    }

    static func previousGap(for entry: SmokingEntry, entries: [SmokingEntry]) -> TimeInterval? {
        entries.filter { $0.smokedAt < entry.smokedAt }.map(\.smokedAt).max().map { entry.smokedAt.timeIntervalSince($0) }
    }

    static func summary(entries: [SmokingEntry], day: Date, calendar: Calendar) -> String {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let today = SmokingAnalytics.entries(in: entries, from: start, to: end)
        return "Smoking log · \(start.formatted(date: .abbreviated, time: .omitted))\n\(today.count) \(today.count == 1 ? "cigarette" : "cigarettes") logged · \(SmokingAnalytics.money(SmokingAnalytics.costPaise(entries: today))) estimated cost\nSelf-reported daily summary. Exact times and context tags are private."
    }
}

struct SmokingSummaryDraft: Identifiable {
    let id = UUID()
    let ownerID: String
    let channelID: String
    let destination: String
    let text: String

    func canSend(identityReady: Bool, currentUserID: String?, currentChannelID: String?, isLive: Bool) -> Bool {
        identityReady && isLive && currentUserID == ownerID && currentChannelID == channelID
    }
}

private struct SmokingShareButton: View {
    @ObservedObject var store: SmokingLogStore
    @ObservedObject var model: ALOViewModel
    @State private var preview: SmokingSummaryDraft?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Share today’s summary…", systemImage: "square.and.arrow.up") {
                guard let channelID = model.selectedRoomID else { return }
                preview = SmokingSummaryDraft(ownerID: store.userID, channelID: channelID,
                    destination: model.roomTitle,
                    text: SmokingPresentation.summary(entries: store.entries, day: Date(), calendar: .current))
                notice = nil
            }.disabled(model.phase != .live || !store.isReadable)
            if model.phase != .live { Text("Join a channel to share a summary.").font(.caption).foregroundStyle(.secondary) }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .sheet(item: $preview) { value in
            VStack(alignment: .leading, spacing: 18) {
                Text("Share with \(value.destination)?").font(.headline)
                Text(value.text).textSelection(.enabled)
                Text("Everyone in this channel can read and retain this message. This shares only this summary, not future entries.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { preview = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Share summary") {
                        guard value.canSend(identityReady: model.account.identityReady,
                                            currentUserID: model.account.identity?.publicIdentity.userID,
                                            currentChannelID: model.selectedRoomID, isLive: model.phase == .live) else {
                            preview = nil; notice = "The channel or profile changed. Review the destination again."; return
                        }
                        notice = model.sendChatOperation(RoomChatOperation(kind: .message, text: value.text))
                            ? "Summary sent to \(value.destination)." : "Could not send. Reconnect and try again."
                        preview = nil
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 420)
        }
    }
}
