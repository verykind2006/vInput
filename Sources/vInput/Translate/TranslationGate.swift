import Foundation

/// 闸门为什么拦下这次翻译。写进日志，也决定 HUD 说什么。
///
/// **`truncated` 与 `tooShort` 是两种不同的失败形态，刻意分开两格。**
/// 「没说完」是推理被砍断（撞 `maxTokens`、被取消），译出来的那半截本身
/// 是合法的目标语言文本；「整段太短」是译文短得不像这句话的译文，成因
/// 更杂（模型只回了一句摘要、只吐了个标点）。合成一格的话 HUD 只能说
/// 一句含糊的「译文有问题」，而这两件事对用户的含义不同——前者再说一遍
/// 大概率就好了，后者多半是这句话本身让模型犯难。
enum TranslationRejection: Equatable, Sendable {
    case residualHan(count: Int)
    case chinesePunctuation(count: Int)
    /// 译文疑似没说完。判据见 `TruncationSignal`。
    case truncated
    /// 译文整段太短。`ratio` 是实测到的长度比，进日志用。
    case tooShort(ratio: Double)
    /// 目标是中文而译文一个汉字都没有——多半整段没译。X→中文方向的
    /// 弱闸门，未实测（设计定稿「不装作验过」一节）。
    case noHan

    /// HUD 上显示的一行字。
    ///
    /// **五种成因都说了「已退回原文」**：闸门拦下之后注入的是原文，而用户
    /// 选了别的语言——屏幕上出现他说的原话本身就是要解释的那件事，
    /// 不说清楚的话他会以为翻译开关没生效。源不再恒为中文（英文输入下
    /// 说「已退回中文原文」是错话），所以只说「原文」。
    /// 与 `CorrectionAnnotation.hudLabel` 同一个取向——不许静默。
    var hudLabel: String {
        switch self {
        case .residualHan: "译文里还有中文，已退回原文"
        case .chinesePunctuation: "译文里还有中文标点，已退回原文"
        case .truncated: "译文没说完，已退回原文"
        case .tooShort: "译文太短，已退回原文"
        case .noHan: "译文不像中文，已退回原文"
        }
    }
}

enum TranslationVerdict: Equatable, Sendable {
    case pass
    case reject(TranslationRejection)
}

