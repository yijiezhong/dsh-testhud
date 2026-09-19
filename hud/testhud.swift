// DSH 自动测试的屏幕浮层：把"正在测什么、期待什么、实际什么、跑到哪一步、跑了多久，
// 以及**现在能不能动鼠标键盘**"直接画在**被测界面之上**。
//
// 用法：testhud <进度文件.json> [锚点] [顶部让出高度]
//   锚点：auto（默认，自动挑最不挡的一个角）| top-left | top-right
//   顶部让出高度：两个角再往下让这么多点，用来躲开浏览器自己的标签栏/地址栏/收藏栏（默认 150）
//
// 版面按 CRAP 定规矩（Contrast / Repetition / Alignment / Proximity）：
//   · **Contrast**：彩色只留给"状态"这一个语义 —— 顶部控制权色带 + 步骤行首那一个字符。
//     其余层次全靠**两级灰**（浅面板 0.06 / 0.08，深面板 white / 0.90）+ **字重四档**（heavy / bold / semibold / regular），
//     不靠字号（用户要求全部文字同一个字号）。
//   · **Repetition**：所有内容贴同一条左边界（inset）；间距只有三个值 —— 组间 14、步骤间 10、行内 2~4。
//   · **Alignment**：控制权色带通栏，文字用 headIndent 回到内容左边界；步骤的"期待/实际"用真正的
//     headIndent 缩进（不是空格 —— 比例字体下空格根本对不齐）。
//   · **Proximity**：头部（标题/对象/计时）一组、步骤一组、结论一组，组内紧、组间松。
//   · **位置**：只在**上边两个角**里挑 —— 用系统窗口列表算两个候选与最前窗口的遮挡面积，取小的那个；
//     底部两个角已取消：面板高度随步骤增长、高度变化时顶边不动，贴底时下半截会被屏幕下缘切掉。
//   · **大小**：随内容增减，到上限（屏幕可见高度的 62%）为止。
//   · **滚动**：只有步骤区滚动，**头部固定**；新步骤进来自动滚到底。
//   · **透明度**：面板底的不透明度**由环境反解**（见 Theme），下限 0.50（用户定的取舍）；
//     方向与背景同向 —— 浅背景配更亮的面板 + 深字，深背景配更暗的面板 + 白字。
//   · **层级**：`panel.level = .screenSaver` —— 压在所有窗口之上。
//   · **字号**：全部 18（`Look.base`），唯一可调的地方。
//
// 进度文件 schema 见插件 README（`lib/hud.js` 与 `bin/testhud.js` 都写它）。
import AppKit
import Foundation
import ScreenCaptureKit
import CoreImage

// MARK: - 进度模型（与 testhud.sh 写出的 JSON 一一对应）

struct Step: Decodable {
    var name: String
    var expect: String?
    var actual: String?
    var state: String?      // run | pass | fail | info
}

struct Progress: Decodable {
    var title: String
    var target: String?
    var status: String?     // running | done | failed
    var startedAt: Double?
    var steps: [Step]?
    var note: String?
}

let progressPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : NSHomeDirectory() + "/.dsh/test-progress.json"
let anchorArg = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "auto"
/// 顶部让出的高度（点）：浮层顶边从这里往下开始，用来躲开浏览器自己的标签栏/地址栏/收藏栏。
/// 由插件/CLI 传进来（默认 150），0 表示像以前一样只留 14 点边距。
let topInsetArg = CommandLine.arguments.count > 3 ? (Double(CommandLine.arguments[3]) ?? 0) : 0

// MARK: - 尺寸与样式

private enum Look {
    /// 唯一字号（pt）——**全部文字都是这个号**，层次只靠灰度与字重。
    /// 浏览器里 DSH 的正文字号是 `--dsh-content-font-size`（默认 14px），macOS 的 point 与浏览器
    /// CSS px 同尺度；浮层是半透明底上的浅色字，同字号看着比浏览器里的黑字小，所以取 18。
    static let base: CGFloat = 18

    static let width: CGFloat = 740             // 面板宽
    static let inset: CGFloat = 16              // 面板内边距，同时是内容左边界
    static let screenMargin: CGFloat = 14       // 离屏幕边缘
    static let maxHeightRatio: CGFloat = 0.62   // 最多占屏幕可见高度的 62%
    static let cornerRadius: CGFloat = 14       // 比原来更圆一点，边缘不那么"硬"
    static let bandPad: CGFloat = 10            // 控制权色带里文字的上下留白
    /// 屏幕底部这条不让压：状态栏 / Dock / 播放条。
    static let bottomInset: CGFloat = 44
    /// 左右不让面板贴边：躲开侧边栏与滚动条。
    static let sideInset: CGFloat = 28

    /// 间距只有三个值，全局复用。
    static let groupGap: CGFloat = 14           // 组与组之间（头部 / 步骤 / 结论）
    static let stepGap: CGFloat = 10            // 步骤与步骤之间
    static let lineGap: CGFloat = 3             // 行内行距
    static let stepIndent: CGFloat = 28         // 步骤第二行（期待/实际）的缩进 = 行首 mark + 序号宽

    // 同一字号（base），四档字重；层次另一半来自灰度。
    static let alertFont = NSFont.systemFont(ofSize: base, weight: .heavy)      // 控制权色带
    static let titleFont = NSFont.systemFont(ofSize: base, weight: .bold)       // 标题
    static let stepFont = NSFont.systemFont(ofSize: base, weight: .semibold)    // 步骤名 / 结论
    static let bodyFont = NSFont.systemFont(ofSize: base, weight: .regular)     // 期待 / 实际 / 测试对象
    /// 计时用等宽数字：秒数跳动时不会左右抖。
    static let metaFont = NSFont.monospacedDigitSystemFont(ofSize: base, weight: .regular)

    /// 统一段落样式工厂：间距与缩进都从这里出，保证全篇一个节奏。
    static func para(before: CGFloat = 0, after: CGFloat = 0, indent: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineGap
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.headIndent = indent
        p.firstLineHeadIndent = indent
        return p
    }
}


/// 一整套视觉参数。**这里每一个值都由 backdrop 一个数算出来**（见 `Theme.palette(for:)`）——
/// 面板底、它的不透明度、两级文字、色带的底色与字色，没有一个是写死的。
struct Palette {
    let panelFill: NSColor
    let panelBorder: NSColor
    let primary: NSColor
    let secondary: NSColor
    let alertRunBg: NSColor
    let alertDoneBg: NSColor
    let alertRunFg: NSColor
    let alertDoneFg: NSColor
    let stateOk: NSColor
    let stateBad: NSColor
    let stateRun: NSColor
    let stateInfo: NSColor
}

/// 变色龙：**颜色和透明度全部由"面板将要盖住的那块区域有多亮"算出来**，没有第二套预设。
///
/// 两条要求互相拉扯，而且是**物理上**的：面板里的字要读得出来，被挡住的东西也要看得见 ——
/// 但包住面板文字的像素，同时就是遮住后方内容的像素，是同一批像素。所以这从来不是审美选择，
/// 只能在**空间上**、或者**在不透明度上**分配。
///
/// 两条路都走过，都留下了实测结论：
///   · **逐行底板**（文字处够实、其余处全透）：读起来连贯，但把行距一起盖住，后方那一整片就没了 ——
///     用户否掉（"块级底板的被遮挡区域后方的文字完全看不到了"），底板整个删除。
///   · **面板底尽量透**（0.10 / 0.20 / 0.35 都试过）：密集文字背景上各会漏 1~3 行背景文字透上来，
///     而且漏的总是**刚打出来的内容** —— SCK 采样有 100~300ms 延迟，底图追不上正在被打印的字。
///
/// 结论是"接近全透"在高对比底层上不成立：面板压在铺满整屏的黑底白字（~15:1）上时，
/// 要真挡住得实到 0.8 以上，那就等于不透明了。于是取 **0.50** 作下限（用户拍板）：
/// 普通背景上面板文字早已远超 AAA，被遮挡区域仍看得出明暗与形状。
///
/// 底图（面板位置的一份模糊快照）负责把残余的背景文字化成柔和的光斑 —— 它是这 0.50 之外的另一半手段。
enum Theme {
    /// 面板底的目标亮度：让面板**离开中灰**。浅面板要够亮、深面板要够暗，
    /// 否则不管配深字还是白字都压不住（实测：终端里密布文字时平均亮度被抬到 0.45，
    /// 固定不透明度只把面板提到 0.64，深字只有 4.0:1）。
    static let lightPanelTarget: CGFloat = 0.72
    static let darkPanelTarget: CGFloat = 0.25
    // 文字的目标对比度。**文字的亮度不再是写死的常量**（曾经是 0.06 / 0.08 / white / 0.90），
    // 而是拿面板底的实际亮度**反解**出来的 —— 于是"两级灰"在任何背景上都还是两级，
    // 对比度也稳定在目标附近，不再随背景漂移（踩过：中灰背景上固定 0.06 只有 7.3:1）。
    // 目标留了余量：纸面 7:1 的东西在屏幕上量出来只有 6.6~6.8（中文笔画细、抗锯齿抬高实测亮度）。
    static let primaryContrast: CGFloat = 9      // 标题 / 步骤名 / 结论
    static let secondaryContrast: CGFloat = 7    // 期待 / 实际 / 元信息
    /// 二级文字相对一级保留的对比度比例。**只在被物理夹紧时起作用**：
    /// 暗面板上白字已经贴到 1.0，若两级各自解各自的目标，就会双双变成纯白、层次消失 ——
    /// 层次是这块面板唯一的层级手段，宁可让二级的对比度低一点也要留住它。
    static let secondaryRatio: CGFloat = 0.91
    /// 环境饱和度到这个值以上才算"有颜色"，文字才跟着上色。
    /// 不能定太高：面板覆盖的是一整块区域，**平均**会把颜色稀释掉 —— 实测一屏彩色文字
    /// （红黄绿青蓝紫块铺满）平均下来只有 0.20，0.22 的门槛反而让它落回黑白。
    /// 也不能太低：中性里带一点点色的界面（浅灰蓝工具栏之类）会误触发。
    /// 0.15 是这两头之间的值；真正中性的画面离得很远（实测白页 0.001），不会误判。
    static let minTintSat: CGFloat = 0.15
    /// 上色时为色相让出的亮度（0~1）。色相不改善任何对比度数字，所以只让很小一档：
    /// 实测在 panelLum 0.15 的底上，白字从 5.24:1 退到 4.95:1，仍高过大字 AA 的 4.5。
    static let tintRelax: CGFloat = 0.05
    /// 解色带明度时假定的"字有多黑"与目标 —— 这一层只决定**色带该多亮**，不决定最终字色。
    static let bannerSeedText: CGFloat = 0.06
    static let bannerSeedContrast: CGFloat = 4.5
    /// 色带底与面板底的**最小对比度**：带子必须"一眼看到"，不能只剩一层色相差。
    /// 1.25 是"能分辨"，1.5 是"一眼看到"（用户选的 1.5）。
    /// 这条约束独立于"带上的字够不够对比" —— 那是两回事，字够亮不等于带子看得见。
    static let bannerVsPanel: CGFloat = 1.5
    /// 色带的不透明度。**2026-09-18 由 0.55 提到 0.75**（用户在这轮明确选了"折中"档）：
    /// 色相/饱和度/亮度都钉到极值后，色带呈现出来仍是粉红（饱和度只有 0.47），
    /// 瓶颈就是这层不透明度 —— 0.55 时鲜红被面板底稀释成 `RGB(246,141,131)`，
    /// 0.75 时是 `RGB(254,63,63)`（实测）。代价是压在色带下的那几行字从"看得清"退到"隐约可见"，
    /// 这是用户当场权衡后接受的；再往上是 0.85（更鲜，但色带下的字基本被盖住）。
    static let bannerAlpha: CGFloat = 0.75

