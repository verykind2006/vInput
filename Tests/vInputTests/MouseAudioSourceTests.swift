import Foundation
import Testing

@testable import vInput

@Suite("MouseAudioSource")
@MainActor
struct MouseAudioSourceTests {

    /// 真实的 SBC 码流夹具（16 kHz / 16 blocks / MONO / Loudness / bitpool 12，
    /// 与鼠标固件现在发的配置完全相同）。切成 128 字节一包，
    /// 正是 BLE 通知的形状。
    private func packets(limit: Int = .max) throws -> [Data] {
        let stream = try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12")
        var result: [Data] = []
        var cursor = 0
        while cursor + MouseVoiceProtocol.audioPacketLength <= stream.count,
              result.count < limit {
            result.append(stream.subdata(
                in: cursor..<(cursor + MouseVoiceProtocol.audioPacketLength)
            ))
            cursor += MouseVoiceProtocol.audioPacketLength
        }
        return result
    }

    @Test("一个 128 字节包解出 4 帧 × 128 样本")
    func decodesOnePacket() throws {
        let source = MouseAudioSource()
        var received: [Float] = []
        source.onFrame = { received.append(contentsOf: $0) }

        try source.start()
        source.deliver(try packets(limit: 1)[0])

        // 每包 4 个 32 字节 SBC 帧，每帧 16 blocks × 8 subbands = 128 样本
        #expect(received.count == 512)
        #expect(source.decodedSampleCount == 512)
        #expect(source.decodeFailureCount == 0)
    }

    @Test("输出全部落在 -1…1")
    func outputInRange() throws {
        let source = MouseAudioSource()
        var received: [Float] = []
        source.onFrame = { received.append(contentsOf: $0) }

        // 夹具是 1376 字节 = 43 帧，切出 10 个整包
        let all = try packets()
        try source.start()
        for packet in all { source.deliver(packet) }

        #expect(all.count == 10)
        #expect(received.count == all.count * 512)
        #expect(received.allSatisfy { $0 >= -1 && $0 <= 1 })
    }

    /// 与直接整段解码逐样本相同——按包喂入不改变结果。
    /// 这条是「BLE 分包」这件事本身的判据。
    @Test("按包喂入与整段解码逐样本相同")
    func chunkedEqualsWhole() throws {
        let stream = try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12")
        let whole = try SBCDecoder().decode(stream)

        let source = MouseAudioSource()
        var received: [Float] = []
        source.onFrame = { received.append(contentsOf: $0) }
        try source.start()
        for packet in try packets() { source.deliver(packet) }

        // 夹具长度未必是 128 的整数倍，只比对喂进去的那部分
        #expect(received.count <= whole.count)
        #expect(received.count > 0)
        for index in 0..<received.count {
            #expect(received[index] == AudioFormat.normalize([whole[index]])[0])
        }
    }

    @Test("未启动时不转发")
    func ignoresPacketsBeforeStart() throws {
        let source = MouseAudioSource()
        source.onFrame = { _ in Issue.record("不该转发") }
        source.deliver(try packets(limit: 1)[0])
        #expect(source.decodedSampleCount == 0)
    }

    @Test("stop 之后不再转发并触发结束回调")
    func stopReportsFinishAndSilences() throws {
        let source = MouseAudioSource()
        var stopped = false
        source.onStop = { _ in stopped = true }

        try source.start()
        source.stop()
        #expect(stopped)

        source.onFrame = { _ in Issue.record("不该转发") }
        source.deliver(try packets(limit: 1)[0])
    }

    /// 上一轮结尾可能留着半帧（会话被时长上限截断、或丢包），
    /// 带进新会话会让开头那几帧错位解成噪音。
    @Test("重新 start 会清掉上一轮残留的半帧")
    func restartResetsDecoder() throws {
        let source = MouseAudioSource()
        let all = try packets(limit: 2)

        try source.start()
        // 只喂半个包，解码器里留下 64 字节
        source.deliver(all[0].prefix(64))
        source.stop()

        var received: [Float] = []
        source.onFrame = { received.append(contentsOf: $0) }
        try source.start()
        source.deliver(all[0])

        // 若残留没清掉，第一个包会被当成「上一轮的后半 + 这一轮的前 64 字节」
        #expect(received.count == 512)
    }

