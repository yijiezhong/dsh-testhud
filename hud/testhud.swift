// DSH 自动测试的屏幕浮层：把"正在测什么、期待什么、实际什么、跑到哪一步、跑了多久，
// 以及**现在能不能动鼠标键盘**"直接画在**被测界面之上**。
//
// 用法：testhud <进度文件.json> [锚点] [顶部让出高度]
//   锚点：auto（默认，自动挑最不挡的一个角）| top-left | top-right
//   顶部让出高度：两个角再往下让这么多点，用来躲开浏览器自己的标签栏/地址栏/收藏栏（默认 150）
//
// 版面按 CRAP 定规矩（Contrast / Repetition / Alignment / Proximity）：
//   · **Contrast**：彩色只留给"状态"这一个语义 —— 顶部控制权色带 + 步骤行首那一个字符。
//     其余层次全靠**灰度三级**（1.0 / 0.78 / 0.58）+ **字重四档**（heavy / bold / semibold / regular），
//     不靠字号（用户要求全部文字同一个字号）。
//   · **Repetition**：所有内容贴同一条左边界（inset）；间距只有三个值 —— 组间 14、步骤间 10、行内 2~4。
//   · **Alignment**：控制权色带通栏，文字用 headIndent 回到内容左边界；步骤的"期待/实际"用真正的
//     headIndent 缩进（不是空格 —— 比例字体下空格根本对不齐）。
//   · **Proximity**：头部（标题/对象/计时）一组、步骤一组、结论一组，组内紧、组间松。
//   · **位置**：只在**上边两个角**里挑 —— 用系统窗口列表算两个候选与最前窗口的遮挡面积，取小的那个；
//     底部两个角已取消：面板高度随步骤增长、高度变化时顶边不动，贴底时下半截会被屏幕下缘切掉。
//   · **大小**：随内容增减，到上限（屏幕可见高度的 62%）为止。
//   · **滚动**：只有步骤区滚动，**头部固定**；新步骤进来自动滚到底。
//   · **透明度**：面板底色 0.80 —— 白字在浅色背景（白色 PDF、浅色主题编辑器）上能不能读全靠它。
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

    /// 面板：**浅色磨砂** —— 系统模糊把底下糊匀，再压一层白。
    /// 浅底 + 深字是这个浮层最舒服的组合：颜色轻、不压眼（"柔、清新"），
    /// 而深色笔画压在半透明白上，边缘对比足、不发虚（"字要锐"）；白字压在深底上则容易发糊。
    /// 唯一要注意的是白色背景上缺边界，靠 1pt 深色描边 + 系统阴影分开。
    /// 深灰半透明（用户点名要的观感）：只压到"看得清、下面也看得见"的程度，不做模糊 ——
    /// 模糊会把下面的内容化成色块，那正是"看不到被测对象"的来源。
    /// 白背景上它落到中灰、深背景上接近纯黑，所以**文字必须自带衬底**（见 textPlate）。
    static let panelFill = NSColor(calibratedRed: 0.098, green: 0.106, blue: 0.125, alpha: 0.44)
    static let panelBorder = NSColor(calibratedWhite: 1.0, alpha: 0.14)

    // 同一字号（base），四档字重；层次另一半来自灰度。
    static let alertFont = NSFont.systemFont(ofSize: base, weight: .heavy)      // 控制权色带
    static let titleFont = NSFont.systemFont(ofSize: base, weight: .bold)       // 标题
    static let stepFont = NSFont.systemFont(ofSize: base, weight: .semibold)    // 步骤名 / 结论
    static let bodyFont = NSFont.systemFont(ofSize: base, weight: .regular)     // 期待 / 实际 / 测试对象
    /// 计时用等宽数字：秒数跳动时不会左右抖。
    static let metaFont = NSFont.monospacedDigitSystemFont(ofSize: base, weight: .regular)

    // 控制权色带：两套方案共用（它本身就是"状态信号"，不该跟着背景变）。
    /// 黄=别动鼠标键盘，绿=可以接手；黑字压在亮底上约 13:1。
    /// 色带上的字（底色与它的透明度由 Theme 按环境算）。
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


/// 一整套视觉参数：颜色 + 四个由环境算出来的透明度。
struct Palette {
    let panelFill: NSColor
    let panelBorder: NSColor
    let primary: NSColor
    let secondary: NSColor
    let textPlate: NSColor
    let alertRunBg: NSColor
    let alertDoneBg: NSColor
    let stateOk: NSColor
    let stateBad: NSColor
    let stateRun: NSColor
    let stateInfo: NSColor
}

