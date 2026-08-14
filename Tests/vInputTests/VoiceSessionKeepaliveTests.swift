import Foundation
import Testing
@testable import vInput

@Suite("语音会话保活")
@MainActor
struct VoiceSessionKeepaliveTests {

    private final class Counter {
        var extends = 0
        var timeouts = 0
    }

    private func makeKeepalive() -> (VoiceSessionKeepalive, Counter) {
        let keepalive = VoiceSessionKeepalive()
        let counter = Counter()
        keepalive.onExtend = { counter.extends += 1 }
        keepalive.onTimeout = { counter.timeouts += 1 }
        return (keepalive, counter)
    }

    @Test("未启动时 tick 不做任何事")
    func idleTickDoesNothing() {
        let (keepalive, counter) = makeKeepalive()
        keepalive.tick(now: Date())
        #expect(counter.extends == 0)
        #expect(counter.timeouts == 0)
    }

    @Test("每满一个间隔续期一次")
    func extendsOncePerInterval() {
        let (keepalive, counter) = makeKeepalive()
        let start = Date()
        keepalive.start(now: start)

        keepalive.tick(now: start.addingTimeInterval(5))    // 未满
        #expect(counter.extends == 0)

        keepalive.tick(now: start.addingTimeInterval(10))   // 第一次
        #expect(counter.extends == 1)

        keepalive.tick(now: start.addingTimeInterval(15))   // 未满第二次
        #expect(counter.extends == 1)

        keepalive.tick(now: start.addingTimeInterval(20))   // 第二次
        #expect(counter.extends == 2)
    }

    @Test("续期必须发生在固件的 60 秒切断之前")
    func extendsBeforeFirmwareCutoff() {
        let (keepalive, counter) = makeKeepalive()
        let start = Date()
        keepalive.start(now: start)

        // 60 秒是 RC003 固件主动结束会话的时点。到达之前必须已经续过期，
        // 否则保活毫无意义。10 秒的间隔留出了 6 次机会。
        keepalive.tick(now: start.addingTimeInterval(59))

        #expect(counter.extends >= 1)
    }

    @Test("跳过的间隔会被补上")
    func catchesUpMissedIntervals() {
        // 计时器可能因主线程繁忙而漏拍，一次 tick 跨过多个间隔时要补齐
        let (keepalive, counter) = makeKeepalive()
        let start = Date()
        keepalive.start(now: start)

        keepalive.tick(now: start.addingTimeInterval(35))

        #expect(counter.extends == 3)
    }

    @Test("达到上限时触发超时且不再续期")
    func timesOutAtLimit() {
        let (keepalive, counter) = makeKeepalive()
        let start = Date()
        keepalive.start(now: start)

        keepalive.tick(now: start.addingTimeInterval(VoiceSessionKeepalive.maxDuration))

        #expect(counter.timeouts == 1)
    }

    @Test("超时后停止，后续 tick 不再触发")
    func stopsAfterTimeout() {
        let (keepalive, counter) = makeKeepalive()
        let start = Date()
        keepalive.start(now: start)

        keepalive.tick(now: start.addingTimeInterval(VoiceSessionKeepalive.maxDuration))
        let extendsAtTimeout = counter.extends

        keepalive.tick(now: start.addingTimeInterval(VoiceSessionKeepalive.maxDuration + 30))

        #expect(counter.timeouts == 1)
        #expect(counter.extends == extendsAtTimeout)
    }

    @Test("stop 之后不再续期")
    func stopHalts() {
        let (keepalive, counter) = makeKeepalive()
        let start = Date()
        keepalive.start(now: start)
        keepalive.stop()

        keepalive.tick(now: start.addingTimeInterval(30))

        #expect(counter.extends == 0)
    }

    @Test("重新开始会重置计时")
    func restartResetsClock() {
        let (keepalive, counter) = makeKeepalive()
        let first = Date()
        keepalive.start(now: first)
        keepalive.tick(now: first.addingTimeInterval(10))
        #expect(counter.extends == 1)

        let second = first.addingTimeInterval(100)
        keepalive.start(now: second)
        keepalive.tick(now: second.addingTimeInterval(5))   // 新会话才过 5 秒

        #expect(counter.extends == 1)
    }

    @Test("间隔与上限的取值")
    func constants() {
        #expect(VoiceSessionKeepalive.interval == 10)
        // 180 秒沿用上游的试验安全值，不是固件限制
        #expect(VoiceSessionKeepalive.maxDuration == 180)
    }
}