    /// 一种灰（默认不透明）。
    /// **必须用 sRGB 构造**：`calibratedWhite` 会被色彩空间转换改掉 —— 实测构造 0.032 读回 0.026、
    /// 构造 0.06 读回 0.073，而整套对比度都是按"构造值 = 实际亮度"反解的，用 calibrated 会让
    /// 实际对比度对不上目标（实测 secondary 只有 6.26:1，而目标是 7）。
    static func grey(_ v: CGFloat, alpha: CGFloat = 1) -> NSColor {
        let x = min(1, max(0, v))
        return NSColor(srgbRed: x, green: x, blue: x, alpha: alpha)
    }

    /// WCAG 对比度（与观测工具同一个公式）。
    static func contrast(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// "亮度为 `under` 的底上，要够 `contrast`，文字该落在什么亮度" —— `plateLum` 的反函数。
    /// **先比黑与白各自能给出的对比度，谁高用谁**，不按"面板亮还是暗"机械选：
    /// panelLum ≈ 0.19 这种地方黑字（4.8:1）其实优于白字（4.38:1），机械选会白让一档。
    /// 物理上做不到就贴到 0 或 1 —— 于是实际对比度低于目标：那个底给不出更多了。
    static func textLum(over under: CGFloat, contrast target: CGFloat) -> CGFloat {
        let lighter = contrast(under, 1) >= contrast(under, 0)
        let v = lighter ? (under + 0.05) * target - 0.05
                        : (under + 0.05) / target - 0.05
        return min(1, max(0, v))
    }

    /// 环境有颜色时，文字该取什么色相 —— **它的互补色**。
    /// 环境接近中性（饱和度低于 `minTintSat`）时返回 nil，文字就用黑白灰：中性最干净，
    /// 而且**黑与白是亮度区间的两个端点**，任何有彩色在同一亮度下都不可能比它们更极端。
    static func tintHue(for color: NSColor) -> CGFloat? {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        (color.usingColorSpace(.deviceRGB) ?? color).getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        guard s >= minTintSat else { return nil }
        return (h + 0.5).truncatingRemainder(dividingBy: 1)
    }

    /// 在"亮度恰好 = lum"的前提下，取该色相能给到的最饱和颜色。
    /// 亮度是 WCAG 对比度的唯一决定因素，所以换色相**不会动任何对比度数字** ——
    /// 它买到的不是"更清楚"，而是"面板文字与背景文字不同色"。
    /// HSB 下亮度 = `b × (1 − (1 − base) × s)`（`base` 是该色相满饱和满明度时的加权亮度），
    /// 解出满足该亮度的最大饱和度；解不出来（这个亮度该色相够不着）就退回灰。
    static func tinted(lum: CGFloat, hue: CGFloat) -> NSColor {
        let base = luminance(NSColor(deviceHue: hue, saturation: 1, brightness: 1, alpha: 1))
        guard base > 0.01, base < 0.99 else { return grey(lum) }
        let room = max(0, min(1, (1 - lum) / (1 - base)))
        let bright = min(1, lum / max(0.01, 1 - (1 - base) * room))
        // 用 **deviceHue** 构造：上面那条公式在 device 空间下实测精确成立
        // （预测 0.2220 / 实测 0.2221），换成 calibratedHue 会偏 12%（0.2525 对 0.2828）。
        return NSColor(deviceHue: hue, saturation: room, brightness: bright, alpha: 1)
    }

    /// 文字色 = 反解出来的亮度 + （环境有颜色时）它的互补色相。
    ///
    /// 有两条路会走到"上色"，它们正是"黑白都不合适"的两种情况：
    ///   · 环境本身有色（`tint` 非 nil）—— 背景文字与面板文字往往同色，亮度对比已经拉满，
    ///     能再把两者分开的只剩下色相；
    ///   · 亮度被夹到了极端（0 或 1）—— 说明这个底连目标对比度都给不出，黑白已经是它的极限。
    ///     而极端亮度下 `tinted` 只能给出中性色（饱和度解出来是 0），等于没上色 ——
    ///     所以让出一小档亮度去换色相。
    /// 让出的对比度很小（`tintRelax`），买到的不是"更清楚"，是"和背景不同色"。
    static func textColor(over under: CGFloat, contrast target: CGFloat, tint: CGFloat?) -> NSColor {
        let lum = textLum(over: under, contrast: target)
        guard let hue = tint else { return grey(lum) }
        if lum >= 0.999 { return tinted(lum: 1 - tintRelax, hue: hue) }
        if lum <= 0.001 { return tinted(lum: tintRelax, hue: hue) }
        return tinted(lum: lum, hue: hue)
    }

    /// 色带的一层。**除了色相，其余全部由环境反解**：
    ///   · **色相**按状态固定（黄＝别动、绿＝可以接手）—— 这是这块浮层存在的首要理由，
    ///     语义不能漂，所以它是这层里唯一留下来的常量；
    ///   · **明度**反解到"带上的字够对比度"；受色相与 alpha 限制时达不到目标，
    ///     所以**带上的字也跟着反解** —— 用带底**实际**能达到的亮度去算字色，把差额补回来；
    ///   · **饱和度**由环境饱和度决定（见下）；
    ///   · **字色的色相**跟着环境走（与面板文字同一套规则）。
    /// 不透明度钉在 0.55 是"能看到后面的文字"那条要求定的，不参与反解。
    ///
    /// ⚠️ **2026-09-18 起没人调它了。** 用户要求色带改成"固定鲜红 / 鲜绿、饱和度高、亮一些"，
    /// 那与这里逐项反解的做法直接冲突，于是换成下面的 `vividBanner`（三项全钉死）。
    /// 这份实现**故意留着**：它是"环境自适应"路线的完整版，想回退就改 `palette()` 里那两行调用。
    static func banner(hue: CGFloat, baseSaturation: CGFloat, alpha: CGFloat,
                       panelLum: CGFloat, envSat: CGFloat) -> (fill: NSColor, text: NSColor) {
        // 饱和度：环境本身有色时降一点 —— 一条满饱和的带子压在彩色背景上，两种颜色会互相打架
        // （那是视觉噪音，不是信息）；环境中性时保持满饱和，那时它得独自承担全部辨识度。
        let sat = max(0.25, baseSaturation * (1 - 0.5 * min(1, envSat)))
        // 给定的色相与饱和度下，"明度 = 1" 时这层颜色本身的亮度。
        // HSB 下亮度 = b × (1 − (1 − base) × s)，在 device 空间实测精确成立，所以可以反解。
        let scale = 1 - (1 - luminance(NSColor(deviceHue: hue, saturation: 1, brightness: 1, alpha: 1))) * sat
        let floor = plateLum(text: bannerSeedText, contrast: bannerSeedContrast, darker: false)
        // 带底**呈现**出来要够 `floor`；`needed` 是它在 alpha 混合之前应有的亮度。
        let needed = (floor - (1 - alpha) * panelLum) / max(0.05, alpha)
        var brightness = min(1.0, max(0.30, needed / max(0.05, scale)))
        // 呈现亮度得按**实际的色相与饱和度**算，不能再拿明度近似 —— 饱和度一降，同样的明度更亮。
        var shown = alpha * brightness * scale + (1 - alpha) * panelLum

        // 第二条约束：**带子自己得看得出来**。字够对比只是个必要条件 —— 面板底恰好落在
        // "带上的字所需那个亮度"附近时，带底与面板底几乎同亮，色带就只剩一层色相差
        // （中灰场景曾算出 1.01:1，那时带子等于不存在，只剩一条说不清的色带）。
        // 不满足就从面板底往外推：先往上推（带子更亮），推不动（会超过 1）再往下推。
        if contrast(shown, panelLum) < bannerVsPanel {
            let up = bannerVsPanel * (panelLum + 0.05) - 0.05
            let down = (panelLum + 0.05) / bannerVsPanel - 0.05
            let target = up <= 0.98 ? max(shown, up) : min(shown, down)
            let b = min(1.0, max(0.30, (target - (1 - alpha) * panelLum) / max(0.05, alpha * scale)))
            let pushed = alpha * b * scale + (1 - alpha) * panelLum
            // **只在真的推上去了才采用**。明度被夹紧时（两个方向都推不动）这一推可能反而
            // 把带子推向面板底 —— 实测模拟 3:1 时对比度从 1.65 掉到 0.62，比不改还差。
            // 约束的语义是"至少 1.5"，做不到时保持原样，而不是把情况弄糟。
            if contrast(pushed, panelLum) > contrast(shown, panelLum) {
                brightness = b
                shown = pushed
            }
        }
        // 带上的字**直接用黑或白**，不做"解到刚好"的反解，也不上色。
        // 带底的亮度本来就是被有意推到"够亮"的，所以纯黑在这里永远可行、而且对比更高 ——
        // 实测带底呈现 0.462 时，纯黑给 10.2:1，而"解到刚好"只有 6.5:1，白白亏掉 3.7:1。
        // 把面板文字那套"解到刚好目标"搬到这里是错的：面板底可能落在任何亮度，带底不会。
        let ink = contrast(shown, 0) >= contrast(shown, 1) ? grey(0) : NSColor.white
        return (NSColor(deviceHue: hue, saturation: sat, brightness: brightness, alpha: alpha), ink)
    }

    /// 用户点名的"鲜"色（2026-09-18）：**色相、饱和度、亮度三个全部钉死**，不参与环境反解。
    ///
    /// 这是对上面那条"变色龙"路线的**有意推翻**，不是它没算对 —— 用户要的是
    /// "鲜红和绿、饱和度高、亮一些"，而"按背景反解"这件事本身就与"固定鲜"矛盾：
    /// 背景有色时它会把饱和度降下来（见 `sat` 那行），背景亮时它会把明度压下来。
    /// 所以这里 `saturation / brightness` 直接取 1.0 —— 这是该色相下能取到的最鲜最亮值，
    /// 再往上没有了（HSB 的上界），"更鲜"只能靠**改色相**或**提高不透明度**，不是调这两个数。
    ///
    /// **字色由调用方指定**（2026-09-18 用户定）：红带配白字、绿带配黑字，不再按对比度自动挑。
    /// 实测（截图采样，字 vs 带底）：白字对鲜红底 **2.35:1**、对鲜绿底 1.14:1；
    /// 黑字对鲜红底 8.93:1、对鲜绿底 18.36:1。所以：
    ///   · **绿带用黑** —— 又好看又清楚，18.36:1 远超 AAA；
    ///   · **红带用白** 是**审美优先**的选择：2.35:1 低于大字号 AA 的 3:1，全靠 heavy 字重与 18 pt
    ///     字号顶着看（这是用户看过实拍后定的，别当成 bug 去"修"）。
    static func vividBanner(hue: CGFloat, alpha: CGFloat,
                            ink: NSColor) -> (fill: NSColor, text: NSColor) {
        let solid = NSColor(deviceHue: hue, saturation: 1.0, brightness: 1.0, alpha: 1)
        return (solid.withAlphaComponent(alpha), ink)
    }

    static func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    /// 反解"要把这一层压/提到 `wanted` 亮度，它需要多不透明"：结果 = a×base + (1−a)×底下，解 a。
    /// 夹在 [0.30, 0.95] —— 下界保证这一层还看得见，上界保证它不变成死板的实心块。
    static func solveAlpha(over under: CGFloat, base: CGFloat, wanted: CGFloat) -> CGFloat {
        guard abs(base - under) > 0.01 else { return 0.75 }
        // 下限 0.50（用户定的取舍）：**"接近全透"在高对比底层上不成立**。
        // 面板压在终端那种铺满整屏的黑底白字上时，底图（模糊 + 压淡）压不平残余，
        // 下限放到 0.10 会让残余直接暴露、面板自己的文字掉到 2.2:1（实测）。
        // 而挡不住的原因不是"不够实" —— 底层是 ~15:1 的高对比内容，要完全挡住得实到 0.8 以上，
        // 那就等于不透明了。所以这里选 0.50：面板文字在普通背景上早已远超 AAA，
        // 被遮挡区域仍然看得出明暗与形状。
        return min(0.98, max(0.50, (wanted - under) / (base - under)))
    }

    /// "亮度 text 的文字要够 `contrast`，衬底该落在什么亮度"。
    /// `darker` 指衬底在文字的暗侧（白字配暗底）；否则在亮侧（深字配亮底）。
    static func plateLum(text: CGFloat, contrast: CGFloat, darker: Bool) -> CGFloat {
        darker ? (text + 0.05) / contrast - 0.05
               : (text + 0.05) * contrast - 0.05
    }

    static func palette(for backdrop: CGFloat, color: NSColor = .gray) -> Palette {
        // 关键在方向：面板与背景**同向**，不是相反 —— 浅背景配更亮的面板 + 深字，
        // 深背景配更暗的面板 + 白字。方向对了才轮到对比度；方向反了只能靠加不透明度去救，
        // 那正是"遮挡太重"的来源。
        let lightPanel = backdrop > 0.35
        let fillBase = lightPanel ? NSColor.white : grey(0.02)
        // 不透明度由"要把面板提到/压到目标的亮度"反解 —— 和配色一样是算出来的，不是常量。
        // 背景落在中灰时它提上去，把面板推离中灰；背景已经在两端时它落到 0.50 的下限（用户定的取舍）。
        let fillAlpha = solveAlpha(over: backdrop, base: luminance(fillBase),
                                   wanted: lightPanel ? lightPanelTarget : darkPanelTarget)

        let panelLum = fillAlpha * luminance(fillBase) + (1 - fillAlpha) * backdrop

        // 文字：亮度**由面板底反解**（不再是写死的 0.06 / white / 0.90），黑与白里谁给得多用谁；
        // 物理上解不出来就贴极端，实际对比度便低于目标 —— 那个底给不出更多了。
        // 颜色也跟着环境走：**背景明显有色时，文字取它的互补色** —— 亮度不变（对比度分毫不差），
        // 变的是色相，换来"面板文字与背景文字不同色"；背景中性时返回 nil，文字就是黑白灰。
        // 面板底本身也是反解出来的，于是面板上每一处都由 backdrop 和它的颜色决定，没有常量。
        let tint = tintHue(for: color)
        // 环境饱和度**不再参与配色**：它原先唯一的读者是色带的 `banner()`（环境有色时给色带降饱和，
        // 免得两种颜色打架）。色带改用固定鲜艳色之后这一项没有读者了，连 `envVal` 一起删掉。
        let primary = textColor(over: panelLum, contrast: primaryContrast, tint: tint)
        // 二级：先看一级**实际**拿到了多少对比度（可能已被夹紧），再按比例退一档 ——
        // 直接解 secondaryContrast 会在暗面板上撞到 1.0 的天花板，两级双双变纯白，层次就没了。
        let reachable = contrast(panelLum, luminance(primary))
        let secondary = textColor(over: panelLum,
                                  contrast: min(secondaryContrast, reachable * secondaryRatio), tint: tint)

        // ---- 色带：固定**鲜红 / 鲜绿**（用户 2026-09-18 要求）----
        // 这一改**有意推翻**了先前"只有色相是常量、饱和与明度全由环境反解"的变色龙路线
        // （`banner()` 那份实现仍在下面躺着，只是没人调它了：想回退就把这两行换回去）。
        // 之所以必须推翻，是因为"按背景反解"与用户要的"固定鲜"天然冲突 —— 背景有色它会降饱和、
        // 背景亮它会压明度；现在色相、饱和度、明度三项全部钉死，见 `vividBanner`。
        // 语义没变，只是换了颜色：**鲜红＝进行中、别动；鲜绿＝已结束、可以接手**。
        // 色相 0.00 是正红，1/3 是正绿（120°）。注意这一对恰好是红绿色盲最难分辨的组合，
        // 先前（琥珀 0.10 / 青绿 0.45）正是为避开它才拉开的；现在改用**明度差**兜底：
        // 两色的自身亮度是 0.21 与 0.72（差 3.4 倍），分不出色相时仍能靠明暗区分。
        // 字色按**状态**定（用户 2026-09-18 指定）：红带配白字、绿带配黑字。
        let (runBase, runFg) = vividBanner(hue: 0.00, alpha: bannerAlpha, ink: .white)
        let (doneBase, doneFg) = vividBanner(hue: 1.0 / 3.0, alpha: bannerAlpha, ink: grey(0))

        let stateOk = lightPanel ? NSColor(calibratedRed: 0.06, green: 0.54, blue: 0.24, alpha: 1)
                                 : NSColor(calibratedRed: 0.42, green: 0.90, blue: 0.52, alpha: 1)
        let stateBad = lightPanel ? NSColor(calibratedRed: 0.79, green: 0.16, blue: 0.13, alpha: 1)
                                  : NSColor(calibratedRed: 1.00, green: 0.52, blue: 0.44, alpha: 1)
        let stateRun = lightPanel ? NSColor(calibratedRed: 0.67, green: 0.40, blue: 0.00, alpha: 1)
                                  : NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.28, alpha: 1)
        let stateInfo = lightPanel ? NSColor(calibratedWhite: 0.42, alpha: 1)
                                   : NSColor(calibratedWhite: 0.60, alpha: 1)

        return Palette(
            panelFill: fillBase.withAlphaComponent(fillAlpha),
            panelBorder: (lightPanel ? NSColor.black : NSColor.white).withAlphaComponent(0.16),
            primary: primary,
            secondary: secondary,
            alertRunBg: runBase,
            alertDoneBg: doneBase,
            alertRunFg: runFg,
            alertDoneFg: doneFg,
            stateOk: stateOk, stateBad: stateBad, stateRun: stateRun, stateInfo: stateInfo)
    }
}

