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
    /// 色带上文字的对比目标。字色现在也是反解出来的，**不必再迁就 0.06 那个旧常量**：
    /// 解出来的字更黑，白送的对比度就该拿（实测深色密集文字背景上，色带从 3.7:1 提到 6.5:1）。
    static let alertContrast: CGFloat = 6.5
    /// 解色带明度时假定的"字有多黑"与目标 —— 这一层只决定**色带该多亮**，不决定最终字色。
    static let bannerSeedText: CGFloat = 0.06
    static let bannerSeedContrast: CGFloat = 4.5
    /// 色带的不透明度：钉住不动（用户要求"能看到后面的文字"）；明度不够时去调明度。
    static let bannerAlpha: CGFloat = 0.55

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
    static func banner(hue: CGFloat, baseSaturation: CGFloat, alpha: CGFloat,
                       panelLum: CGFloat, envSat: CGFloat, tint: CGFloat?) -> (fill: NSColor, text: NSColor) {
        // 饱和度：环境本身有色时降一点 —— 一条满饱和的带子压在彩色背景上，两种颜色会互相打架
        // （那是视觉噪音，不是信息）；环境中性时保持满饱和，那时它得独自承担全部辨识度。
        let sat = max(0.25, baseSaturation * (1 - 0.5 * min(1, envSat)))
        // 给定的色相与饱和度下，"明度 = 1" 时这层颜色本身的亮度。
        // HSB 下亮度 = b × (1 − (1 − base) × s)，在 device 空间实测精确成立，所以可以反解。
        let scale = 1 - (1 - luminance(NSColor(deviceHue: hue, saturation: 1, brightness: 1, alpha: 1))) * sat
        let floor = plateLum(text: bannerSeedText, contrast: bannerSeedContrast, darker: false)
        // 带底**呈现**出来要够 `floor`；`needed` 是它在 alpha 混合之前应有的亮度。
        let needed = (floor - (1 - alpha) * panelLum) / max(0.05, alpha)
        let brightness = min(1.0, max(0.30, needed / max(0.05, scale)))
        // 呈现亮度得按**实际的色相与饱和度**算，不能再拿明度近似 —— 饱和度一降，同样的明度更亮。
        let shown = alpha * brightness * scale + (1 - alpha) * panelLum
        return (NSColor(deviceHue: hue, saturation: sat, brightness: brightness, alpha: alpha),
                textColor(over: shown, contrast: alertContrast, tint: tint))
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
        // 环境饱和度 —— 色带的饱和度由它决定（环境有色时色带降饱和，免得两种颜色打架）。
        var envSat: CGFloat = 0, envVal: CGFloat = 0
        (color.usingColorSpace(.deviceRGB) ?? color).getHue(nil, saturation: &envSat, brightness: &envVal, alpha: nil)
        let primary = textColor(over: panelLum, contrast: primaryContrast, tint: tint)
        // 二级：先看一级**实际**拿到了多少对比度（可能已被夹紧），再按比例退一档 ——
        // 直接解 secondaryContrast 会在暗面板上撞到 1.0 的天花板，两级双双变纯白，层次就没了。
        let reachable = contrast(panelLum, luminance(primary))
        let secondary = textColor(over: panelLum,
                                  contrast: min(secondaryContrast, reachable * secondaryRatio), tint: tint)

        // 色带也交给"变色龙"：**只有色相是常量**（黄=别动、绿=可以接手，语义不能漂），
        // 饱和度、明度、字色全部由环境反解，不透明度钉在 0.55（后面的字要能看见）。
        // 明度不够就调明度，而不是一路加不透明度（那样会变成一条不透光的色纸）。
        let (runBase, runFg) = banner(hue: 0.14, baseSaturation: 1.00, alpha: bannerAlpha,
                                      panelLum: panelLum, envSat: envSat, tint: tint)
        let (doneBase, doneFg) = banner(hue: 0.38, baseSaturation: 0.85, alpha: bannerAlpha,
                                        panelLum: panelLum, envSat: envSat, tint: tint)

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
        let alertTextH = height(alert, innerWidth)
        let alertH = alertTextH + Look.bandPad * 2        // 色带：文字上下各留 bandPad
        let headH = height(head, innerWidth)
        let bodyH = height(body, innerWidth - 10)
        let footH = height(foot, innerWidth)

        let wanted = alertH + gap + headH + gap + bodyH + (footH > 0 ? gap + footH : 0) + Look.inset
        let total = min(max(wanted, 96), maxHeight)
        let stepsH = max(28, total - alertH - gap - headH - gap - (footH > 0 ? gap + footH : 0) - Look.inset)

        let oldTop = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.origin.x, y: panel.frame.origin.y,
                              width: Look.width, height: total), display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: Look.width, height: total)
        blurView.frame = panel.contentView?.bounds ?? .zero
        containerView.frame = panel.contentView?.bounds ?? .zero

        // 色带通栏；文字在自己的高度里居中 —— 不再靠段落间距去"顶"，那是顶不下来的。
        alertBand.frame = NSRect(x: 0, y: total - alertH, width: Look.width, height: alertH)
        alertField.frame = NSRect(x: 0, y: total - alertH + Look.bandPad,
                                  width: Look.width, height: alertTextH)
        headerField.frame = NSRect(x: Look.inset, y: total - alertH - gap - headH,
                                   width: innerWidth, height: headH)
        stepsScroll.frame = NSRect(x: Look.inset, y: Look.inset + (footH > 0 ? footH + gap : 0),
                                   width: innerWidth, height: stepsH)
        stepsField.frame = NSRect(x: 0, y: 0, width: innerWidth - 10, height: max(bodyH, stepsH))
        footerField.frame = NSRect(x: Look.inset, y: Look.inset, width: innerWidth, height: footH)

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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)                 // 不出现在 Dock / ⌘Tab
let hud = HUD()
app.delegate = hud
app.run()
