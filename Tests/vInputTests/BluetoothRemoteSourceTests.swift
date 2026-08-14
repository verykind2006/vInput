import Testing
@testable import vInput

@Suite("BluetoothRemoteSource")
@MainActor
struct BluetoothRemoteSourceTests {

    // MARK: - Int16 → Float 归一化

    @Test("最大正值归一化到接近 1")
    func normalizesMaxPositive() {
        let floats = BluetoothRemoteSource.normalize([32_767])
        #expect(abs(floats[0] - 1.0) < 0.001)
    }

    @Test("最小负值归一化到 -1")
    func normalizesMinNegative() {
        let floats = BluetoothRemoteSource.normalize([-32_768])
        #expect(abs(floats[0] - (-1.0)) < 0.001)
    }

    @Test("零仍是零")
    func zeroStaysZero() {
        #expect(BluetoothRemoteSource.normalize([0]) == [0])
    }

    @Test("输出全部落在 -1…1")
    func outputInRange() {
        let input: [Int16] = [-32_768, -16_384, 0, 16_384, 32_767]
        let floats = BluetoothRemoteSource.normalize(input)
        #expect(floats.allSatisfy { $0 >= -1 && $0 <= 1 })
    }

    @Test("样本数不变")
    func preservesCount() {
        let input = [Int16](repeating: 100, count: 240)
        #expect(BluetoothRemoteSource.normalize(input).count == 240)
    }

    @Test("空输入返回空")
    func emptyInput() {
        #expect(BluetoothRemoteSource.normalize([]).isEmpty)
    }

    // MARK: - AudioSource 行为

    @Test("推入的样本经归一化后转发")
    func forwardsNormalizedSamples() throws {
        let source = BluetoothRemoteSource()
        var received: [Float] = []
        source.onFrame = { received.append(contentsOf: $0) }

        try source.start()
        source.deliver([32_767, 0, -32_768])

        #expect(received.count == 3)
        #expect(abs(received[0] - 1.0) < 0.001)
        #expect(received[1] == 0)
        #expect(abs(received[2] - (-1.0)) < 0.001)
    }

    @Test("未启动时不转发")
    func ignoresSamplesBeforeStart() {
        // 蓝牙桥的音频可能在会话开始前就到达（例如上一轮的尾包），
        // 这些必须丢弃，否则会混进新会话的缓冲区
        let source = BluetoothRemoteSource()
        source.onFrame = { _ in Issue.record("不该转发") }

        source.deliver([1, 2, 3])
    }

    @Test("stop 后触发结束回调")
    func stopReportsFinish() throws {
        let source = BluetoothRemoteSource()
        var stopped = false
        source.onStop = { _ in stopped = true }

        try source.start()
        source.stop()

        #expect(stopped)
    }

    @Test("stop 之后不再转发")
    func ignoresSamplesAfterStop() throws {
        let source = BluetoothRemoteSource()
        try source.start()
        source.stop()

        source.onFrame = { _ in Issue.record("不该转发") }
        source.deliver([1, 2, 3])
    }

    @Test("断连时以错误结束")
    func disconnectReportsError() throws {
        let source = BluetoothRemoteSource()
        var reported: Error?
        source.onStop = { reported = $0 }

        try source.start()
        source.reportDisconnected()

        #expect(reported != nil)
    }

    @Test("未启动时的断连不产生回调")
    func disconnectWhenIdleIsNoop() {
        let source = BluetoothRemoteSource()
        source.onStop = { _ in Issue.record("不该回调") }

        source.reportDisconnected()
    }
}
