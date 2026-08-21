import Testing

@testable import vInput

/// 「下载好的模型什么时候真的换上去」。
///
/// 这几条钉的是一个**只在真实时序下才出现**的洞：向导关掉之后下载还在跑
/// （不取消是有意的），于是它可能在用户正说着话的那一刻完成——而那一刻
/// `selectModel` 会被 `canSwitchModel` 挡下来，原先挡下来就没有下文了。
@MainActor
struct ModelAdoptionQueueTests {
    /// 没在录音：立刻换，且不留欠账。
    @Test func adoptsImmediatelyWhenIdle() {
        let queue = ModelAdoptionQueue()
        let now = queue.request(folder: "/models/turbo", canSwitchNow: true)
        #expect(now == "/models/turbo")
        #expect(queue.pendingFolder == nil)
    }

    /// 正录着：这次不换，但**必须记住**。
    ///
    /// 变异「把 `pendingFolder = folder` 那行删掉」由这一条抓：删掉之后
    /// 返回值仍然是 nil（行为看着一样），而那 1.5GB 从此没人再提起。
    @Test func remembersWhenBusy() {
        let queue = ModelAdoptionQueue()
        let now = queue.request(folder: "/models/turbo", canSwitchNow: false)
        #expect(now == nil)
        #expect(queue.pendingFolder == "/models/turbo")
    }

    /// 会话结束时补上。
    @Test func resumesAfterSessionEnds() {
        let queue = ModelAdoptionQueue()
        _ = queue.request(folder: "/models/turbo", canSwitchNow: false)
        let resumed = queue.resume(canSwitchNow: true)
        #expect(resumed == "/models/turbo")
        #expect(queue.pendingFolder == nil)
    }

    /// **补一次就够，不许补第二次。**
    ///
    /// 换模型本身是异步的，会话还会一次次回到 idle。不清账的话，用户在那之后
    /// 手动选了别的模型，下一次听写结束就被这条补挂悄悄改了回去——
    /// 那是「我明明选了 large-v3，它自己变回 turbo」这种查不出来的怪事。
    @Test func resumesOnlyOnce() {
        let queue = ModelAdoptionQueue()
        _ = queue.request(folder: "/models/turbo", canSwitchNow: false)
        _ = queue.resume(canSwitchNow: true)
        let second = queue.resume(canSwitchNow: true)
        #expect(second == nil)
    }

    /// 没有欠账时补挂是空操作——不能凭空换一次模型。
    @Test func resumeWithNothingPendingDoesNothing() {
        let queue = ModelAdoptionQueue()
        #expect(queue.resume(canSwitchNow: true) == nil)
    }

    /// 回到 idle ≠ 能换模型：`loadingModelName` 非空时照样不能换
    /// （`canSwitchModel` 是两个条件的与）。这时欠账要**原样留着**，
    /// 下一次再问；清掉的话那次下载就白费了。
    @Test func keepsPendingWhenStillNotSwitchable() {
        let queue = ModelAdoptionQueue()
        _ = queue.request(folder: "/models/turbo", canSwitchNow: false)
        #expect(queue.resume(canSwitchNow: false) == nil)
        #expect(queue.pendingFolder == "/models/turbo")
        #expect(queue.resume(canSwitchNow: true) == "/models/turbo")
    }

    /// 后一次请求覆盖前一次：等着的那个目录永远是最新下好的那个。
    @Test func laterRequestWins() {
        let queue = ModelAdoptionQueue()
        _ = queue.request(folder: "/models/old", canSwitchNow: false)
        _ = queue.request(folder: "/models/new", canSwitchNow: false)
        #expect(queue.pendingFolder == "/models/new")
    }
}
