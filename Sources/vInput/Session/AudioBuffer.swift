import Foundation

/// 累积单声道浮点音频样本。取值范围 -1…1。
///
/// 这是纯值类型，不持有任何系统资源，因此可以自由复制与测试。
struct AudioBuffer {
    let sampleRate: Double
    private(set) var samples: [Float] = []

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    /// 已累积音频的时长（秒）。
    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    mutating func append(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
    }

    /// 返回最近 `lastSeconds` 秒的样本。样本不足则返回全部。
    func window(lastSeconds: TimeInterval) -> [Float] {
        let wanted = Int(lastSeconds * sampleRate)
        guard wanted > 0, samples.count > wanted else { return samples }
        return Array(samples.suffix(wanted))
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}