/// 译文的机械检查。**这一层唯一的机械保障。**
///
/// 与 `CorrectionGate` 同一个定位：只保证「明显错了的挡下来」，
/// 不保证「过了的就是对的」。**故意不做语义正确性检查**——那需要另一个
/// 模型，而「用更强的模型检查更强的模型」是无穷回退。
///
/// 它位于 `Translator` 协议之外：本地与云端两种实现共用同一道闸门，
/// 写进任一实现内部就会有两种松紧。
///
/// ## 已知会漏的那一类，是算过账之后决定放过的
///
/// （下面这篇账只覆盖**拉丁目标分支**；X→中文那条弱闸门未实测，
/// 它的边界写在 `TranslationRejection.noHan` 的注释里。）
///
/// 最难办的是**半截译文**：Task 8 实测（8/8）超时取消对 MLX 推理基本无效，
/// `translate` 会**成功返回**半截译文；而半截译文往往是完全合法的目标语言
/// 文本——「我想订三张下周五的机票」译到一半是 "I'd like to book three
/// tickets"，残留汉字 0、中文标点 0、术语保留 100%，前两条判据一条都碰不到。
///
/// 兜住它的是 `truncated`。但**越接近「快译完才被砍」的半截，两条信号都
/// 越无力**：砍点正好落在句中某个句号后面时，译文以句号收尾，
/// `TruncationSignal` 沉默；而只少了最后一小段时长度比还在正常区间，
/// `tooShort` 也沉默。
///
/// **这是有意接受的残留风险，不是没想到。** 第 0 步实测拿那 86 条 4B 正常
/// 译文做过模拟：把译文砍在第一个句末标点之后（`TruncationSignal` 对这一类
/// 0/23 全漏），长度比阈值取 1.0 / 1.1 / 1.2 拦下的都是同样 2 条，要多拦
/// 就得抬到 1.3（4 条）、1.5（8 条）——而 1.3 已经开始误杀实测里最短的
/// 那条正常译文。**不要为了堵这个漏去抬阈值**：误杀的恰好是用户的主场景
/// （技术短句，见 `defaultMinimumLengthRatio`），而漏网的代价只是一条没译完
/// 的句子被注入，用户当场看得见。
struct TranslationGate: Sendable {
    /// 长度比的默认下限。**低于它就认为译文短得不像这句话的译文。**
    ///
    /// ### 这个数是量出来的，不是拍的
    ///
    /// 数据来源：`Bench/reports/m8-step0/` 的三份 qwen3-4b 报告
    /// （`03a-4b-manifest.txt` + `03b-4b-digits.txt` + `04c-4b-de-baseline.txt`，
    /// english-language-name 变体，maxTokens=512），共 **86 条正常译文**。
    /// 该目录已 gitignore，报告在开发机上。分布：
    /// **最小 1.2040816326530612 / P5 1.97 / 中位 2.92 / P95 4.25 / 最大 6.16**。
    ///
    /// ### 为什么不是 1.2
    ///
    /// 计划原本写 1.2，理由是「实测最小 1.20、零误杀」。**但那个 1.20 是
    /// 报告里四舍五入到两位小数的数，真值是 1.2040816…（= 59/49）**，
    /// 而 1.2 × 49 = 58.8——那条译文正好 59 个显著字符，**余量是 0 个字符**：
    /// 模型少吐一个字母（58/49 = 1.1837）就被误杀。阈值恰好压在样本最小值上
    /// 是教科书式的边界 bug，本仓库 M8 Task 2 刚在同一个坑里栽过。
    ///
    /// ### 1.1 的余量与代价
    ///
    /// 余量 0.104（实测最小值的 8.6%）；换算到那条样本上是 5 个显著字符
    /// （1.1 × 49 = 53.9，译文得掉到 53 个字符才会被拦）。
    ///
    /// 代价是 0：在长度比唯一起作用的那一类失败上（砍在句末标点之后，
    /// `TruncationSignal` 全漏），1.0 / 1.1 / 1.2 拦下的是同样 2 条；
    /// 在「按字符砍一半」「留 70%」两类上 `TruncationSignal` 86 条全拦，
    /// 长度比的额外贡献本来就是 0。**降下来一条都没少拦。**
    ///
    /// ### 误杀的是谁——别往上抬
    ///
    /// 分布最左端那两条都是同一句技术短句
    /// （`tech-hold-02`：「你把 useMemo 换成 useCallback，然后在 Zustand 的
    /// store 里加个 selector。」→ en 1.204 / es 1.429）。它长度比天然就低，
    /// 因为一半内容是原样保留的代码标识符——**保留标识符是正确行为**，
    /// 而这正是本工具的主场景。阈值抬到 1.3 误杀 1 条，1.5 误杀 2 条。
    static let defaultMinimumLengthRatio = 1.1

    let minimumLengthRatio: Double

    /// 构造参数保留是为了让测试能构造极端阈值（验「阈值真的被读了」），
    /// 生产调用方不该每次拍一个数——默认值有实测支撑，见上。
    init(minimumLengthRatio: Double = TranslationGate.defaultMinimumLengthRatio) {
        self.minimumLengthRatio = minimumLengthRatio
    }

