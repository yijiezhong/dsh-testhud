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

    // 控制权色带上的字：黄底（别动鼠标键盘）与绿底（可以接手）都是黑字。
    // 色带本身色相固定、明度按环境反解、不透明度钉在 0.55 —— 见 Theme.banner。
    static let alertRunFg = NSColor(calibratedWhite: 0.06, alpha: 1)
    static let alertDoneFg = NSColor(calibratedWhite: 0.06, alpha: 1)

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


/// 一整套视觉参数：颜色 + 面板底的不透明度（由环境反解，见 `Theme.palette(for:)`）。
struct Palette {
    let panelFill: NSColor
    let panelBorder: NSColor
    let primary: NSColor
    let secondary: NSColor
    let alertRunBg: NSColor
    let alertDoneBg: NSColor
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
    // **不复用那套"解到刚好 N:1"的对比度目标** —— 底板删掉之后它就没有作用对象了（踩过：
    // 把目标从 9 提到 12，实测仍是 4.1:1，因为解的是底板的不透明度，而底板已经不存在）。
    // 两级灰现在直接取极端值（见 palette）。教训记在这儿：纸面 7:1 的东西在屏幕上量出来只有
    // 6.6~6.8 —— 中文笔画细、抗锯齿把实测亮度抬高了，所以"刚好 7:1"的方案实测永远不够。
    /// 色带上黑字的对比目标。这里**故意只取 AAA 对大字号的门槛（4.5）**，不跟着文字一起上 9 ——
    /// 黄底为了 9:1 得压到亮度 0.94，而黄色本身只有 0.77，解出来的不透明度会超过 1（被夹到 0.98，
    /// 成了一条不透光的色纸，把后面的文字全挡掉）。取 4.5 时解出来正好是半透明，后面的字还能看见。
    static let alertContrast: CGFloat = 4.5
    /// 色带的不透明度：钉住不动（用户要求"能看到后面的文字"）；明度不够时去调明度。
    static let bannerAlpha: CGFloat = 0.55