// MARK: - 浮层

final class HUD: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var blurView: NSImageView!           // 底层：后方内容的模糊快照
    private var containerView: NSView!           // 半透明面板色 + 全部内容
    private var alertBand: NSView!               // 顶部通栏色带（纯色块）
    private var alertField: NSTextField!         // 色带里的文字（在色带内垂直居中）
    private var headerField: NSTextField!        // 标题 / 测试对象 / 计时（固定不滚）
    private var stepsScroll: NSScrollView!
    private var stepsField: NSTextField!
    private var footerField: NSTextField!        // 结论（固定不滚）
    private var timer: Timer?
    private var themeTimer: Timer?
    private var doneSince: Date?
    private var lastFingerprint = ""
    /// 只反映"面板内容"的指纹：**不含计时行**（它每秒都变），用来判断该不该立刻重采底图。
    private var lastContentFingerprint = ""
    private var lastSampleAt: TimeInterval = 0
    private var placed = false
    /// 色带的拖拽把手（见 `DragHandle`）。它是**独立的一个小窗口** —— 面板本身必须整体保持
    /// 鼠标穿透，那种"只有色带能抓"的效果没法用一个窗口做到（`ignoresMouseEvents` 是窗口级的）。
    private var dragHandle: DragHandle!
    /// 色带左端那三个圆点的**命中区**（红关闭 / 黄折叠 / 绿缩放），住在把手窗口里。
    /// 它自己**不负责显示** —— 显示见 `bandDots`。
    private var lights: TrafficLights!
    /// 三个圆点的**显示**，画在主面板的色带里。
    ///
    /// 为什么不跟命中区合成同一个视图：把手窗口是一层**透明**的窗口，里面本来就没有画面 ——
    /// 它存在的唯一目的是接鼠标（主面板整体鼠标穿透）。所以让两边各司其职：显示画在主面板的
    /// 色带上，命中区留在必须能接鼠标的地方。
    ///
    /// 圆点必须用 `addSubview(positioned: .above)` 提到最上层：色带和几个文字字段都是后加进
    /// `containerView` 的，不这么做会被色带整个盖住（位置、颜色全对，就是看不见）。
    private var bandDots: [NSTextField] = []
    /// 黄点：折叠成只剩色带一条，再点一下原样回来。
    private var collapsed = false
    /// 绿点：放大到高度上限、把滚动区撑满，再点回到按内容算的高度。
    private var zoomed = false
    /// 当前用哪套配色。默认按"浅背景"起手，第一次采样之后就会纠正。
    /// 最后一次量到的背景亮度 —— 整套配色（颜色 + 四个透明度）都由它推出来。
    /// 最后一次量到的背景亮度。-1 是"还没量过"的哨兵 —— 用 0.95 之类当初始值会让第一次采样
    /// 因"变化不够 4%"被判为没变化，配色和底图就永远不应用（踩过）。
    private var backdrop: CGFloat = -1
    /// 上一次采样的面板尺寸。面板长高/缩短时底图必须重采 —— 只比亮度的话，同一背景下面板变高
    /// 不会触发重采，多出来的下半截就没有模糊覆盖（踩过）。
    private var sampledSize: NSSize = .zero
    /// 上一次量到的**明暗跨度**（p10~p90）。底图该压多平由它决定，所以它变了也要重采：
    /// 面板从纯色区域挪到明暗交界处时，backdrop 可能几乎没动，但文字失准的风险已经完全不同。
    private var spread: CGFloat = 0
    /// 上一次布局出来的面板高度。它一变就立刻重采底图 —— 否则要等下一个采样周期，
    /// 那段窗口里底图是旧尺寸的（被拉伸铺满，内容与当前区域不对应）。
    private var laidOutHeight: CGFloat = -1
    /// 面板覆盖区域的**平均颜色** —— 只用来判断"这里有没有颜色"，从而决定文字要不要上色。
    private var backdropColor: NSColor = .gray
    private var palette: Palette { Theme.palette(for: backdrop, color: backdropColor) }

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Look.width, height: 96),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        // 压在所有窗口之上：`.statusBar`(25) 只比普通窗口高，浏览器自己的面板/原生全屏窗口能盖住它
        // （用户反馈"浮层没在最前面"）。`.screenSaver`(1000) 是普通应用能拿到的最高层级。
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true             // 鼠标穿透：不挡操作
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 跟着所有空间、原生全屏也显示、不参与 Mission Control 排序
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let root = NSView(frame: NSRect(x: 0, y: 0, width: Look.width, height: 96))

        // 底层：面板位置的一份模糊快照。它让后方内容变成柔和的光斑 —— 仍看得出"下面有东西"，
        // 但不会与面板文字抢读（这一步替代了"给每行压一块不透明底板"）。
        blurView = NSImageView(frame: root.bounds)
        blurView.imageScaling = .scaleAxesIndependently
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = Look.cornerRadius
        blurView.layer?.masksToBounds = true
        root.addSubview(blurView)

        // 面板底：一层半透明色，颜色与不透明度都由 backdrop 反解（见 Theme）。
        // 它在底图之上 —— 底图把背景文字化成光斑，这一层再把残余压到"看得出形状、读不出内容"。
        containerView = NSView(frame: root.bounds)
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = palette.panelFill.cgColor
        containerView.layer?.cornerRadius = Look.cornerRadius
        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = palette.panelBorder.cgColor
        // 换前台应用时重新量一次：被测对象常常是跟着当前应用换的。
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshTheme() }
        // 让顶部色带被面板圆角裁掉，色带才能干干净净地通栏
        containerView.layer?.masksToBounds = true
        root.addSubview(containerView)

        alertBand = NSView(frame: .zero)
        alertBand.wantsLayer = true
        // 三个圆点画在面板顶层（和 `alertField` 同一层），位置由 `layout()` 摆，
        // 点击由把手窗口那份命中区负责。
        //
        // **用 NSTextField 画实心圆字符，不是图省事。** 一共换过三种画法 —— `draw(_:)`、
        // `NSView + wantsLayer + layer.backgroundColor`、直接往色带 layer 上加 `CALayer` ——
        // 三种都把 frame 和 layer 验证到了"完全正确"（日志里 bounds、frame、layer 非空、
        // 窗口 onscreen=1、在最前，全对），屏幕上就是什么都没有。而 `alertField` 这类文本控件
        // 在这个面板里始终显示正常，所以走这条已知能通的路。
        for color in TrafficLights.colors {
            let dot = NSTextField(labelWithString: "●")
            dot.font = .systemFont(ofSize: 12)
            dot.textColor = color
            dot.alignment = .center
            dot.isBordered = false
            dot.drawsBackground = false
            containerView.addSubview(dot)
            bandDots.append(dot)
        }
        alertField = makeField()
        headerField = makeField()
        footerField = makeField()
        stepsField = makeField()
        alertField.wantsLayer = true               // 色带画在它自己的 layer 上

        stepsScroll = NSScrollView(frame: .zero)
        stepsScroll.drawsBackground = false
        stepsScroll.hasVerticalScroller = true
        stepsScroll.autohidesScrollers = true
        stepsScroll.scrollerStyle = .overlay
        stepsScroll.documentView = stepsField

        containerView.addSubview(alertBand)
        containerView.addSubview(alertField)
        containerView.addSubview(headerField)
        containerView.addSubview(stepsScroll)
        containerView.addSubview(footerField)
        panel.contentView = root
        render()

        applyPalette()
        panel.orderFrontRegardless()

        // 色带的拖拽把手。几何由 `layout()` 每帧同步到色带矩形（色带藏起来时高度为 0，
        // 把手自然就抓不到东西），这里只负责把它建出来并压在最上面。
        dragHandle = DragHandle(contentRect: .zero,
                                styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false)
        dragHandle.isOpaque = false
        // 不是 `.clear`：完全透明的窗口在窗口服务器眼里"没有可点的东西"，鼠标事件会被跳过。
        // 0.01 的白肉眼看不出来（色带正好整条盖在上面），但让这个窗口在 hit-test 里是实心的。
        dragHandle.backgroundColor = NSColor(white: 1, alpha: 0.01)
        dragHandle.hasShadow = false
        dragHandle.level = .screenSaver
        dragHandle.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // 事件必须由一个 **view** 接住。NSWindow 本身也是 NSResponder，但鼠标事件是先发给
        // hit-tested 的那个 view，而 view 默认的 `mouseDown` 不会自动上溯到窗口 —— 把 `mouseDragged`
        // 写在窗口上，拖动会**毫无反应**：窗口建对了、位置分毫不差、辅助功能权限也有，就是拖不动。
        // （第一版就踩了这个，查窗口列表和权限花了一轮。）
        let grip = DragGrip(frame: NSRect(x: 0, y: 0, width: Look.width, height: 40))
        grip.host = panel
        // 整条链都上 layer：`dots` 是 layer 子视图，而"layer 子视图挂在普通父视图下"这种混合
        // 模式在某些情况下不渲染。与其赌它会自动向上冒泡，不如自己把链上每个视图都设成 layer-backed。
        grip.wantsLayer = true
        // 三个圆点画在把手里面：主面板整体鼠标穿透，整块浮层只有把手这一条能接鼠标。
        // 做成 `grip` 的子视图，点击天然被它们吃掉，不会漏给底下的拖拽逻辑。
        lights = TrafficLights(frame: grip.bounds)
        lights.wantsLayer = true
        lights.onLamp = { [weak self] lamp in self?.handle(lamp) }
        grip.addSubview(lights)
        // 尺寸交给 `DragGrip.layout()` 同步，不用 autoresizingMask —— 那是从 0×0 起步做等比缩放，
        // 0 乘任何数还是 0，圆点会一直看不见。
        grip.lights = lights
        dragHandle.contentView = grip
        dragHandle.orderFrontRegardless()
        // 显示之前先量一次：第一帧就是对的，不闪。
        refreshTheme()
        // 0.7 秒：底图是"面板下方此刻的样子"，周期越短越追得上正在变化的背景。
        themeTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            self?.refreshTheme()
        }
        RunLoop.current.add(themeTimer!, forMode: .common)

        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.render()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    private func makeField() -> NSTextField {
        let f = NSTextField(frame: .zero)
        f.isEditable = false
        f.isSelectable = false
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false        // 需要时在 applyPalette 里开（块级底板）
        f.lineBreakMode = .byWordWrapping
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        return f
    }

    // MARK: 渲染

    private func render() {
        guard let data = FileManager.default.contents(atPath: progressPath),
              let p = try? JSONDecoder().decode(Progress.self, from: data) else { return }

        let alert = composeAlert(p)
        let head = composeHeader(p)
        let body = composeSteps(p)
        let foot = composeFooter(p)
        let fingerprint = alert.string + head.string + body.string + foot.string
        let finished = (p.status == "done" || p.status == "failed")

        // 面板内容真变了（不是计时在跳）就立刻重采底图 —— 底图追不上变化是"背景文字透上来"的根因。
        // 0.5 秒的防抖：内容连续变化时不必每次都采。
        let content = contentFingerprint(p)
        if content != lastContentFingerprint {
            lastContentFingerprint = content
            let now = Date().timeIntervalSince1970
            if now - lastSampleAt > 0.5 {
                lastSampleAt = now
                refreshTheme()
            }
        }

        if fingerprint != lastFingerprint {
            lastFingerprint = fingerprint
            alertField.attributedStringValue = alert
            alertBand.layer?.backgroundColor = alertBackgroundNow().cgColor
            headerField.attributedStringValue = head
            stepsField.attributedStringValue = body
            footerField.attributedStringValue = foot
            layout(alert: alert, head: head, body: body, foot: foot)
            scrollStepsToBottom()
        }
        if finished {
            if doneSince == nil { doneSince = Date() }
            // 结束后多停一会儿：让等待的人看清"可以收回控制权了"
            if let since = doneSince, Date().timeIntervalSince(since) > 12 { NSApp.terminate(nil) }
        } else {
            doneSince = nil
        }
    }

    /// 三个圆点的动作。
    private func handle(_ lamp: TrafficLights.Lamp) {
        switch lamp {
        case .close:
            // 红点：面板就此退出。不是不可恢复 —— 任何 session 再调一次 `test_hud` 它就会回来。
            NSApp.terminate(nil)
        case .minimize:
            collapsed.toggle()
            relayout()
        case .zoom:
            zoomed.toggle()
            relayout()
        }
    }

    /// 点了圆点要**立刻**重排。不能只调 `render()` 就完事：它先比内容指纹，而内容和上一次
    /// 一模一样，指纹没变就不会重排 —— 点下去像没反应。清掉指纹是让这条路径绕开那次比较。
    private func relayout() {
        lastFingerprint = ""
        render()
    }

    /// 按内容算高度并摆好四块：顶部色带通栏、头部固定、步骤区滚动、页脚固定；高度变化时**顶边不动**。
    private func layout(alert: NSAttributedString, head: NSAttributedString, body: NSAttributedString, foot: NSAttributedString) {
        guard let screen = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let topInset = max(0, topInsetArg)
        // 高度上限：既要 62% 屏高，也要顶边让开工具栏、底边不压状态栏。
        let maxHeight = min(screen.height * Look.maxHeightRatio,
                            screen.height - max(topInset, Look.screenMargin) - Look.bottomInset)
        let innerWidth = Look.width - Look.inset * 2
        let gap = Look.groupGap

        func height(_ s: NSAttributedString, _ w: CGFloat) -> CGFloat {
            guard s.length > 0 else { return 0 }
            return ceil(s.boundingRect(with: NSSize(width: w, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        // 色带左边要放三个圆点，文字得从它们右边开始 —— 量高度时就得按缩窄后的宽度算，
        // 否则文字按全宽排好版、再塞进窄框里又会折行，高度和实测对不上。
        let alertTextH = height(alert, innerWidth - TrafficLights.reservedWidth)
        let alertH = alertTextH + Look.bandPad * 2        // 色带：文字上下各留 bandPad
        let headH = height(head, innerWidth)
        let bodyH = height(body, innerWidth - 10)
        let footH = height(foot, innerWidth)

        let wanted = alertH + gap + headH + gap + bodyH + (footH > 0 ? gap + footH : 0) + Look.inset
        let natural = min(max(wanted, 96), maxHeight)
        // 黄点折叠：只留一条色带。绿点放大：直接取高度上限，把滚动区撑满（步骤多时能一眼看全）。
        let total = collapsed ? alertH : (zoomed ? maxHeight : natural)
        let stepsH = collapsed ? 0
            : max(28, total - alertH - gap - headH - gap - (footH > 0 ? gap + footH : 0) - Look.inset)

        let oldTop = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.origin.x, y: panel.frame.origin.y,
                              width: Look.width, height: total), display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: Look.width, height: total)
        blurView.frame = panel.contentView?.bounds ?? .zero
        containerView.frame = panel.contentView?.bounds ?? .zero

        // 色带通栏；文字在自己的高度里居中 —— 不再靠段落间距去"顶"，那是顶不下来的。
        alertBand.frame = NSRect(x: 0, y: total - alertH, width: Look.width, height: alertH)
        // 圆点在色带里垂直居中、从左边依次排开。色带高度会随文字折行变，所以每次布局都得重摆。
        let dotStep = TrafficLights.diameter + TrafficLights.gap
        // **必须把圆点提到最上层。** 色带和四个文字视图都是后加进 `containerView` 的，
        // 默认盖在圆点上面 —— 那样圆点位置、颜色、frame 全对，就是被色带整个挡住
        // （插桩日志：`n=3 f0=(12.0, 131.5, 16.0, 16.0) hidden=false alpha=1.0`，一项不差）。
        for dot in bandDots {
            containerView.addSubview(dot, positioned: .above, relativeTo: nil)
        }
        // 框给 16 点、比圆本身（12）大一圈：`NSTextField` 拿 12 点高的框去装 11pt 的字符，
        // 会把字垂直裁掉大半 —— 看上去和"根本没画出来"一模一样（踩过）。
        let dotBox: CGFloat = 16
        for (i, dot) in bandDots.enumerated() {
            dot.frame = NSRect(x: TrafficLights.leading + CGFloat(i) * dotStep
                                 - (dotBox - TrafficLights.diameter) / 2,
                               y: total - alertH + (alertH - dotBox) / 2,
                               width: dotBox, height: dotBox)
        }
        alertField.frame = NSRect(x: TrafficLights.reservedWidth, y: total - alertH + Look.bandPad,
                                  width: Look.width - TrafficLights.reservedWidth, height: alertTextH)
        headerField.frame = NSRect(x: Look.inset, y: total - alertH - gap - headH,
                                   width: innerWidth, height: headH)
        stepsScroll.frame = NSRect(x: Look.inset, y: Look.inset + (footH > 0 ? footH + gap : 0),
                                   width: innerWidth, height: stepsH)
        stepsField.frame = NSRect(x: 0, y: 0, width: innerWidth - 10, height: max(bodyH, stepsH))
        footerField.frame = NSRect(x: Look.inset, y: Look.inset, width: innerWidth, height: footH)
        // 折起来的时候把内容藏掉：它们的 frame 会落到面板外面，留着只会在色带边缘漏出半行字。
        for view in [headerField as NSView?, stepsScroll as NSView?, footerField as NSView?] {
            view?.isHidden = collapsed
        }

        // 导出几何时用的是**全屏**顶边，不是这里的 `screen` —— 那是 visibleFrame，少了菜单栏那 30 点。
        // 面板的 NS 坐标以全屏为基准，拿 visibleFrame 去换算，观测工具就会在比面板实际位置
        // **高 30 点**的矩形里裁图（量出来的数字一直带着这层偏差，查了很久）。
        exportFrame(screen: (panel.screen ?? NSScreen.main)?.frame ?? screen)

        // 面板高度变了：立刻重采底图，别等下一个周期，否则这段时间底图与面板区域不对应。
        if abs(total - laidOutHeight) > 1 {
            laidOutHeight = total
            refreshTheme()
        }

        if !placed {
            placed = true
            panel.setFrameOrigin(origin(for: NSSize(width: Look.width, height: total), on: screen))
        } else {
            panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: oldTop - total))
        }
        // 把手跟着面板走：色带在**屏幕**坐标里的位置 = 面板顶边往下 `alertH` 那一条。
        // （`alertBand.frame` 是面板内部坐标，这里要从 `panel.frame` 反推。）
        // 拖动过程中这个同步不会和拖动打架 —— 它读的就是已经被拖到的位置，只是把把手对齐上去。
        if let handle = dragHandle {
            let band = NSRect(x: panel.frame.minX, y: panel.frame.maxY - alertH,
                              width: Look.width, height: max(0, alertH))
            // `display: true` 不能省。这个窗口是 0 尺寸创建的，尺寸改了却不重绘的话，
            // 屏幕上不会出现任何东西 —— 里面的层（三个圆点）也就一直空白（踩过）。
            if handle.frame != band { handle.setFrame(band, display: true) }
            // 圆点的尺寸**不在这里**同步 —— 见 `DragGrip.resizeSubviews()`。这段代码只在面板内容
            // 变化时才跑，拿它当同步点会让圆点一直停在 .zero（踩过）。
        }
        panel.invalidateShadow()
    }

    private func refreshTheme() {
        lastSampleAt = Date().timeIntervalSince1970
        guard let screen = panel.screen ?? NSScreen.main else { return }
        // 面板在**自己那块屏**上的位置（点，左上原点）—— 采样只用这一块。
        let frame = panel.frame
        let rect = CGRect(x: frame.minX - screen.frame.minX,
                          y: screen.frame.maxY - frame.maxY,
                          width: frame.width, height: frame.height)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let exclude = panel.windowNumber
        let previous = backdrop
        let previousSpread = spread
        let previousSize = sampledSize
        let size = frame.size

        // 采样放**后台线程**：ScreenCaptureKit 的 async 调用和 @MainActor 会互等 ——
        // 症状是一条日志都不出、配色永远停在初始值（踩过）。采完再回主线程套用。
        Task.detached { [rect, displayID, exclude, previous, previousSpread, previousSize, size] in
            guard let (luminance, spread, meanColor, snapshot) =
                await Self.capturePanelArea(rect, displayID: displayID, excluding: exclude) else {
                FileHandle.standardError.write("testhud: sample FAILED\n".data(using: .utf8)!); return }
            // 亮度变化小于 4%、跨度变化小于 0.12、面板尺寸也没变，就不重绘 ——
            // 免得背景稍微一动整个面板跟着抖。跨度也要比：面板从纯色区挪到明暗交界处时
            // backdrop 可能几乎没动，但底图该压多平已经完全不同。
            let sizeChanged = abs(size.height - previousSize.height) > 1 || abs(size.width - previousSize.width) > 1
            guard abs(luminance - previous) > 0.04 || abs(spread - previousSpread) > 0.12 || sizeChanged else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.backdrop = luminance
                self.spread = spread
                self.backdropColor = meanColor
                self.sampledSize = size
                if let snapshot { self.blurView.image = NSImage(cgImage: snapshot, size: .zero) }
                self.applyPalette()
            }
        }
    }

    private static func capturePanelArea(_ rect: CGRect, displayID: CGDirectDisplayID?,
                                         excluding windowNumber: Int) async -> (CGFloat, CGFloat, NSColor, CGImage?)? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first
            else { return nil }
            let mine = content.windows.filter { $0.windowID == CGWindowID(windowNumber) }
            let filter = SCContentFilter(display: display, excludingWindows: mine)

            let outW = max(64, display.width / 4), outH = max(64, display.height / 4)
            let configuration = SCStreamConfiguration()
            configuration.width = outW
            configuration.height = outH
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

            guard let data = image.dataProvider?.data as Data? else { return nil }
            let stride = image.bytesPerRow, bpp = image.bitsPerPixel / 8
            // 分母用**点**（display.frame），因为传进来的 rect 就是点。
            let k = CGFloat(outW) / display.frame.width
            let x0 = max(0, Int(rect.minX * k)), y0 = max(0, Int(rect.minY * k))
            let x1 = min(image.width, x0 + max(1, Int(rect.width * k)))
            let y1 = min(image.height, y0 + max(1, Int(rect.height * k)))

            var sum = 0.0, count = 0
            var sumR = 0.0, sumG = 0.0, sumB = 0.0        // 顺带量出这块区域的颜色
            var hist = [Int](repeating: 0, count: 64)      // 以及它的明暗跨度
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let o = y * stride + x * bpp
                    let r = Double(data[o + 2]) / 255, g = Double(data[o + 1]) / 255, b = Double(data[o]) / 255
                    let v = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    sum += v
                    sumR += r; sumG += g; sumB += b
                    hist[min(63, Int(v * 64))] += 1
                    count += 1
                }
            }
            let luminance = count > 0 ? sum / Double(count) : 0.5
            // 这块区域的平均颜色。只用来问一件事：**这里到底有没有颜色。**
            // 有颜色的背景上，面板文字和背景文字往往是同一个颜色（都是白字或都是黑字），
            // 亮度对比已经拉满，能再把两层字分开的只剩下色相 —— 文字该取它的互补色。
            let meanColor = NSColor(calibratedRed: count > 0 ? sumR / Double(count) : 0.5,
                                    green: count > 0 ? sumG / Double(count) : 0.5,
                                    blue: count > 0 ? sumB / Double(count) : 0.5, alpha: 1)
            // 覆盖区域的明暗跨度（p10~p90）。这不是个摆设：面板底是半透明的，底图会把这块区域的
            // **大尺度明暗**留在面板上，而面板上的文字只有一个颜色 —— 一边亮一边暗时，无论配深字
            // 还是白字都会有一半失准（实测：同一块面板上底色从 0.51 到 0.31，白字对亮的那半只有 2.5:1）。
            // 跨度是"这个风险有多大"的唯一量度，底图该压多平、由它决定。
            var spread: CGFloat = 0
            if count > 0 {
                func pct(_ p: Double) -> Double {
                    var acc = 0
                    for (i, n) in hist.enumerated() {
                        acc += n
                        if Double(acc) >= p * Double(count) { return Double(i) / 64 }
                    }
                    return 1
                }
                spread = CGFloat(pct(0.90) - pct(0.10))
            }

            // 面板那块位置的一份**模糊快照** —— 它会成为面板的底。
            // 后方内容因此变成柔和的光斑：仍然看得出"下面有东西"，但不会和面板文字抢读。
            var blurred: CGImage?
            /// 面板底的**等效背景亮度** —— 会被换成"底图真实的均值"，见下面。
            var effective = luminance
            if let cropped = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) {
                // σ 要够大：14 时密集文字仍能辨认出字形，和面板文字抢读（截图里一眼就看出来）。
                // 再把对比度压低 —— 背景退成"低对比的纹理"，这比提高面板不透明度更划算：
                // 后者会增加遮挡，前者不增加。
                // **用原图的 extent 导出，不能用模糊后的** —— CIGaussianBlur 会把 extent 向外扩约 3σ，
                // 用它的 extent 导出会带上一圈透明边：341×249 的图里有效内容只有 185×93，
                // 贴到面板上拉伸之后，面板的边缘区域其实根本没有底图覆盖，原始背景就直接露出来了
                // （这就是"密集文字仍能读出来"的真正原因，查了很久）。
                let ci = CIImage(cgImage: cropped)
                // σ 与对比度是两把不同的刀：σ 负责把字形化开，对比度负责把剩下的痕迹压淡。
                // 面板压在最密的文字上时（终端铺满整屏的 ls 输出），σ=26 之后仍留下条纹状的痕迹
                // —— 低方差行占比只有 16%（稀疏背景时是 43~51%），所以两把刀都加一点。
                //
                // 对比度再按**跨度**自适应：跨度大就压得更平。压平不增加遮挡（面板底的不透明度没动），
                // 代价只是"下面有东西"的痕迹变淡 —— 那比让面板自己的文字失准划算。
                let contrast = max(0.12, 0.40 - spread * 0.70)
                // 再把均值**锚回 backdrop**。这一步是必须的：对比度是围绕中灰压缩的，
                // 压完之后这块图的均值不再是 backdrop（0.30 的图会被抬到 0.42），
                // 而配色算法是拿 backdrop 算面板底的 —— 两者一旦不一致，算出来的对比度就是假的，
                // 面板会照着一个不存在的底去配文字色（这正是"底色 0.51 到 0.31"那次的根因）。
                let offset = (luminance - 0.5) * (1 - contrast)
                let blurredCI = ci.applyingGaussianBlur(sigma: 34)
                    .applyingFilter("CIColorControls", parameters: [
                        kCIInputContrastKey: contrast,
                        kCIInputSaturationKey: 0.70,
                    ])
                    // 亮度单独一次，保证它是压在对比度**之后**的线性偏移（同一个 filter 里的先后顺序不可靠）
                    .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: offset])
                blurred = CIContext().createCGImage(blurredCI, from: ci.extent)
                // 量出**底图真正的平均亮度**，拿它当 backdrop —— 而不是采样均值。
                // 两者在浅色背景下只差 0.001，在深色背景下能差一倍：CIColorControls 工作在
                // **线性**空间，而采样均值是在 **gamma** 空间（0~255 直接加权）算的，中间还隔着
                // 一次对比度压缩、一次亮度偏移。配色算法是拿 backdrop 去算面板底的 ——
                // 这个数一旦不是"底图真实的均值"，算出来的对比度就是对着一个不存在的底算的
                // （这正是"同一块面板上底色从 0.51 到 0.31"那个 bug 的另一半）。
                // 与其推公式去补偿，不如直接量 —— 这也是这个项目一贯的做法。
                let avg = blurredCI.applyingFilter("CIAreaAverage",
                                                   parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
                var px = [UInt8](repeating: 0, count: 4)
                // 必须**显式要 sRGB**：`CIAreaAverage` 的结果在**线性**空间，`colorSpace: nil`
                // 会把线性值原封不动当成 sRGB 交出来，底图均值于是偏暗一倍（实测 0.039 对截图 0.118）。
                // `CIFormat.RGBA8` 同时把字节顺序定死了 —— px[0] 就是红，不用猜 bitmapInfo。
                CIContext().render(avg, toBitmap: &px, rowBytes: 4,
                                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                   format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
                effective = (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / 255
            }
            return (effective, spread, meanColor, blurred)
        } catch {
            FileHandle.standardError.write("testhud: SCK error \(error)\n".data(using: .utf8)!)
            return nil
        }
    }


    /// 换配色：面板色直接改 layer，文字靠重画。
    private func applyPalette() {
        containerView.layer?.backgroundColor = palette.panelFill.cgColor
        containerView.layer?.borderColor = palette.panelBorder.cgColor
        alertBand.layer?.backgroundColor = alertBackgroundNow().cgColor
        // 逼 render() 重画文字。注意光把 fingerprint 清掉还不够：attributedStringValue 的**文字内容**
        // 没变、只有颜色变了时，AppKit 可能判定"没变化"而不重绘（踩过 —— 面板底换了、字还是旧颜色）。
        // 所以再显式 needsDisplay 一次。
        lastFingerprint = ""
        render()
        for field in [alertField, headerField, stepsField, footerField] {
            field?.needsDisplay = true
        }
        exportTheme()
    }

    /// 把"这一帧到底用了哪套参数"写到磁盘，供观测工具核对（`bin/testhud-inspect.py`）。
    /// 与 `panel-frame.json` 同一个理由：**不要靠猜**。面板的底、两级文字、色带都是算出来的 ——
    /// 只看截图反推，只能知道"渲染成了什么"，不知道"为什么是这个值"。
    /// 尤其要盯 `sampledSize` 与 `panelSize` 是否一致：面板长高之后底图若还是旧尺寸，它会被拉伸铺满，
    /// 于是每一行的亮度不再等于 `backdrop`（"同一块面板上底色从 0.51 到 0.31"就是这么来的）。
    private func exportTheme() {
        let fill = palette.panelFill
        // 与 `Theme.palette(for:)` 里同一个式子：面板底 = fillAlpha 混合在 backdrop 之上。
        let panelLum = fill.alphaComponent * Theme.luminance(fill)
                     + (1 - fill.alphaComponent) * backdrop
        let primaryLum = Theme.luminance(palette.primary)
        let secondaryLum = Theme.luminance(palette.secondary)
        // 环境色相与"文字到底上没上色" —— 这两条只有导出来才看得见：上色**不改任何对比度数字**，
        // 所以从截图和对比度上都判断不出它有没有触发。`tintHue = -1` 表示环境是中性、文字用黑白灰。
        var bgHue: CGFloat = 0, bgSat: CGFloat = 0, bgVal: CGFloat = 0
        (backdropColor.usingColorSpace(.deviceRGB) ?? backdropColor)
            .getHue(&bgHue, saturation: &bgSat, brightness: &bgVal, alpha: nil)
        var bannerSat: CGFloat = 0, bannerVal: CGFloat = 0
        (palette.alertRunBg.usingColorSpace(.deviceRGB) ?? palette.alertRunBg)
            .getHue(nil, saturation: &bannerSat, brightness: &bannerVal, alpha: nil)
        // 带底**呈现**出来的亮度（alpha 混合之后）—— 带上的字是对着它反解的。
        let bannerShown = palette.alertRunBg.alphaComponent * Theme.luminance(palette.alertRunBg)
                        + (1 - palette.alertRunBg.alphaComponent) * panelLum
        let info: [String: Any] = [
            "updatedAt": Date().timeIntervalSince1970,
            "backdrop": backdrop,
            "spread": spread,
            "fillAlpha": fill.alphaComponent,
            "panelLum": panelLum,
            "primaryLum": primaryLum,
            "secondaryLum": secondaryLum,
            "bgHue": bgHue, "bgSat": bgSat,
            "tintHue": Theme.tintHue(for: backdropColor).map { Double($0) } ?? -1,
            // 色带：饱和度、明度、字色亮度 —— 同样是算出来的，同样只有导出来才看得见。
            "bannerSat": bannerSat, "bannerVal": bannerVal,
            "bannerFgLum": Theme.luminance(palette.alertRunFg),
            // 字对的是**混合之后**的带底，不是带底颜色本身 —— 带子是半透明的，
            // 拿未混合的颜色去比会低估一大截（实测 3.55 对真实 6.5），这是口径问题不是算法问题。
            "bannerShown": bannerShown,
            "bannerFgVsBanner": Theme.contrast(bannerShown, Theme.luminance(palette.alertRunFg)),
            "primaryVsPanel": Theme.contrast(panelLum, primaryLum),
            "secondaryVsPanel": Theme.contrast(panelLum, secondaryLum),
            "panelW": panel.frame.width, "panelH": panel.frame.height,
            "sampledW": sampledSize.width, "sampledH": sampledSize.height,
            "blurW": blurView.image?.size.width ?? 0, "blurH": blurView.image?.size.height ?? 0,
        ]
        let dir = NSHomeDirectory() + "/.dsh/dsh-testhud"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: dir + "/theme.json"))
        }
    }

    /// 面板内容的指纹（不含时间）。
    private func contentFingerprint(_ p: Progress) -> String {
        var s = p.title + "|" + (p.target ?? "") + "|" + (p.note ?? "") + "|" + (p.status ?? "")
        for step in p.steps ?? [] {
            s += "|" + step.name + "\u{1}" + (step.expect ?? "") + "\u{1}" + (step.actual ?? "") + "\u{1}" + (step.state ?? "")
        }
        return s
    }

    /// 把面板的精确几何写到磁盘，供观测工具使用（`bin/testhud-inspect.py`）。
    /// **这是为了不再猜坐标** —— 之前一系列"背景文字是否穿透"的误判，根因都是工具侧凭 OCR 反推面板范围。
    /// 坐标系说明：这里写的是 NS 坐标（原点在左下），工具会把它换算成截图的物理像素（原点在左上）。
    private func exportFrame(screen: NSRect) {
        let info: [String: Any] = [
            "x": panel.frame.minX,
            "y": panel.frame.minY,
            "width": panel.frame.width,
            "height": panel.frame.height,
            "screenWidth": screen.width,
            "screenHeight": screen.height,
            "screenOriginX": screen.minX,
            "screenOriginY": screen.minY,
            "screenTop": screen.maxY,
            "scale": (panel.screen ?? NSScreen.main)?.backingScaleFactor ?? 2,
            "windowNumber": panel.windowNumber,
            "updatedAt": Date().timeIntervalSince1970,
        ]
        let dir = NSHomeDirectory() + "/.dsh/dsh-testhud"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: dir + "/panel-frame.json"))
        }
    }

    private func scrollStepsToBottom() {
        let clip = stepsScroll.contentView
        let maxY = max(0, stepsField.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: maxY))
        stepsScroll.reflectScrolledClipView(clip)
    }

    // MARK: 文案

    /// 第一行通栏色带：**这块浮层存在的首要理由** —— 现在能不能碰鼠标键盘。
    /// 文字用 headIndent 拉回内容左边界，和下面几行对齐（Alignment）。
    private func composeAlert(_ p: Progress) -> NSAttributedString {
        let status = p.status ?? "running"
        let foreground = (status == "running") ? palette.alertRunFg : palette.alertDoneFg
        return NSAttributedString(string: handoffLine(status), attributes: [
            .font: Look.alertFont,
            .foregroundColor: foreground,
            .paragraphStyle: Look.para(indent: Look.inset),
        ])
    }

    /// 色带底色 —— 由当前状态与算出来的那套配色决定（不是固定色）。
    private func alertBackgroundNow() -> NSColor {
        let data = FileManager.default.contents(atPath: progressPath)
        let status = data.flatMap { try? JSONDecoder().decode(Progress.self, from: $0) }?.status ?? "running"
        return status == "running" ? palette.alertRunBg : palette.alertDoneBg
    }

    /// 控制权提示 —— **这是这块浮层存在的首要理由**：让人知道现在能不能碰鼠标键盘。
    private func handoffLine(_ status: String) -> String {
        switch status {
        case "done":   return "✅ 已结束，可以收回鼠标键盘的控制权了"
        case "failed": return "⚠️ 已结束（有失败），可以收回控制权；结论见下方"
        default:       return "🖱️⌨️ 正在进行：先别动鼠标键盘，以免打断测试"
        }
    }

    /// 头部一组：标题（最强）→ 测试对象 → 计时（最弱）。组内靠灰度拉开，不加空行。
    private func composeHeader(_ p: Progress) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: p.title + "\n", attributes: [
            .font: Look.titleFont, .foregroundColor: palette.primary, .paragraphStyle: Look.para(after: 4),

        ]))
        if let t = p.target, !t.isEmpty {
            out.append(NSAttributedString(string: "测试对象：" + t + "\n", attributes: [
                .font: Look.bodyFont, .foregroundColor: palette.secondary, .paragraphStyle: Look.para(after: 2),
            ]))
        }
        if let s = p.startedAt {
            let elapsed = Date().timeIntervalSince1970 - s
            out.append(NSAttributedString(string: String(format: "开始 %@ · 已用 %.0f 秒", timeString(s), elapsed),
                                          attributes: [
                .font: Look.metaFont, .foregroundColor: palette.secondary, .paragraphStyle: Look.para(),
            ]))
        }
        return out
    }

    /// 步骤一组：行首一个状态字符上色，其余一律白/灰 —— 颜色不铺满整行。
    private func composeSteps(_ p: Progress) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, step) in (p.steps ?? []).enumerated() {
            let mark: String, markColor: NSColor
            switch step.state ?? "info" {
            // `ok` 与 `pass` 都是"这步过了"：bash 版脚本写的是 ok，别让它显示成灰点。
            case "pass", "ok": mark = "✅"; markColor = palette.stateOk
            case "fail":       mark = "❌"; markColor = palette.stateBad
            case "run":        mark = "⏳"; markColor = palette.stateRun
            default:           mark = "•";  markColor = palette.stateInfo
            }
            let first = Look.para(before: i == 0 ? 0 : Look.stepGap, after: 2)
            out.append(NSAttributedString(string: mark, attributes: [
                .font: Look.stepFont, .foregroundColor: markColor, .paragraphStyle: first,
            ]))
            out.append(NSAttributedString(string: " \(i + 1). " + step.name + "\n", attributes: [
                .font: Look.stepFont, .foregroundColor: palette.primary, .paragraphStyle: first,
            ]))
            // 真正缩进（headIndent），不是空格 —— 比例字体下空格对不齐。
            if let e = step.expect, !e.isEmpty {
                out.append(NSAttributedString(string: "期待：" + e + "\n", attributes: [
                    .font: Look.bodyFont, .foregroundColor: palette.secondary,
                    .paragraphStyle: Look.para(indent: Look.stepIndent),
                ]))
            }
            if let a = step.actual, !a.isEmpty {
                out.append(NSAttributedString(string: "实际：" + a + "\n", attributes: [
                    .font: Look.bodyFont, .foregroundColor: palette.secondary,
                    .paragraphStyle: Look.para(indent: Look.stepIndent),
                ]))
            }
        }
        return out
    }

    /// 结论一组：字重回到 semibold、颜色回到最亮 —— 与步骤区分开。
    private func composeFooter(_ p: Progress) -> NSAttributedString {
        guard let n = p.note, !n.isEmpty else { return NSAttributedString() }
        return NSAttributedString(string: "结论：" + n, attributes: [
            .font: Look.stepFont, .foregroundColor: palette.primary, .paragraphStyle: Look.para(),

        ])
    }

    private func timeString(_ epoch: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }

    // MARK: 位置：优先不挡被测对象，其次居中，再左、再右

    /// 三个水平候选，纵向一律"靠上"：顶边让开菜单/工具栏，底边不越过状态栏（高度上限见 layout）。
    /// 横向都不贴边（`sideInset`），免得压住侧边栏或滚动条。
    private func candidates(size: NSSize, on screen: NSRect) -> [(name: String, origin: NSPoint)] {
        let top = max(Look.screenMargin, topInsetArg)
        let y = screen.maxY - size.height - top
        let side = max(Look.screenMargin, Look.sideInset)
        // 旧配置里的 top-left / top-right 继续认，映射到靠上的左 / 右。
        return [
            ("center", NSPoint(x: screen.minX + (screen.width - size.width) / 2, y: y)),
            ("left",   NSPoint(x: screen.minX + side, y: y)),
            ("right",  NSPoint(x: screen.maxX - size.width - side, y: y)),
        ]
    }

    private func origin(for size: NSSize, on screen: NSRect) -> NSPoint {
        let cands = candidates(size: size, on: screen)
        let wanted = anchorArg == "top-left" ? "left" : (anchorArg == "top-right" ? "right" : anchorArg)
        if wanted != "auto", let hit = cands.first(where: { $0.name == wanted }) { return hit.origin }

        // 打分对象是**被测对象**本身 —— 前台应用的窗口。躲开它优先于居中/靠边：
        // 三个候选里挑与它重叠面积最小的；并列时取靠前的（居中 > 左 > 右）。
        let targets = frontWindowsInScreenCoords()
        guard !targets.isEmpty else { return cands[0].origin }
        var best = cands[0], bestScore = CGFloat.greatestFiniteMagnitude
        for c in cands {
            let rect = NSRect(origin: c.origin, size: size)
            let score = targets.reduce(CGFloat(0)) { $0 + overlapArea(rect, $1) }
            if score < bestScore { bestScore = score; best = c }
        }
        return best.origin
    }

    private func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }

    /// **前台应用（被测对象）的窗口**在屏幕坐标里的矩形 —— 面板要躲的就是它。
    /// 用 CGWindowList（不需要辅助功能权限），并把"左上原点"的 CG 坐标换成 NSWindow 的"左下原点"。
    private func frontWindowsInScreenCoords() -> [NSRect] {
        guard let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontPID != getpid() else { return [] }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        var out: [NSRect] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner == frontPID,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let x = b["X"] ?? 0, y = b["Y"] ?? 0, width = b["Width"] ?? 0, height = b["Height"] ?? 0
            guard width > 120, height > 120 else { continue }
            out.append(NSRect(x: x, y: screenTop - y - height, width: width, height: height))
        }
        return out
    }
}

