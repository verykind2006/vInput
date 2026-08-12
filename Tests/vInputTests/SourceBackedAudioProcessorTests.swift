import Foundation
import Testing
@testable import vInput

@Suite("SourceBackedAudioProcessor")
struct SourceBackedAudioProcessorTests {
    @Test("新建时没有样本")
    func startsEmpty() {
        let processor = SourceBackedAudioProcessor()
        #expect(processor.audioSamples.isEmpty)
        #expect(processor.relativeEnergy.isEmpty)
    }

    @Test("推入的样本会被累积")
    func appendsSamples() {
        let processor = SourceBackedAudioProcessor()

        processor.append([0.1, 0.2, 0.3])
        processor.append([0.4, 0.5])

        #expect(Array(processor.audioSamples) == [0.1, 0.2, 0.3, 0.4, 0.5])
    }

    @Test("每推入一批就产出一个能量值")
    func producesOneEnergyPerChunk() {
        let processor = SourceBackedAudioProcessor()

        processor.append([0.5, 0.5, 0.5])
        processor.append([0.1, 0.1, 0.1])

        #expect(processor.relativeEnergy.count == 2)
    }

    @Test("能量值落在 0…1 区间")
    func energyIsNormalized() {
        let processor = SourceBackedAudioProcessor()

        processor.append(Array(repeating: 0.9, count: 1_600))
        processor.append(Array(repeating: 0.0, count: 1_600))

        #expect(processor.relativeEnergy.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("响亮的音频能量高于静音")
    func loudExceedsSilence() {
        let processor = SourceBackedAudioProcessor()

        processor.append(Array(repeating: 0.8, count: 1_600))   // 响
        processor.append(Array(repeating: 0.0, count: 1_600))   // 静音

        let energy = processor.relativeEnergy
        #expect(energy[0] > energy[1])
    }

    @Test("空批次不产生能量值也不改变样本")
    func emptyChunkIsIgnored() {
        let processor = SourceBackedAudioProcessor()
        processor.append([])

        #expect(processor.audioSamples.isEmpty)
        #expect(processor.relativeEnergy.isEmpty)
    }

    @Test("reset 清空样本与能量")
    func resetClearsEverything() {
        let processor = SourceBackedAudioProcessor()
        processor.append([0.1, 0.2])

        processor.reset()

        #expect(processor.audioSamples.isEmpty)
        #expect(processor.relativeEnergy.isEmpty)
    }

    @Test("purgeAudioSamples 只保留末尾指定数量")
    func purgeKeepsTail() {
        let processor = SourceBackedAudioProcessor()
        processor.append(Array(0..<100).map(Float.init))

        processor.purgeAudioSamples(keepingLast: 10)

        #expect(processor.audioSamples.count == 10)
        #expect(processor.audioSamples.first == 90)
    }

    @Test("生命周期方法不抛错且不采集音频")
    func lifecycleMethodsAreInert() throws {
        let processor = SourceBackedAudioProcessor()

        // 音频由 AudioSource 驱动，这些方法在本实现里近乎空操作。
        // 只要求它们不崩溃、不启动任何采集。
        try processor.startRecordingLive(inputDeviceID: nil, callback: nil)
        processor.pauseRecording()
        try processor.resumeRecordingLive(inputDeviceID: nil, callback: nil)
        processor.stopRecording()

        #expect(processor.audioSamples.isEmpty)
    }
}