    func check(
        source: String, translation: String,
        from sourceLanguage: Language, to target: Language
    ) -> TranslationVerdict {
        // X→中文：判据只有「须含汉字」与截断。不查拉丁残留（中文合法保留
        // 英文术语正是本项目的规则），不查长度比（未标定）。
        //
        // **必须排在下面的 usesLatinScript guard 之前**：`.chinese` 的
        // `usesLatinScript` 是 false，落到那条 guard 会被静默 pass——
        // 整个弱闸门等于没写。
        if target == .chinese {
            if TranslationMetrics.residualHanCount(translation) == 0 {
                return .reject(.noHan)
            }
            if !TruncationSignal.looksTruncated(source),
                TruncationSignal.looksTruncated(translation)
            {
                return .reject(.truncated)
            }
            return .pass
        }

        // **查 usesLatinScript 而不是「非中文」。**
        //
        // 两者今天等价，但语义不同：下面几条判据**只对拉丁字母书写系统
        // 成立**——日文本来就用汉字，拿「残留汉字」去判日语译文，正常的
        // 译文会被全部拦下。写成 `target != .chinese` 的话，将来加日语时
        // Language 那几处 switch 会逼人把 usesLatinScript 填成
        // false（护栏有效），**而闸门仍会把这套判据套上去**——那个护栏就
        // 白设了。Task 1 的评审指出了这一点。
        guard target.usesLatinScript else { return .pass }

        let han = TranslationMetrics.residualHanCount(translation)
        if han > 0 { return .reject(.residualHan(count: han)) }

        let punct = TranslationMetrics.residualChinesePunctuationCount(translation)
        if punct > 0 { return .reject(.chinesePunctuation(count: punct)) }

        // **主信号，排在长度比前面。** 第 0 步 306 次 MLX 推理（失败 0 次）里
        // 它只误报 1 次——`Bench/reports/m8-step0/` 七份报告的「疑似截断」那一行，
        // 16 个语言块写 0 条、1 个写 1 条，「总计 N 次推理」加起来是 306。
        // 比长度比可靠得多（长度比要拦住半截译文就得抬到会误杀主场景的高度）。
        //
        // （计划正文里写的是 292，与报告对不上；这里用从报告里数出来的数。
        // 误报 1 次这个结论两边一致。）
        //
        // **前置条件「原文自己得以句末标点收尾」是必要的，不是保险丝。**
        // 判据的完整说法是「原文有句末标点而译文没有」：用户松手早了、
        // 半句话就停了转写的话，原文本身没有句末标点，译文照实译出来也不会有
        // ——那是正常输出，不能算截断。少了这半个条件，这类输入会被全数拦下。
        //
        // 这半个条件在第 0 步的数据上**不改变任何结论**：基准集 26 条标准
        // 文本与 141 条真实 Whisper 转写全部以句末标点收尾（实地扫过），
        // 所以「只误报 1 次」这个实测值原样成立。它防的是实测素材里没有、
        // 真机上一定会有的那一类。
        if !TruncationSignal.looksTruncated(source),
            TruncationSignal.looksTruncated(translation)
        {
            return .reject(.truncated)
        }

        // 「译文里根本没有内容」的兜底，对任何源语言启用。**这条不是长度比**
        // ——不需要标定：零个显著字符在任何语言对上都不是合法译文。少了它，
        // 非中文源 + 原文无句末标点（用户松手早）时，空译文（或只剩空白/
        // 标点的退化译文）会三条判据全部沉默、被静默注入：残留汉字 0、
        // 截断判据因前置条件不成立而跳过、长度比未标定不启用。
        // 尺子与 `TranslationMetrics.lengthRatio` 的分子是同一把
        // （`significantCharacters`）。中文目标分支的同类情形已由 `noHan`
        // 兜住，所以只需要在拉丁分支加。
        if BenchMetrics.significantCharacters(translation).isEmpty {
            return .reject(.tooShort(ratio: 0))
        }

        // 辅助信号，排最后：它拦得住的多半上面已经拦了，留着是为了兜住
        // 「译文以句末标点收尾但短得离谱」那一类。
        //
        // 长度比阈值 1.1 是 zh→拉丁 的 86 条语料标定的（见 defaultMinimumLengthRatio
        // 注释）；拉丁→拉丁的自然长度比就在 1.0 附近，沿用会误杀正常译文。
        // 未标定的判据不启用——这是「不装作验过」，不是漏。
        if sourceLanguage == .chinese {
            let ratio = TranslationMetrics.lengthRatio(source: source, translation: translation)
            if ratio < minimumLengthRatio { return .reject(.tooShort(ratio: ratio)) }
        }
        return .pass
    }
}