/// 把手事件的诊断日志（写在 `~/.dsh/dsh-testhud/drag.log`）。
/// 排障用的：窗口在位、位置分毫不差、辅助功能权限也是 true，拖动却毫无反应 ——
/// 只有日志能分辨"事件根本没到窗口"和"到了但位移算错"。留在代码里，下次不用重查一遍。
func dragLog(_ text: String) {
    let dir = NSHomeDirectory() + "/.dsh/dsh-testhud"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/drag.log"
    let line = "\(Date().timeIntervalSince1970) \(text)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// 色带的拖拽把手 —— 一个**只盖住色带那一条**的透明窗口。
///
/// 为什么不直接在面板上开关鼠标：`ignoresMouseEvents` 是**窗口级**的，macOS 没有"这块穿透、
/// 那块不穿透"的写法。而面板必须整体保持穿透 —— 它要压在被测界面之上，一旦开始吃点击，
/// 底下那个应用就没法操作了，而这是这个浮层存在的前提。所以"抓得住"只能由另一个窗口提供。
///
/// 代价要说清楚：**色带那一条从此不再穿透**。拖到色带上会抓住它移动整个面板，而不是点到底下的应用。
/// 这就是用户要的手动定位能力，换来的是色带上损失一条点击区（约 40 点高、740 点宽）。
final class DragHandle: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 把手的 contentView —— 真正接住鼠标的地方（为什么不能写在窗口上，见 `DragHandle` 的注释）。
final class DragGrip: NSView {
    /// 被拖动的主面板。弱引用：把手是面板的附属物，面板没了它不该继续留着。
    weak var host: NSWindow?

    /// 色带左端那三个圆点，跟着把手一起调整尺寸。
    var lights: TrafficLights?

    /// 圆点的尺寸**只能在这里同步**，而且**必须用 `resizeSubviews` 而不是 `layout()`**。
    ///
    /// 这一行试错了三次才落到对的地方：
    /// 1. 放进 `HUD.layout()` —— 那段代码只在面板**内容变化**时才跑，而把手窗口是启动那一次
    ///    （圆点还没建）定好尺寸的，之后再没人调它；
    /// 2. 改用自己的 `layout()` —— 照样不行：`layout()` 是 **Auto Layout 的钩子**，这棵树里
    ///    一个约束都没有，AppKit 压根不会主动调它（日志坐实：只在启动那两次被调过，之后
    ///    把手窗口改了好几次尺寸，它一动不动）；
    /// 3. `resizeSubviews(withOldSize:)` 才是 frame-based 视图在尺寸变化时一定会走的钩子。
    ///
    /// 症状自始至终一样：圆点的 frame 停在 `.zero` —— 视图在、点击也有效、就是看不见。
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        lights?.frame = bounds
    }

    /// **这个必须返回 true，否则一次都拖不动。**
    /// app 是 `.accessory`、窗口是 `.nonactivatingPanel` —— 它永远不会成为 key window，
    /// 于是每一次点击在 AppKit 眼里都是 "first mouse"：默认会被吞掉，只用于"激活"一个
    /// 本来就不需要激活的窗口。前面查窗口位置、查辅助功能权限全都是白查，就卡在这一行。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 上一次鼠标的**全局**位置 —— 位移靠它自己算，不用 `event.deltaX/deltaY`。
    ///
    /// 为什么不用 `delta`：合成事件（CGEvent，自动化测试就是用它发的）里 delta 恒为 **0**，
    /// 只有真人拖动才有值。于是会掉进最难查的那种状态 —— 真人能用、自动化永远拖不动，
    /// 或者反过来。自己算差值，两条路都对。
    ///
    /// 为什么用 `NSEvent.mouseLocation` 而不是 `event.locationInWindow`：后者是**窗口内**坐标，
    /// 而拖动时窗口自己也在动，鼠标没动也会算出位移，正反馈一路跑飞。
    /// `mouseLocation` 是全局屏幕坐标，和 `setFrameOrigin` 用的是同一套坐标系，不受窗口移动影响。
    private var lastPoint: NSPoint = .zero

    /// 必须实现。不实现的话 AppKit 不认为这个 view 参与了本次拖拽，
    /// 后续的 `mouseDragged` 一次都不会来（只写 dragged 不写 down 同样拖不动）。
    override func mouseDown(with event: NSEvent) {
        lastPoint = NSEvent.mouseLocation
        dragLog("mouseDown global=\(lastPoint)")
    }

    /// 把窗口原点夹进**鼠标所在那块屏**的可见范围 —— 按鼠标选屏，跨屏拖动就自然成立。
    ///
    /// 夹的是整块窗口，不留"露一条缝"的花活：边缘只露一条缝的浮层和丢了没区别，用户照样找不到。
    /// `max(...)` 那一层是给"窗口比屏幕还高"这种极端情况兜底的，免得夹出个上小下大的空区间。
    private func clamp(_ origin: NSPoint, size: NSSize) -> NSPoint {
        guard let vis = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                         ?? NSScreen.main)?.visibleFrame else { return origin }
        return NSPoint(
            x: min(max(origin.x, vis.minX), max(vis.minX, vis.maxX - size.width)),
            y: min(max(origin.y, vis.minY), max(vis.minY, vis.maxY - size.height)))
    }

    override func mouseUp(with event: NSEvent) {
        lastPoint = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        // **这一行是兜底，必须有。** 如果这次拖拽的 mouseUp 没能回到这个 view（合成的鼠标事件、
        // 鼠标滑出把手、窗口被挪走都会），AppKit 会把之后**所有**的鼠标移动继续当成 dragged 发过来 ——
        // 于是一个字都没按，鼠标一动面板就跟着跑，一路滑出屏幕（实测掉到 x=-121，屏幕都出不去）。
        // 每帧直接问硬件"左键还按着吗"，比信任事件关联可靠得多。
        guard NSEvent.pressedMouseButtons & 0x1 == 1 else {
            lastPoint = .zero
            return
        }
        // 没有配对的 `mouseDown` 就不该算位移：点在圆点上时 down 被圆点吃掉了，事件却仍会上溯到
        // 这里，而此时 `lastPoint` 还是 `.zero` —— 算出来的"位移"等于鼠标的**绝对坐标**，面板会瞬移。
        guard lastPoint != .zero else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - lastPoint.x, dy = now.y - lastPoint.y
        lastPoint = now
        guard let host = host, let handle = window else { return }
        // 相对拖动：面板跟着鼠标的位移走，不需要记"抓在哪个点"。
        // 但必须夹在屏幕里 —— 拖出去就再也点不到了（浮层没有 Dock 图标、没有菜单栏入口、
        // 也不出现在 ⌘Tab 里），只能重启面板才找得回来。实测拖到过 X:1594 Y:-640 那种
        // 两块屏之间的空白地带，屏幕上什么都看不见。
        host.setFrameOrigin(clamp(NSPoint(x: host.frame.origin.x + dx, y: host.frame.origin.y + dy),
                                  size: host.frame.size))
        // 把手当场跟上，不等下一次 `layout()`（最多 0.4 秒后）：否则拖动时把手会明显"掉队"，
        // 看起来像色带没跟着面板走。（拖拽期间事件是锁定在这个 view 上的，鼠标跑出把手也不会断。）
        handle.setFrameOrigin(NSPoint(x: host.frame.minX, y: host.frame.maxY - handle.frame.height))
        dragLog("dragged d=(\(dx),\(dy)) host=\(host.frame.origin)")
    }
}