/// 变色龙：**颜色和透明度全部由"面板将要盖住的那块区域有多亮"算出来**，没有第二套预设。
///
/// 两条要求互相拉扯 —— 面板越透，被挡住的东西越看得清；可面板里的字就越没着落。所以把它们分给不同的层：
///   · **面板底尽量透**（`fillAlpha = 0.10`）—— 直接服务于"被遮挡的区域也看得清"；
///   · **文字的衬底反解到刚好够读**（`solveAlpha`）—— 服务于"面板内的信息不费力"。
/// 文字自带衬底之后，面板底只剩"整体感"这点职责，于是可以放心压到很透。
///
/// 底板**逐行**给，只包住文字本身 —— 这是空间上的取舍，不是审美选择：包住文字的像素，同时就是
/// 遮住后方文字的像素，两者是同一批像素。所以只能在**空间上**分配：文字处够实（够 AAA），其余处一律
/// 透明（后方内容照旧可见）。块级底板试过，读起来更连贯，但连行距一起盖住，后方那一整片就没了 —— 退回逐行。
///
/// 另一件事：底板**必须够实**。第一版解出来只有 0.72，透下来的内容在笔画间形成干扰，轻字重的小字最吃亏。
enum Theme {
    /// 面板底的不透明度：只留一点点，够暗示"这是一块面板"就行。
    /// 它是**唯一会成片盖住被测对象**的东西，所以压到最低 —— 遮挡面积主要留给文字自己的底板。
    /// 0.10 时背景文字会穿透（模糊层几何与图像都正常，但密集正文处仍能被读出），
    /// 所以用这个**必然生效**的层兜底：它是 CALayer 的底色，不像模糊那样依赖采样链路。
    /// 代价是遮挡从 10% 涨到 45% —— 想更透就往下调，想更干净就往上调。
    static let fillAlpha: CGFloat = 0.45
    // 目标一律写成**对比度**（WCAG 风格：(亮+0.05)/(暗+0.05)），不是"亮度差" ——
    // 这两者差得很远：0.6 的亮度差换算过来只有 ~1.6:1。
    // 目标按 **AAA**（18pt 属大字号，AAA 要 7:1）再**留一档余量**取 9 ——
    // 纸面 7:1 的东西在屏幕上量出来只有 6.6~6.8（中文笔画细，抗锯齿把实测亮度抬高了）。
    // 留余量顺带把衬底做得更实，透下来内容对它的干扰也更小。
    static let primaryContrast: CGFloat = 10     // 标题 / 步骤名 / 结论
    static let secondaryContrast: CGFloat = 12   // 期待 / 实际 / 元信息（实测比目标低一档，再留余量）
    static let alertContrast: CGFloat = 9        // 色带上的黑字

