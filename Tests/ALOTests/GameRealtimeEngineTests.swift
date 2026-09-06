import Foundation
import Testing
import ALOCore
@testable import ALO

struct GameRealtimeEngineTests {
    @Test func renderCadenceDoesNotChangeSimulationTimeOrSnapshotCadence() {
        for hz in [30, 60, 120, 144] {
            var engine = GameRealtimeEngine<ArenaInput>(); engine.rebaseClock(at: 0)
            var steps = 0, snapshots = 0
            for i in 1...hz {
                let frame = engine.advance(at: Double(i) / Double(hz), running: true)
                steps += frame.steps; if frame.publishSnapshot { snapshots += 1 }
            }
            #expect(steps == 60); #expect(snapshots == 30)
        }
    }
    @Test func longStallsCannotAccumulateAPlaybackBacklog() {
        var engine = GameRealtimeEngine<StickFightInput>(); engine.rebaseClock(at: 0)
        #expect(engine.advance(at: 20, running: true).steps == 6)
        #expect(engine.advance(at: 20, running: true).steps == 0)
        #expect(engine.advance(at: 19, running: true).steps == 0)
        #expect(engine.advance(at: 20 + GameRealtimePolicy.step, running: true).steps == 1)
        #expect(engine.advance(at: 25, running: false).steps == 0)
        #expect(engine.advance(at: 25 + GameRealtimePolicy.step, running: true).steps == 1)
    }
    @Test func predictionUsesActualStepsAndAcknowledgements() {
        var engine = GameRealtimeEngine<Int>()
        engine.recordInput(sequence: 1, input: 10, steps: 3)
        engine.recordInput(sequence: 2, input: 20, steps: 2)
        #expect(engine.acknowledge(1) == [20,20])
        #expect(engine.acknowledge(2).isEmpty)
        engine.recordInput(sequence: 3, input: 30, steps: 6)
        engine.recordInput(sequence: 4, input: 40, steps: 6)
        #expect(engine.acknowledge(2) == Array(repeating: 40, count: 6))
        #expect(engine.acknowledge(nil).isEmpty)
    }
    @Test func jitterBufferInterpolatesAndBoundsOutageExtrapolation() {
        var engine = GameRealtimeEngine<Int>()
        for i in 0...6 {
            let time = Double(i) / 30
            engine.receiveSnapshot(frame: i * 2, epoch: "one", at: 10 + time,
                                   motion: [.init(x: time * 300, y: 100, vx: 300, vy: 0)])
        }
        let fallback = GameMotion(x: 60, y: 100, vx: 300, vy: 0)
        let a = engine.position(for: 0, at: 10.19, fallback: fallback, remote: true)
        let b = engine.position(for: 0, at: 10.19 + 1.0/120, fallback: fallback, remote: true)
        #expect(abs((b.x - a.x) - 2.5) < 0.0001)
        #expect(engine.position(for: 0, at: 50, fallback: fallback, remote: true).x <= 70.0001)
        #expect(engine.position(for: 0, at: 50, fallback: fallback, remote: false) == fallback)
        let acceptedStale = engine.receiveSnapshot(frame: 10, epoch: "one", at: 11, motion: [fallback])
        #expect(!acceptedStale)
        engine.receiveSnapshot(frame: 14, epoch: "one", at: 10.233,
                               motion: [.init(x: 500, y: 100, vx: 0, vy: 0, continuity: 1)])
        let respawned = GameMotion(x: 500, y: 100, vx: 0, vy: 0, continuity: 1)
        #expect(engine.position(for: 0, at: 10.234, fallback: respawned, remote: true).x == 500)
    }
    @Test func renderRateAndInjectedJitterStayFiniteAndBounded() {
        for hz in [30,60,144] {
            var engine = GameRealtimeEngine<Int>()
            var packet = 0
            for tick in 0..<(hz*3) {
                let now = Double(tick)/Double(hz)
                while packet < 75 && Double(packet)/30 + Double(packet%4)*0.003 <= now {
                    engine.receiveSnapshot(frame: packet*2, epoch: "match", at: Double(packet)/30 + Double(packet%4)*0.003,
                                           motion: [.init(x: Double(packet)*5,y:100,vx:150,vy:0)])
                    packet += 1
                }
                let p = engine.position(for: 0, at: now, fallback: .init(x:0,y:100,vx:0,vy:0), remote:true)
                #expect(p.x.isFinite && p.x >= 0 && p.x <= 375)
                #expect(engine.interpolationDelay >= 1.0/30 && engine.interpolationDelay <= 0.083)
            }
        }
    }
    @Test func gamesAndDirectionsCannotOverwriteOrCancelEachOther() {
        var queue = GameSendQueue()
        queue.enqueue(kind:"state",data:Data([1]),stream:"rift/a")
        queue.enqueue(kind:"state",data:Data([2]),stream:"stick/b")
        queue.enqueue(kind:"input",data:Data([3]),stream:"stick/b")
        queue.enqueue(kind:"state",data:Data([4]),stream:"stick/b")
        queue.enqueue(kind:"leave",data:Data([5]),stream:"rift/a")
        #expect(queue.popFirst() == Data([5]))
        #expect(queue.popFirst() == Data([4]))
        #expect(queue.popFirst() == Data([3]))
        #expect(queue.popFirst() == nil)
    }
    @Test func riftPredictionCannotDealDamageOrAdvanceTheMatch() {
        var sim = ArenaSimulation(); sim.countdown = 0
        let original = sim
        var input = ArenaInput(); input.horizontal = 1; input.jump = true; input.light = true; input.heavy = true
        for _ in 0..<6 { sim.predictMovement(slot: 0, input: input) }
        #expect(sim.fighters[0].x > original.fighters[0].x)
        #expect(sim.fighters[0].y > original.fighters[0].y)
        #expect(sim.fighters[1] == original.fighters[1])
        #expect(sim.fighters[0].damage == original.fighters[0].damage)
        #expect(sim.fighters[0].attackFrames == 0)
        #expect(sim.frame == original.frame && sim.remainingFrames == original.remainingFrames)
    }
    @Test @MainActor func menuPausesPracticeButNeverTheMultiplayerHost() {
        #expect(GameRealtimePolicy.pausesWorld(multiplayer:false,menuOpen:true))
        #expect(!GameRealtimePolicy.pausesWorld(multiplayer:true,menuOpen:true))
        let arena = ArenaSession(); defer { arena.disconnect() }
        arena.host(botCount: 1); arena.readyUp()
        arena.togglePause()
        let frame = arena.simulation.frame
        arena.update(at: ProcessInfo.processInfo.systemUptime + 0.05)
        #expect(arena.simulation.frame > frame)
        #expect(!arena.paused)
        arena.practice(); arena.togglePause()
        let practice = arena.simulation
        arena.update(at: ProcessInfo.processInfo.systemUptime + 0.1)
        #expect(arena.simulation == practice)
        let stick = StickFightSession(); defer { stick.disconnect() }
        stick.send = { _,_ in }; stick.host(botCount:1); stick.readyUp(); stick.togglePause()
        let stickFrame = stick.simulation.frame
        stick.update(at:ProcessInfo.processInfo.systemUptime+0.05)
        #expect(stick.simulation.frame > stickFrame)
        stick.practice(); stick.togglePause()
        let offline = stick.simulation
        stick.update(at:ProcessInfo.processInfo.systemUptime+0.1)
        #expect(stick.simulation == offline)
    }
}