/// 色带左端的三个圆点 —— 红关闭 / 黄折叠 / 绿缩放，配色和尺寸照 macOS 自己的来。
///
/// 为什么画在把手窗口里（见 `DragHandle`）：主面板整体鼠标穿透，整块浮层只有把手那一条能接鼠标，
/// 圆点必须住在它里面。做成 `DragGrip` 的子视图，点击天然被吃掉，不会漏给底下的拖拽逻辑。
///
/// **这三个颜色不参与变色龙算法。** 面板上其它文字都是按环境算出来的，这三颗不行：
/// 用户认的就是"红黄绿 = 关掉 / 收起来 / 放大"，跟着背景变色反而认不出来。
final class TrafficLights: NSView {
    enum Lamp: CaseIterable { case close, minimize, zoom }

    var onLamp: ((Lamp) -> Void)?

    /// macOS 自己的取值：#FF5F57 / #FEBC2E / #28C840。
    /// 不是 private —— 主面板要用同一组颜色画它那份圆点（见 `HUD.bandDots`）。
    static let colors = [
        NSColor(srgbRed: 1.00, green: 0.373, blue: 0.341, alpha: 1),
        NSColor(srgbRed: 0.996, green: 0.737, blue: 0.180, alpha: 1),
        NSColor(srgbRed: 0.157, green: 0.784, blue: 0.251, alpha: 1),
    ]

