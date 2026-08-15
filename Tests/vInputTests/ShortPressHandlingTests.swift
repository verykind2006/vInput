import Testing
@testable import vInput

@Suite("错误是否该展示")
struct UserFacingErrorTests {
    @Test("音频过短不展示——按一下就松是常见误触")
    func shortAudioIsSilent() {
        #expect(!AppModel.isUserFacing(TranscribeError.audioTooShort))
    }

    @Test("空转写结果要展示——用户得知道自己说的话没落地")
    func emptyResultIsShown() {
        // 与「音频过短」不同：那是按一下就松的误触，用户知道自己没说话；
        // 而空结果意味着录了至少 0.3 秒还是一个字都没解出来，
        // 静默关掉 HUD 会让用户以为注入成功了。
        #expect(AppModel.isUserFacing(TranscribeError.emptyResult))
    }

    @Test("转写引擎失败要展示")
    func engineFailureIsShown() {
        #expect(AppModel.isUserFacing(TranscribeError.engineFailed("boom")))
    }

    @Test("模型未就绪要展示")
    func modelNotReadyIsShown() {
        #expect(AppModel.isUserFacing(TranscribeError.modelNotReady))
    }

    @Test("注入失败要展示")
    func injectionFailureIsShown() {
        #expect(AppModel.isUserFacing(TextSinkError.accessibilityDenied))
    }

    @Test("目标应用改变要展示——用户需要知道文字去哪了")
    func targetChangeIsShown() {
        #expect(AppModel.isUserFacing(
            TextSinkError.targetApplicationChanged(expected: "a", actual: "b")
        ))
    }

    @Test("音频源故障要展示")
    func audioSourceFailureIsShown() {
        #expect(AppModel.isUserFacing(AudioSourceError.microphonePermissionDenied))
    }
}