    /// 坏帧之后不猜着重新同步：往前找下一个 0x9C 看着更健壮，实际是猜，
    /// 0x9C 也可能只是音频数据里的一个字节，跟着它走会解出一段能播放的
    /// 噪音——而噪音会被转写成一句像样的中文。
    @Test("坏包被丢掉，后续包照常解")
    func badPacketIsDroppedAndStreamRecovers() throws {
        let source = MouseAudioSource()
        var received: [Float] = []
        source.onFrame = { received.append(contentsOf: $0) }

        try source.start()
        source.deliver(Data(repeating: 0x00, count: 128))   // syncword 不对
        #expect(source.decodeFailureCount == 1)
        #expect(received.isEmpty)

        source.deliver(try packets(limit: 1)[0])
        #expect(received.count == 512)
        #expect(source.decodeFailureCount == 1)
    }

    @Test("断连时以错误结束")
    func disconnectReportsError() throws {
        let source = MouseAudioSource()
        var reported: Error?
        source.onStop = { reported = $0 }

        try source.start()
        source.reportDisconnected()

        #expect(reported != nil)
    }

    @Test("未启动时的断连不产生回调")
    func disconnectWhenIdleIsNoop() {
        let source = MouseAudioSource()
        source.onStop = { _ in Issue.record("不该回调") }
        source.reportDisconnected()
    }
}

@Suite("MouseCoordinator")
@MainActor
struct MouseCoordinatorTests {

    private final class Recorder {
        var actions: [String] = []
    }

    private func makeCoordinator() -> (MouseCoordinator, Recorder, MouseAudioSource) {
        let recorder = Recorder()
        let source = MouseAudioSource()
        let coordinator = MouseCoordinator(source: source)
        coordinator.onStartSession = { recorder.actions.append("start") }
        coordinator.onFinishSession = { recorder.actions.append("finish") }
        return (coordinator, recorder, source)
    }

    @Test("语音键按下请求开始会话")
    func startsSession() {
        let (coordinator, recorder, _) = makeCoordinator()
        coordinator.handleVoiceStart()
        #expect(recorder.actions == ["start"])
    }

    @Test("语音键松开请求结束会话")
    func finishesSession() {
        let (coordinator, recorder, _) = makeCoordinator()
        coordinator.handleVoiceStart()
        coordinator.handleVoiceStop()
        #expect(recorder.actions == ["start", "finish"])
    }

    @Test("重复的开始被忽略")
    func ignoresRepeatedStart() {
        let (coordinator, recorder, _) = makeCoordinator()
        coordinator.handleVoiceStart()
        coordinator.handleVoiceStart()
        #expect(recorder.actions == ["start"])
    }

    @Test("未开始时的结束被忽略")
    func ignoresStopWithoutStart() {
        let (coordinator, recorder, _) = makeCoordinator()
        coordinator.handleVoiceStop()
        #expect(recorder.actions.isEmpty)
    }

    /// 断连之后才到达的结束码不该再触发一次转写。
    @Test("断连后到达的结束被忽略")
    func ignoresStopAfterDisconnect() {
        let (coordinator, recorder, _) = makeCoordinator()
        coordinator.handleVoiceStart()
        coordinator.handleDisconnected()
        coordinator.handleVoiceStop()
        #expect(recorder.actions == ["start"])
    }

    @Test("音频包转给音频源")
    func forwardsAudio() throws {
        let (coordinator, _, source) = makeCoordinator()
        var received = 0
        source.onFrame = { received += $0.count }

        try source.start()
        let stream = try SBCFixtures.stream("dev-16k-16blk-8sb-loudness-bp12")
        coordinator.handleAudio(stream.subdata(in: 0..<128))

        #expect(received == 512)
    }
}