    static let diameter: CGFloat = 12
    static let gap: CGFloat = 8
    static let leading: CGFloat = 14

    /// 圆点的描边（2026-09-18）。**宽度 1.0 点、颜色白** —— 这是用户看过四版实测后选的，
    /// 不是按"对比度最优"选的，所以先把它的含义写清楚。
    ///
    /// 起因：色带固定成鲜红 / 鲜绿之后，红点落在鲜红底上会融成一片 —— 实测红点 `RGB(242,96,82)`
    /// 对底色 `RGB(213,70,56)` 只有 **1.03:1**，而红点是鼠标关掉浮层的唯一入口；done 态的绿点
    /// 也从"清楚"退成"勉强看得出"。黄点两态都没事，但三颗点必须长得一样，否则"红黄绿"这组语义就散了。
    ///
    /// 当天试了四版，环对色带底的对比度（浅底 / 深底）：
    ///   · 1.5 点 黑 0.85  → 4.57 / ~7.0   效果最好，但用户看后说"黑色难看"
    ///   · 1.0 点 黑 0.75  → 3.22 / 1.97   用户先选的折中：深底不达标（半透明让红点透上来抬亮了环）
    ///   · 1.0 点 黑 1.00  → 11.21 / 7.00  数据最好，但仍然是黑
    ///   · 1.0 点 白 1.00  → 2.39 / 3.11   ← **最终选它**：用户要白，并接受"浅底上红点仍不明显"
    ///
    /// **两个必须记住的物理事实**：
    ///   1. 对比度由**颜色**决定，与描边宽度**无关**。白变细不会更清楚，只会更不显眼
    ///      （环的像素数 468 → 252）。白环对鲜红底无论多粗都只有 ~2:1，因为色带永远是高饱和
    ///      亮色（饱和与明度钉在 1.0）。
    ///   2. 深色描边在这个色带上**始终是白环的 3 倍以上**（色带呈现亮度只落在 0.21~0.84）。
    ///      要"既好看又看得见"，只有换成深色这一条路。
    /// 所以现在的状态是一次**知情的取舍**，不是没修好 —— 别"顺手修好"它而不先问用户。
    private static let strokeWidth: CGFloat = 1.0
    private static let strokeColor = NSColor.white
    /// 含描边的外径。frame 要用这个尺寸（见 `layoutDots`）。
    static var outerDiameter: CGFloat { diameter + 2 * strokeWidth }