    static func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.deviceRGB) ?? color
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    /// 反解"要把这一层压/提到 `wanted` 亮度，它需要多不透明"：结果 = a×base + (1−a)×底下，解 a。
    /// 夹在 [0.30, 0.95] —— 下界保证这一层还看得见，上界保证它不变成死板的实心块。
    static func solveAlpha(over under: CGFloat, base: CGFloat, wanted: CGFloat) -> CGFloat {
        guard abs(base - under) > 0.01 else { return 0.75 }
        return min(0.98, max(0.30, (wanted - under) / (base - under)))
    }

    /// "亮度 text 的文字要够 `contrast`，衬底该落在什么亮度"。
    /// `darker` 指衬底在文字的暗侧（白字配暗底）；否则在亮侧（深字配亮底）。
    static func plateLum(text: CGFloat, contrast: CGFloat, darker: Bool) -> CGFloat {
        darker ? (text + 0.05) / contrast - 0.05
               : (text + 0.05) * contrast - 0.05
    }

    static func palette(for backdrop: CGFloat) -> Palette {
        // 关键在方向：面板与背景**同向**，不是相反 —— 浅背景配更浅的面板 + 深字，
        // 深背景配更深的面板 + 白字。方向对了以后，0.10 的不透明度就足以把对比推过 AAA，
        // 于是不需要任何"文字底板"：面板几乎全透，后方内容照旧看得见。
        // （反着来才需要不透明的底板去救 —— 那正是"遮挡太重"的来源。）
        let lightPanel = backdrop > 0.35
        let fillBase = lightPanel ? NSColor.white : NSColor(calibratedWhite: 0.02, alpha: 1)
        let fillAlpha: CGFloat = 0.10

        let primary = lightPanel ? NSColor(calibratedWhite: 0.06, alpha: 1) : NSColor.white
        // 没有底板之后，两级的对比只能靠**颜色本身**拉开 —— secondaryContrast 那类目标解的是底板的不透明度，
        // 底板没了它们就不起作用（踩过：把目标提到 12 实测仍是 4.1）。所以这里直接往极端压。
        let secondary = lightPanel ? NSColor(calibratedWhite: 0.08, alpha: 1)
                                   : NSColor(calibratedWhite: 0.90, alpha: 1)

        let runBase = NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.00, alpha: 1)
        let doneBase = NSColor(calibratedRed: 0.16, green: 0.80, blue: 0.38, alpha: 1)
        let panelLum = fillAlpha * luminance(fillBase) + (1 - fillAlpha) * backdrop
        let alertFloor = plateLum(text: 0.06, contrast: alertContrast, darker: false)
        let runAlpha = solveAlpha(over: panelLum, base: luminance(runBase), wanted: alertFloor)
        let doneAlpha = solveAlpha(over: panelLum, base: luminance(doneBase), wanted: alertFloor)

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
            textPlate: NSColor.clear,
            alertRunBg: runBase.withAlphaComponent(runAlpha),
            alertDoneBg: doneBase.withAlphaComponent(doneAlpha),
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
    private var placed = false
    /// 当前用哪套配色。默认按"浅背景"起手，第一次采样之后就会纠正。
    /// 最后一次量到的背景亮度 —— 整套配色（颜色 + 四个透明度）都由它推出来。
    /// 最后一次量到的背景亮度。-1 是"还没量过"的哨兵 —— 用 0.95 之类当初始值会让第一次采样
    /// 因"变化不够 4%"被判为没变化，配色和底图就永远不应用（踩过）。
    private var backdrop: CGFloat = -1
    /// 上一次采样的面板尺寸。面板长高/缩短时底图必须重采 —— 只比亮度的话，同一背景下面板变高
    /// 不会触发重采，多出来的下半截就没有模糊覆盖（踩过）。
    private var sampledSize: NSSize = .zero
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

        // 只有一层半透明白 + 内容，**不做模糊** —— 用户要的是看清下面压着什么，
        // 模糊会把内容糊成色块，那正是"看不到被测对象"的来源。
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
        // 显示之前先量一次（这一帧不闪），之后每 2 秒实时跟着背景走：配色与透明度都自动调。
        refreshTheme()
        themeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
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

        if !placed {
            placed = true
            panel.setFrameOrigin(origin(for: NSSize(width: Look.width, height: total), on: screen))
        } else {
            panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: oldTop - total))
        }
        panel.invalidateShadow()
    }

    private func refreshTheme() {
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
                let ci = CIImage(cgImage: cropped)
                    .applyingGaussianBlur(sigma: 26)
                    .applyingFilter("CIColorControls", parameters: [
                        // 背景压到几乎纯色：模糊在稀疏处够用（面板内实测 stddev 0.2~6.5），
                        // 但密集正文处仍有字形残留，与其继续猜模糊强度，不如直接把它压平 —— 零遮挡代价。
                        kCIInputContrastKey: 0.15,
                        kCIInputSaturationKey: 0.55,
                    ])
                blurred = CIContext().createCGImage(ci, from: ci.extent)
            }
            return (luminance, blurred)
        } catch {
            FileHandle.standardError.write("testhud: SCK error \(error)\n".data(using: .utf8)!)
            return nil
        }
    }

    /// 换配色：面板色直接改 layer，文字靠重画。
    private func applyPalette() {
        FileHandle.standardError.write("testhud: blur=\(blurView.frame) img=\(blurView.image?.size ?? .zero) root=\(panel.contentView?.frame ?? .zero) panel=\(panel.frame.size)\n".data(using: .utf8)!)
        FileHandle.standardError.write(String(format: "testhud: apply backdrop=%.3f textLum=%.2f plateAlpha=%.2f fillAlpha=%.2f\n",
                                             backdrop, Theme.luminance(palette.primary),
                                             palette.textPlate.alphaComponent,
                                             palette.panelFill.alphaComponent).data(using: .utf8)!)
        containerView.layer?.backgroundColor = palette.panelFill.cgColor
        containerView.layer?.borderColor = palette.panelBorder.cgColor
        alertBand.layer?.backgroundColor = alertBackgroundNow().cgColor
        // 块级底板：头部 / 步骤区 / 结论各铺一块连续的底（含块内行距），读起来是一块信息，
        // 而不是一行一条的横条码。面板底仍然只有 0.10，三块之间的间距也照旧透明。
        // 逼 render() 重画文字。注意光把 fingerprint 清掉还不够：attributedStringValue 的**文字内容**
        // 没变、只有颜色变了时，AppKit 可能判定"没变化"而不重绘（踩过 —— 面板底换了、字还是旧颜色）。
        // 所以再显式 needsDisplay 一次。
        lastFingerprint = ""
        render()
        for field in [alertField, headerField, stepsField, footerField] {
            field?.needsDisplay = true
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