    /// 色带的一层：固定色相与不透明度，**明度反解**到"上面的黑字刚好够 `alertContrast`"。
    /// 面板本来就够亮时它自然变暗（那时黑字在面板上已有对比，色带不必再亮）。
    static func banner(hue: CGFloat, saturation: CGFloat, alpha: CGFloat, panelLum: CGFloat) -> NSColor {
        let floor = plateLum(text: 0.06, contrast: alertContrast, darker: false)
        let needed = (floor - (1 - alpha) * panelLum) / max(0.05, alpha)
        return NSColor(calibratedHue: hue, saturation: saturation,
                       brightness: min(1.0, max(0.30, needed)), alpha: alpha)
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

    static func palette(for backdrop: CGFloat) -> Palette {
        // 关键在方向：面板与背景**同向**，不是相反 —— 浅背景配更亮的面板 + 深字，
        // 深背景配更暗的面板 + 白字。方向对了才轮到对比度；方向反了只能靠加不透明度去救，
        // 那正是"遮挡太重"的来源。
        let lightPanel = backdrop > 0.35
        let fillBase = lightPanel ? NSColor.white : NSColor(calibratedWhite: 0.02, alpha: 1)
        // 不透明度由"要把面板提到/压到目标的亮度"反解 —— 和配色一样是算出来的，不是常量。
        // 背景落在中灰时它提上去，把面板推离中灰；背景已经在两端时它落到 0.50 的下限（用户定的取舍）。
        let fillAlpha = solveAlpha(over: backdrop, base: luminance(fillBase),
                                   wanted: lightPanel ? lightPanelTarget : darkPanelTarget)

        let primary = lightPanel ? NSColor(calibratedWhite: 0.06, alpha: 1) : NSColor.white
        // 没有底板之后，两级的对比只能靠**颜色本身**拉开 —— "解到刚好 N:1"那类目标解的是
        // **底板**的不透明度，底板没了它就没有作用对象（踩过：把目标从 9 提到 12，实测仍是 4.1:1）。
        // 所以这里不设目标，直接往极端压。
        let secondary = lightPanel ? NSColor(calibratedWhite: 0.08, alpha: 1)
                                   : NSColor(calibratedWhite: 0.90, alpha: 1)

        let panelLum = fillAlpha * luminance(fillBase) + (1 - fillAlpha) * backdrop
        // 色带也交给"变色龙"：**色相**按状态固定（黄=别动、绿=可以接手，语义不能变），
        // **明度**由环境反解 —— 目标是"上面的黑字够 4.5:1"，不透明度钉在 0.55（后面的字要能看见）。
        // 明度不够就调明度，而不是一路加不透明度（那样会变成一条不透光的色纸）。
        let runBase = banner(hue: 0.14, saturation: 1.00, alpha: bannerAlpha, panelLum: panelLum)
        let doneBase = banner(hue: 0.38, saturation: 0.85, alpha: bannerAlpha, panelLum: panelLum)

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
    /// 上一次布局出来的面板高度。它一变就立刻重采底图 —— 否则要等下一个采样周期，
    /// 那段窗口里底图是旧尺寸的（被拉伸铺满，内容与当前区域不对应）。
    private var laidOutHeight: CGFloat = -1
    private var palette: Palette { Theme.palette(for: backdrop) }

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

        exportFrame(screen: screen)

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
        let previousSize = sampledSize
        let size = frame.size

        // 采样放**后台线程**：ScreenCaptureKit 的 async 调用和 @MainActor 会互等 ——
        // 症状是一条日志都不出、配色永远停在初始值（踩过）。采完再回主线程套用。
        Task.detached { [rect, displayID, exclude, previous, previousSize, size] in
            guard let (luminance, snapshot) = await Self.capturePanelArea(rect, displayID: displayID,
                                                                         excluding: exclude) else {
                FileHandle.standardError.write("testhud: sample FAILED\n".data(using: .utf8)!); return }
            FileHandle.standardError.write(String(format: "testhud: backdrop=%.3f\n", luminance).data(using: .utf8)!)
            // 亮度变化小于 4% 且面板尺寸没变就不重绘，免得背景稍微一动整个面板跟着抖。
            let sizeChanged = abs(size.height - previousSize.height) > 1 || abs(size.width - previousSize.width) > 1
            guard abs(luminance - previous) > 0.04 || sizeChanged else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.backdrop = luminance
                self.sampledSize = size
                if let snapshot { self.blurView.image = NSImage(cgImage: snapshot, size: .zero) }
                FileHandle.standardError.write("testhud: snapshot=\(snapshot == nil ? "nil" : "ok") view=\(self.blurView.image == nil ? "empty" : "set")\n".data(using: .utf8)!)
                self.applyPalette()
            }
        }
    }

    private static func capturePanelArea(_ rect: CGRect, displayID: CGDirectDisplayID?,
                                         excluding windowNumber: Int) async -> (CGFloat, CGImage?)? {
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
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let o = y * stride + x * bpp
                    let r = Double(data[o + 2]) / 255, g = Double(data[o + 1]) / 255, b = Double(data[o]) / 255
                    sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
                    count += 1
                }
            }
            let luminance = count > 0 ? sum / Double(count) : 0.5

            // 面板那块位置的一份**模糊快照** —— 它会成为面板的底。
            // 后方内容因此变成柔和的光斑：仍然看得出"下面有东西"，但不会和面板文字抢读。
            var blurred: CGImage?
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
                let blurredCI = ci.applyingGaussianBlur(sigma: 34)
                    .applyingFilter("CIColorControls", parameters: [
                        kCIInputContrastKey: 0.40,
                        kCIInputSaturationKey: 0.70,
                    ])
                blurred = CIContext().createCGImage(blurredCI, from: ci.extent)
            }
            return (luminance, blurred)
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
        let foreground = (status == "running") ? Look.alertRunFg : Look.alertDoneFg
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
