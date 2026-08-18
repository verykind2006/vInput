import Testing
@testable import vInput

/// M6 ⑤：说中文时 Whisper 输出半角标点，句号却是全角 `。`。
///
/// **难点全在中英混排**——`用 Claude Code 部署到 AWS,先跑 npm install`
/// 里那个逗号该转全角，而英文短语内部的逗号该保持半角。判据取「离标点最近
/// 的那个实字符是不是中文语境」，与 `CorrectionGate.joiningLatinWords`
/// 处理拉丁词边界是同一种做法：在原始字符串上看邻居，不做整段语言判定。
///
/// 2026-08-17 用户把范围从「只有逗号」扩到「中文语境下的标点全部全角」。
/// 落地时分成两类，判据不同：
/// - `, ? ! : ;` 沿用上面那条邻居规则；
/// - `( )` **成对判断**，邻居规则在括号上必然误伤——`函数 foo(x) 的返回值`
///   里左括号前邻是拉丁、右括号后邻是中文，邻居规则会判成该转，但那是代码。
@Suite("中文语境的半角标点")
struct PunctuationWidthTests {

    // MARK: - 逗号：该转的

    @Test("两侧都是汉字时转全角")
    func convertsBetweenChinese() {
        #expect(TranscriptCleaner.clean("我在想,有没有可能") == "我在想，有没有可能")
    }