    /// 圆点总共占掉色带左边多宽 —— 色带文字要从这里往右开始排。
    static var reservedWidth: CGFloat { leading + diameter * 3 + gap * 2 + 12 }

    /// 命中范围比圆本身大一圈：12 点的圆要精准点中太费劲，macOS 自己也放宽。
    private static let slop: CGFloat = 4

    /// 三颗圆各自是一个 layer 小视图，**不靠 `draw(_:)`**。
    ///
    /// 第一版是用 `draw` 画的，结果一颗都没出来（扫描色带那一行，只有面板自己的琥珀色）。
    /// `draw` 什么时候被调用，完全交给 AppKit 的显示调度 —— 而这个视图住在一个从 `.zero`
    /// 起步、之后又被 `setFrame(display: false)` 改过尺寸的把手窗口里，不该赌它会被调。
    /// 换成子视图 + `cornerRadius` 之后渲染走 CALayer，只要进了视图层次就会显示。
    private var dots: [NSView] = []
    private static var layoutLogs = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        for _ in Self.colors {
            let dot = NSView()
            dot.wantsLayer = true
            addSubview(dot)
            dots.append(dot)
        }
        // 建完就摆一次。不能只等 `resizeSubviews` —— 如果这个视图一进来就已是最终尺寸，
        // 那个钩子永远不会触发，三颗圆会一直保持 0×0。
        layoutDots()
    }

    required init?(coder: NSCoder) { fatalError("这个视图只有代码创建一条路") }

    /// 尺寸一变就重排三颗圆（把手的宽高每个周期都可能跟着面板走）。
    /// 同样不能用 `layout()` —— 原因见 `DragGrip.resizeSubviews`：那是 Auto Layout 的钩子。
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutDots()
        if Self.layoutLogs < 3 {
            Self.layoutLogs += 1
            dragLog("lights.resize bounds=\(bounds) layers=\(dots.map { $0.layer != nil }) "
                    + "bg=\(dots.first?.layer?.backgroundColor != nil) frames=\(dots.map { $0.frame })")
        }
    }

    /// 摆位置 **并且** 每次都重设 layer 的样子。
    ///
    /// 颜色和圆角放在这里、而不是 init 里：视图刚 `init` 时还没进窗口，`dot.layer` 可能是 nil，
    /// 而 `dot.layer?.backgroundColor = ...` 遇到 nil 是**静默通过**的 —— 不报错、也不生效，
    /// 圆点于是永远透明。frame 一直是对的，只是眼睛看不见（查了三轮才落到这一行上）。
    private func layoutDots() {
        let step = Self.diameter + Self.gap
        // frame 取**外径**，位置向左、向上各让出描边宽度 —— 于是描边长在外面，彩色圆的圆心与
        // 半径分毫不动。（踩过：直接把 border 加在 12 点的框上，`CALayer` 的 border 是**向内**画的，
        // 会吃掉两倍描边宽 —— 1.5 点那版实测色块从 452 px 缩到 216 px，肉眼就是"圆点变小了"。）
        let outer = Self.outerDiameter
        for (i, dot) in dots.enumerated() {
            dot.frame = NSRect(x: Self.leading + CGFloat(i) * step - Self.strokeWidth,
                               y: (bounds.height - outer) / 2,
                               width: outer, height: outer)
            dot.layer?.backgroundColor = Self.colors[i].cgColor
            dot.layer?.cornerRadius = outer / 2
            dot.layer?.borderWidth = Self.strokeWidth
            dot.layer?.borderColor = Self.strokeColor.cgColor
        }
    }

    /// 第几颗圆被点到了（`local` 是本视图坐标）。
    private func lampIndex(at local: NSPoint) -> Int? {
        let step = Self.diameter + Self.gap
        let cy = bounds.height / 2
        for i in 0..<Self.colors.count {
            let cx = Self.leading + CGFloat(i) * step + Self.diameter / 2
            if abs(local.x - cx) <= Self.diameter / 2 + Self.slop,
               abs(local.y - cy) <= Self.diameter / 2 + Self.slop { return i }
        }
        return nil
    }

    /// 只有三颗圆本身接鼠标，其余地方返回 nil —— 于是色带左端那一条**仍然拖得动**。
    /// （本视图铺满整条色带；不这么写，左端 80 点宽的一整条就废了。）`point` 在**父视图**坐标里。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let parent = superview else { return nil }
        return lampIndex(at: convert(point, from: parent)) != nil ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let i = lampIndex(at: convert(event.locationInWindow, from: nil)) {
            onLamp?(Lamp.allCases[i])
        }
    }

    /// 必须把 dragged 吃掉。不实现的话事件会沿响应链上溯到 `DragGrip`，而它的 `lastPoint`
    /// 还停在 `.zero`（它的 `mouseDown` 被圆点截住了，没机会更新）—— 于是"点一下圆点"就变成
    /// 把面板朝鼠标的绝对坐标推一下，点一次跑一次（实测 x：28 → 96 → 232）。
    override func mouseDragged(with event: NSEvent) {}
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)                 // 不出现在 Dock / ⌘Tab
let hud = HUD()
app.delegate = hud
app.run()
