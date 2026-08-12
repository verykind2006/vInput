import Testing
@testable import vInput

@Suite("AudioBuffer")
struct AudioBufferTests {
    @Test("新建时为空且时长为零")
    func startsEmpty() {
        let buffer = AudioBuffer(sampleRate: 16_000)
        #expect(buffer.samples.isEmpty)
        #expect(buffer.duration == 0)
    }

    @Test("追加样本后时长按采样率换算")
    func durationReflectsSampleCount() {
        var buffer = AudioBuffer(sampleRate: 16_000)
        buffer.append(Array(repeating: 0.5, count: 8_000))
        #expect(buffer.samples.count == 8_000)
        #expect(abs(buffer.duration - 0.5) < 0.0001)
    }

    @Test("多次追加会累积")
    func appendAccumulates() {
        var buffer = AudioBuffer(sampleRate: 16_000)
        buffer.append([1, 2, 3])
        buffer.append([4, 5])
        #expect(buffer.samples == [1, 2, 3, 4, 5])
    }

    @Test("取窗口返回最近 N 秒的样本")
    func windowReturnsMostRecent() {
        var buffer = AudioBuffer(sampleRate: 10)
        buffer.append(Array(0..<100).map(Float.init))
        let window = buffer.window(lastSeconds: 2)
        #expect(window.count == 20)
        #expect(window.first == 80)
        #expect(window.last == 99)
    }

    @Test("样本不足一个窗口时返回全部")
    func windowShorterThanRequested() {
        var buffer = AudioBuffer(sampleRate: 10)
        buffer.append([1, 2, 3])
        #expect(buffer.window(lastSeconds: 5) == [1, 2, 3])
    }

    @Test("reset 后回到空状态")
    func resetClears() {
        var buffer = AudioBuffer(sampleRate: 16_000)
        buffer.append([1, 2, 3])
        buffer.reset()
        #expect(buffer.samples.isEmpty)
        #expect(buffer.duration == 0)
    }
}