    @Test("中英混排：英文词收尾、中文起头的那个逗号要转")
    func convertsAfterLatinBeforeChinese() {
        #expect(
            TranscriptCleaner.clean("用 Claude Code 部署到 AWS,先跑 npm install")
                == "用 Claude Code 部署到 AWS，先跑 npm install"
        )
    }

    @Test("中英混排：中文收尾、英文起头的那个逗号也要转")
    func convertsAfterChineseBeforeLatin() {
        #expect(TranscriptCleaner.clean("先装好依赖,npm install 就够了")
                == "先装好依赖，npm install 就够了")
    }

    @Test("一句话里多个逗号各判各的")
    func judgesEachCommaIndependently() {
        #expect(
            TranscriptCleaner.clean("先跑 npm run build, npm run test,然后再部署")
                == "先跑 npm run build, npm run test，然后再部署"
        )
    }

    @Test("逗号在末尾时看前面那个字")
    func usesPrecedingCharacterAtEnd() {
        #expect(TranscriptCleaner.clean("他说,") == "他说，")
    }

    @Test("紧邻中文标点也算中文语境，哪怕另一侧是拉丁词")
    func treatsChinesePunctuationAsContext() {
        // 左边只有一个中文右引号，右边是纯拉丁词——判据是「最近的实字符」，
        // 不是「两侧都得是汉字」。
        #expect(TranscriptCleaner.clean("「好的」,OK") == "「好的」，OK")
    }

    @Test("转换时吃掉紧邻的空格：全角逗号自带间距")
    func swallowsAdjacentSpaces() {
        #expect(TranscriptCleaner.clean("部署到 AWS, 先跑 npm install")
                == "部署到 AWS，先跑 npm install")
        #expect(TranscriptCleaner.clean("部署到 AWS ,先跑 npm install")
                == "部署到 AWS，先跑 npm install")
    }

    // MARK: - 逗号：不该转的

    @Test("纯英文句子里的逗号保持半角")
    func keepsCommaInEnglishSentence() {
        #expect(TranscriptCleaner.clean("Run npm install, then npm test")
                == "Run npm install, then npm test")
    }

    @Test("千分位不能动——这是最贵的一个误伤")
    func keepsThousandSeparator() {
        #expect(TranscriptCleaner.clean("这轮融资 1,200,000 美元") == "这轮融资 1,200,000 美元")
    }

    @Test("中文句子里被引号括起来的英文，内部逗号保持半角")
    func keepsCommaInsideQuotedEnglish() {
        #expect(TranscriptCleaner.clean("他说 \"Hello, world\" 然后走了")
                == "他说 \"Hello, world\" 然后走了")
    }

    @Test("代码里的参数列表保持半角")
    func keepsCommaInCode() {
        #expect(TranscriptCleaner.clean("写成 foo(a, b) 就行") == "写成 foo(a, b) 就行")
    }

    @Test("已经是全角的逗号不动")
    func leavesFullWidthAlone() {
        #expect(TranscriptCleaner.clean("我在想，有没有可能") == "我在想，有没有可能")
    }

    @Test("没有半角标点的文本原样返回")
    func leavesTextWithoutHalfWidth() {
        #expect(TranscriptCleaner.clean("今天天气不错。") == "今天天气不错。")
    }

    // MARK: - 问号叹号冒号分号：与逗号同一条邻居规则

    @Test("问号：真实日志里就是这一句，句号全角而问号半角")
    func convertsQuestionMark() {
        // 用户 2026-08-17 的日志原文。
        #expect(TranscriptCleaner.clean("把 M8 的分场景优化改成?")
                == "把 M8 的分场景优化改成？")
    }

    @Test("叹号")
    func convertsExclamationMark() {
        #expect(TranscriptCleaner.clean("太好了!这就上线") == "太好了！这就上线")
    }

    @Test("冒号")
    func convertsColon() {
        #expect(TranscriptCleaner.clean("注意:这里有坑") == "注意：这里有坑")
    }

    @Test("分号")
    func convertsSemicolon() {
        #expect(TranscriptCleaner.clean("先装依赖;再跑测试") == "先装依赖；再跑测试")
    }

    @Test("连着写的标点一起转，不能一半一半")
    func convertsPunctuationRuns() {
        // 叹号紧挨着问号，找邻居时要跨过它继续往外看：只看紧邻的实字符
        // 会把叹号判成「不在中文语境」，转出「真的吗？!」这种一半一半的结果。
        #expect(TranscriptCleaner.clean("真的吗?!") == "真的吗？！")
        #expect(TranscriptCleaner.clean("太好了!!!") == "太好了！！！")
    }

    @Test("跨过标点找邻居不会把英文里的连写标点带进来")
    func punctuationRunsStayLatin() {
        #expect(TranscriptCleaner.clean("Really?!") == "Really?!")
    }

    @Test("英文语境里这四个一律不动")
    func keepsLatinContextMarks() {
        #expect(TranscriptCleaner.clean("Is it ready? Not yet!") == "Is it ready? Not yet!")
        #expect(TranscriptCleaner.clean("写成 int x = 1; y = 2;") == "写成 int x = 1; y = 2;")
    }

    @Test("已知误伤：代码片段末尾的分号后面跟中文时会被转全角")
    func knownFalsePositiveOnTrailingSemicolon() {
        // 记在这里，因为它是**邻居规则本身的代价**，不是漏写的分支：
        // 这一句里分号左边是 `2`、右边是「然」，与
        // `部署到 AWS,先跑 npm install`（该转）的形状一模一样，
        // 只看邻居分不开两者。括号能靠成对判断绕开同类问题，
        // `; : ? !` 没有「对」可配，绕不开。
        //
        // 之所以接受：口述中文时说出 `;` 的场景极少（Whisper 从语音里
        // 产出分号本身就罕见），而误伤只发生在「代码片段紧接中文」这
        // 一种排布上。若日后真出问题，先收窄的应是分号与冒号。
        #expect(TranscriptCleaner.clean("写成 int x = 1; 然后编译")
                == "写成 int x = 1；然后编译")
    }

    /// 独立验收 2026-08-17 找到的同族误伤，**概率比分号那条高一个数量级**：
    /// 口述 commit message、口述日志前缀是日常动作。
    ///
    /// 同样不改规则。冒号左边那个拉丁词是不是标识符，邻居规则看不出来，
    /// 而 `注意: 这里有坑`、`第 5 章: 数据结构` 转全角是对的——一刀切改会
    /// 把对的一起改坏。钉在这里是为了让它是**已知**的，别以后被当成新
    /// bug 重查一遍。
    @Test("已知误伤：口述 commit 前缀的冒号会被转全角")
    func knownFalsePositiveOnCommitPrefix() {
        #expect(TranscriptCleaner.clean("fix: 修复了那个问题")
                == "fix：修复了那个问题")
        // 对照：这两条转全角是对的，不能为了上面那条把它们一起改坏。
        #expect(TranscriptCleaner.clean("注意: 这里有坑") == "注意：这里有坑")
        #expect(TranscriptCleaner.clean("第 5 章: 数据结构") == "第 5 章：数据结构")
    }

    /// 独立验收同批报的几条，逐一实测后**只有一条成立**。写在一起是为了
    /// 让「查过、不成立」和「没查」区分得开。
    @Test("口述代码场景：括号内部逗号确实会被转")
    func knownFalsePositiveInsideCallParentheses() {
        // 成立。括号本身因内部有拉丁而保持半角，但内部的逗号左右分别是
        // `d` 与「名」——邻居规则里「任一侧是中文语境」成立，于是转了。
        #expect(TranscriptCleaner.clean("写成 setName(id, 名字) 就行")
                == "写成 setName(id，名字) 就行")
    }

    /// **这条独立验收报了但没复现**，记下来免得以后有人照着报告去「修」
    /// 一个不存在的问题。
    ///
    /// 报告说 `见 [点这里](地址)` 的圆括号会被转成全角导致 Markdown 失效。
    /// 实测不会：括号那条三条件规则的第三条要求「外部至少一处是中文语境」，
    /// 而这里左边紧邻是 `]`、右边是字符串结尾，两处都不是。
    @Test("Markdown 链接的圆括号不会被转——独立验收报的这条没复现")
    func markdownLinkParenthesesAreUntouched() {
        #expect(TranscriptCleaner.clean("见 [点这里](地址)") == "见 [点这里](地址)")
    }

    @Test("URL 里的问号冒号不动——两侧都是拉丁")
    func keepsURLPunctuation() {
        #expect(TranscriptCleaner.clean("打开 https://x.com/s?q=vinput 看看")
                == "打开 https://x.com/s?q=vinput 看看")
    }

    @Test("时间与比例里的冒号不动——两侧都是数字")
    func keepsNumericColon() {
        #expect(TranscriptCleaner.clean("下午 3:30 开会") == "下午 3:30 开会")
        #expect(TranscriptCleaner.clean("画面是 16:9 的") == "画面是 16:9 的")
    }

    @Test("句号不在改写范围内——`...` 会被逐点转成「。。。」")
    func leavesPeriodAlone() {
        // 2026-08-17 用户点名的是逗号问号叹号冒号分号五个，句号不在其列，
        // 而且句号确实不该顺手加进来：省略号的三个点各自都满足邻居规则。
        #expect(TranscriptCleaner.clean("今天天气不错.") == "今天天气不错.")
        #expect(TranscriptCleaner.clean("我想想...") == "我想想...")
    }

    // MARK: - 括号：成对判断

    @Test("代码里的括号保持半角——邻居规则在这里必然判错")
    func keepsCodeBrackets() {
        // 左括号前邻是拉丁 `foo`、右括号后邻是汉字「的」，按邻居规则右括号
        // 该转、左括号不该转，一对括号被拆成一全一半。所以括号必须成对判。
        #expect(TranscriptCleaner.clean("函数 foo(x) 的返回值") == "函数 foo(x) 的返回值")
    }

    @Test("内容是中文、外部也在中文语境里，才转全角")
    func convertsChineseBrackets() {
        #expect(TranscriptCleaner.clean("他说(其实我不同意)然后走了")
                == "他说（其实我不同意）然后走了")
    }

    @Test("括号内允许数字，只要没有拉丁字母")
    func allowsDigitsInsideBrackets() {
        // `（见 2.1 节）` 是正常的中文行文，一刀切禁掉数字会漏掉一大类。
        #expect(TranscriptCleaner.clean("详情见附录(第 3 节)那里")
                == "详情见附录（第 3 节）那里")
    }

    @Test("紧贴着拉丁/数字的括号一律不转——那是函数调用与路径的形状")
    func keepsBracketsGluedToLatin() {
        // `/usr/local/bin(不要改)`：括号里是中文，但左括号紧贴路径末尾的
        // `n`，中间连个空格都没有。这种粘连形状在代码与路径里是常态，
        // 在中文行文里几乎不出现（中文会写「路径是 /usr/local/bin（不要改）」
        // 或至少留个空格）。判成代码、保持半角。
        #expect(TranscriptCleaner.clean("路径是 /usr/local/bin(不要改)")
                == "路径是 /usr/local/bin(不要改)")
        #expect(TranscriptCleaner.clean("调用 render(这里传中文) 就行")
                == "调用 render(这里传中文) 就行")
    }

    @Test("不成对的括号一律不转")
    func keepsUnpairedBrackets() {
        // 只有一半时无从知道括号的范围，也就无从判断「里面是什么」。
        // Whisper 漏掉一半括号是常事，宁可不动。
        #expect(TranscriptCleaner.clean("他说(其实我不同意然后走了")
                == "他说(其实我不同意然后走了")
        #expect(TranscriptCleaner.clean("他说其实我不同意)然后走了")
                == "他说其实我不同意)然后走了")
    }

    @Test("括号外部不在中文语境时不转")
    func keepsBracketsOutsideChineseContext() {
        // 整行只有括号内是中文，外面没有任何中文邻居——多半是被截断的
        // 代码片段或注释，不是中文行文。
        #expect(TranscriptCleaner.clean("(不要改)") == "(不要改)")
    }

    @Test("括号内是拉丁词时不转，哪怕整句是中文")
    func keepsLatinInsideBrackets() {
        #expect(TranscriptCleaner.clean("这个模型(large-v3-turbo)最快")
                == "这个模型(large-v3-turbo)最快")
    }

    @Test("空括号不转")
    func keepsEmptyBrackets() {
        #expect(TranscriptCleaner.clean("写成 foo() 就行") == "写成 foo() 就行")
    }

    @Test("嵌套括号逐对判断")
    func convertsNestedBrackets() {
        #expect(TranscriptCleaner.clean("他说(其实(真的)不同意)然后走了")
                == "他说（其实（真的）不同意）然后走了")
    }

    @Test("括号转换时同样吃掉紧邻空格")
    func swallowsSpacesAroundBrackets() {
        #expect(TranscriptCleaner.clean("这个功能 (还没做完) 明天再说")
                == "这个功能（还没做完）明天再说")
    }

    // MARK: - 度量

    @Test("中文语境里的半角标点被数出来")
    func countsHalfWidthInChinese() {
        #expect(BenchMetrics.halfWidthPunctuationInChinese("我在想,有没有可能?") == 2)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("太好了!注意:这里有坑;真的") == 3)
    }

    @Test("全角标点不计入")
    func fullWidthNotCounted() {
        #expect(BenchMetrics.halfWidthPunctuationInChinese("我在想，有没有可能？") == 0)
    }

    @Test("英文语境里的半角标点不计入——它们本来就该是半角")
    func latinContextNotCounted() {
        #expect(BenchMetrics.halfWidthPunctuationInChinese("Run npm install, then test.") == 0)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("这轮融资 1,200,000 美元") == 0)
        #expect(BenchMetrics.halfWidthPunctuationInChinese("版本是 3.14 那个") == 0)
    }

    /// **下面四条替换了原来钉住「转换器与度量是同一把尺子」的那批测试。**
    ///
    /// 那个契约本身是错的：度量跑在转换之后，共用同一个函数就意味着凡是
    /// 该函数认得出的半角标点都已经被它转掉了，**指标必然读 0**。基准集
    /// 26 条全是「半角=0」，那不是测量结果，是恒等式。独立验收 2026-08-17
    /// 指出这是 M5「把答案抄进被测系统」那个错误的同形缩小版。
    ///
    /// 新判据独立实现，且**严格更窄**：只认「半角 `,;:?!` 两侧紧邻都是
    /// 汉字」。窄的代价是括号、句号、单侧中文都不再计入；换来的是**凡它
    /// 报出来的都无疑是错的**，读 0 因此是有意义的。

    @Test("度量不再共用转换器的判据——括号与句号都不计入")
    func metricNoLongerSharesConverterRule() {
        // 括号：转换器会转（成对 + 内部中文无拉丁 + 外部无粘连），
        // 但度量不管——括号不在「两侧都是汉字夹一个半角标点」这个形状里。
        #expect(BenchMetrics.halfWidthPunctuationInChinese("他说(其实我不同意)然后走了") == 0)
        // 句号：转换器刻意不改（`我想想...` 会变成「。。。」），
        // 度量也不再数它。想量句号得另立指标，混进来只会让这一格恒不为零。
        #expect(BenchMetrics.halfWidthPunctuationInChinese("今天天气不错.") == 0)
    }

    /// 这条是新判据存在的理由：**它必须能独立发现转换器漏转。**
    ///
    /// 旧判据做不到——转换器漏掉的东西，共用函数的度量同样看不见。
    @Test("转换器漏转时度量能独立发现")
    func metricCatchesConverterMisses() {
        let raw = "你好,世界。对吗?注意:这里有坑;太好了!"
        #expect(BenchMetrics.halfWidthPunctuationInChinese(raw) == 5)
        // 转换器正常工作时清零——这不是恒等式，是两条独立规则的交集为空。
        #expect(BenchMetrics.halfWidthPunctuationInChinese(TranscriptCleaner.clean(raw)) == 0)
    }

    /// 新判据比转换器窄，窄的部分要写明白，免得以后有人以为是漏了。
    @Test("单侧中文不计入——那是转换器的地盘，不是度量的")
    func metricStaysNarrowerThanConverter() {
        // 转换器会把这个逗号转成全角（它的规则是「任一侧是中文语境」），
        // 度量不报——两侧不都是汉字，就有正当解释的余地。
        #expect(BenchMetrics.halfWidthPunctuationInChinese("部署到 AWS,先跑 npm install") == 0)
        #expect(TranscriptCleaner.clean("部署到 AWS,先跑 npm install") == "部署到 AWS，先跑 npm install")
    }

    @Test("这个指标正是基准集从第一天起就屏蔽掉的那个不匹配")
    func exposesTheBlindSpot() {
        let reference = "今天下午三点开会，讨论一下发版计划。"
        let hypothesis = "今天下午三点开会,讨论一下发版计划。"

        // CER 刻意排除标点，两者一模一样——这就是它藏了这么久的原因。
        #expect(BenchMetrics.characterErrorRate(reference: reference, hypothesis: hypothesis) == 0)
        // punctuationCount 只数个数，也一模一样。
        #expect(BenchMetrics.punctuationCount(reference) == BenchMetrics.punctuationCount(hypothesis))
        // 只有新指标看得见。
        #expect(BenchMetrics.halfWidthPunctuationInChinese(reference) == 0)
        #expect(BenchMetrics.halfWidthPunctuationInChinese(hypothesis) == 1)
    }
}
