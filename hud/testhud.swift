// DSH 自动测试的屏幕浮层：把"正在测什么、期待什么、实际什么、跑到哪一步、跑了多久，
// 以及**现在能不能动鼠标键盘**"直接画在**被测界面之上**。
//
// 用法：testhud <进度文件.json> [锚点]
//   锚点：auto（默认，自动挑最不挡的一个角）| top-left | top-right | bottom-left | bottom-right
//
// 四条布局约定（按用户要求）：
//   · **位置**：尽量放空白处 —— 用系统窗口列表算四个角与最前窗口的遮挡面积，取最小的那个，
//     所以它会躲开被测窗口；也可以用锚点参数强制指定。
//   · **大小**：随内容增减（步骤多了长高、少了缩回），到上限（屏幕可见高度的 62%）为止。
//   · **滚动**：只有步骤区滚动，**头部固定**（标题/状态/测试对象/控制权提示/计时）；
//     新步骤进来自动滚到底，看历史往上滚。
//   · **透明度**：面板底色 0.58，压得住背景但不挡视线；鼠标穿透，永远不影响操作。
//
// 进度文件由 `tools/testhud.sh` 写（bash + python3 拼 JSON，不引任何依赖）。
import AppKit
import Foundation

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

// MARK: - 尺寸与样式

private enum Look {
    static let width: CGFloat = 560
    static let inset: CGFloat = 14              // 面板内边距
    static let screenMargin: CGFloat = 14       // 离屏幕边缘
    static let maxHeightRatio: CGFloat = 0.62   // 最多占屏幕可见高度的 62%
    static let bgAlpha: CGFloat = 0.58          // 用户要求"浅一点"
    static let cornerRadius: CGFloat = 12

    static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let stateFont = NSFont.systemFont(ofSize: 13, weight: .bold)
    static let handoffFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let metaFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let stepFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let detailFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let style: NSMutableParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        return p
    }()

    static let dim = NSColor(calibratedWhite: 0.80, alpha: 1)
    static let bright = NSColor.white
    static let ok = NSColor(calibratedRed: 0.45, green: 0.92, blue: 0.55, alpha: 1)
    static let bad = NSColor(calibratedRed: 1, green: 0.5, blue: 0.45, alpha: 1)
    static let warn = NSColor(calibratedRed: 1, green: 0.82, blue: 0.35, alpha: 1)
    static let info = NSColor(calibratedRed: 0.55, green: 0.82, blue: 1, alpha: 1)
}

// MARK: - 浮层

final class HUD: NSObject, NSApplicationDelegate {
    private var panel: NSPanel!
    private var headerField: NSTextField!        // 固定不滚
    private var stepsScroll: NSScrollView!
    private var stepsField: NSTextField!
    private var footerField: NSTextField!
    private var timer: Timer?
    private var doneSince: Date?
    private var lastFingerprint = ""
    private var placed = false

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Look.width, height: 96),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.level = .statusBar                    // 盖在被测应用之上
        panel.ignoresMouseEvents = true             // 鼠标穿透：不挡操作
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Look.width, height: 96))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: Look.bgAlpha).cgColor
        container.layer?.cornerRadius = Look.cornerRadius
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor

        headerField = makeField()
        footerField = makeField()
        stepsField = makeField()

        stepsScroll = NSScrollView(frame: .zero)
        stepsScroll.drawsBackground = false
        stepsScroll.hasVerticalScroller = true
        stepsScroll.autohidesScrollers = true
        stepsScroll.scrollerStyle = .overlay
        stepsScroll.documentView = stepsField

        container.addSubview(headerField)
        container.addSubview(stepsScroll)
        container.addSubview(footerField)
        panel.contentView = container
        panel.orderFrontRegardless()

        render()
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
        f.drawsBackground = false
        f.lineBreakMode = .byWordWrapping
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        return f
    }

    // MARK: 渲染

    private func render() {
        guard let data = FileManager.default.contents(atPath: progressPath),
              let p = try? JSONDecoder().decode(Progress.self, from: data) else { return }

        let head = composeHeader(p)
        let body = composeSteps(p)
        let foot = composeFooter(p)
        let fingerprint = head.string + body.string + foot.string
        let finished = (p.status == "done" || p.status == "failed")

        if fingerprint != lastFingerprint {
            lastFingerprint = fingerprint
            headerField.attributedStringValue = head
            stepsField.attributedStringValue = body
            footerField.attributedStringValue = foot
            layout(head: head, body: body, foot: foot)
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

    /// 按内容算高度并摆好三块：头部固定、步骤区滚动、页脚固定；高度变化时**顶边不动**
    private func layout(head: NSAttributedString, body: NSAttributedString, foot: NSAttributedString) {
        guard let screen = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        let maxHeight = screen.height * Look.maxHeightRatio
        let innerWidth = Look.width - Look.inset * 2

        func height(_ s: NSAttributedString, _ w: CGFloat) -> CGFloat {
            guard s.length > 0 else { return 0 }
            return ceil(s.boundingRect(with: NSSize(width: w, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        }
        let headH = height(head, innerWidth)
        let bodyH = height(body, innerWidth - 10)
        let footH = height(foot, innerWidth)
        let gap: CGFloat = 8

        let wanted = Look.inset * 2 + headH + gap + bodyH + (footH > 0 ? gap + footH : 0)
        let total = min(max(wanted, 96), maxHeight)
        let stepsH = max(28, total - Look.inset * 2 - headH - (footH > 0 ? gap + footH : 0) - gap)

        let oldTop = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.origin.x, y: panel.frame.origin.y,
                              width: Look.width, height: total), display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: Look.width, height: total)

        headerField.frame = NSRect(x: Look.inset, y: total - Look.inset - headH,
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

    private func scrollStepsToBottom() {
        let clip = stepsScroll.contentView
        let maxY = max(0, stepsField.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: maxY))
        stepsScroll.reflectScrolledClipView(clip)
    }

    // MARK: 文案

    private func composeHeader(_ p: Progress) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ s: String, _ font: NSFont, _ color: NSColor) {
            out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color,
                                                                  .paragraphStyle: Look.style]))
        }
        let status = p.status ?? "running"
        add("DSH 自动测试  ", Look.stateFont, Look.info)
        switch status {
        case "done":   add("● 已完成\n", Look.stateFont, Look.ok)
        case "failed": add("● 有失败\n", Look.stateFont, Look.bad)
        default:       add("● 进行中\n", Look.stateFont, Look.warn)
        }
        add(p.title + "\n", Look.titleFont, Look.bright)
        if let t = p.target, !t.isEmpty { add("测试对象：" + t + "\n", Look.detailFont, Look.dim) }
        if let s = p.startedAt {
            let elapsed = Date().timeIntervalSince1970 - s
            add(String(format: "开始 %@   已用时 %.0f 秒\n", timeString(s), elapsed), Look.metaFont, Look.dim)
        }
        add("\n", Look.detailFont, Look.dim)
        // 用户最关心的那句：现在能不能动鼠标键盘
        add(handoffLine(status), Look.handoffFont, status == "running" ? Look.warn : Look.ok)
        return out
    }

    /// 控制权提示 —— **这是这块浮层存在的首要理由**：让人知道现在能不能碰鼠标键盘。
    private func handoffLine(_ status: String) -> String {
        switch status {
        case "done":   return "✅ 已结束，可以收回鼠标键盘的控制权了\n"
        case "failed": return "⚠️ 已结束（有失败），可以收回控制权；结论见下方\n"
        default:       return "🖱️⌨️ 正在进行：先别动鼠标键盘，以免打断测试\n"
        }
    }

    private func composeSteps(_ p: Progress) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ s: String, _ font: NSFont, _ color: NSColor) {
            out.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color,
                                                                  .paragraphStyle: Look.style]))
        }
        for (i, step) in (p.steps ?? []).enumerated() {
            let mark: String, color: NSColor
            switch step.state ?? "info" {
            // `ok` 与 `pass` 都是"这步过了"：bash 版脚本写的是 ok，别让它显示成灰点。
            case "pass", "ok": mark = "✅"; color = Look.ok
            case "fail":       mark = "❌"; color = Look.bad
            case "run":        mark = "⏳"; color = Look.warn
            default:           mark = "•";  color = Look.dim
            }
            add("\(mark) \(i + 1). " + step.name + "\n", Look.stepFont, color)
            if let e = step.expect, !e.isEmpty { add("     期待：" + e + "\n", Look.detailFont, Look.dim) }
            if let a = step.actual, !a.isEmpty { add("     实际：" + a + "\n", Look.detailFont, Look.dim) }
        }
        return out
    }

    private func composeFooter(_ p: Progress) -> NSAttributedString {
        guard let n = p.note, !n.isEmpty else { return NSAttributedString() }
        return NSAttributedString(string: "结论：" + n, attributes: [
            .font: Look.stepFont, .foregroundColor: Look.bright, .paragraphStyle: Look.style,
        ])
    }

    private func timeString(_ epoch: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: epoch))
    }

    // MARK: 位置：挑最不挡的那个角

    private func candidates(size: NSSize, on screen: NSRect) -> [(name: String, origin: NSPoint)] {
        let m = Look.screenMargin
        return [
            ("top-left",     NSPoint(x: screen.minX + m, y: screen.maxY - size.height - m)),
            ("top-right",    NSPoint(x: screen.maxX - size.width - m, y: screen.maxY - size.height - m)),
            ("bottom-left",  NSPoint(x: screen.minX + m, y: screen.minY + m)),
            ("bottom-right", NSPoint(x: screen.maxX - size.width - m, y: screen.minY + m)),
        ]
    }

    private func origin(for size: NSSize, on screen: NSRect) -> NSPoint {
        let cands = candidates(size: size, on: screen)
        if anchorArg != "auto", let hit = cands.first(where: { $0.name == anchorArg }) { return hit.origin }
        let windows = otherWindowsInScreenCoords()
        guard !windows.isEmpty else { return cands[3].origin }
        var best = cands[3], bestScore = CGFloat.greatestFiniteMagnitude
        for c in cands {
            let rect = NSRect(origin: c.origin, size: size)
            let score = windows.reduce(CGFloat(0)) { $0 + overlapArea(rect, $1) }
            if score < bestScore { bestScore = score; best = c }
        }
        return best.origin
    }

    private func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }

    /// 屏幕上其它应用的普通窗口。用 CGWindowList（**不需要辅助功能权限**），
    /// 并把"左上原点"的 CG 坐标换成 NSWindow 的"左下原点"。
    private func otherWindowsInScreenCoords() -> [NSRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        var out: [NSRect] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = w[kCGWindowOwnerPID as String] as? pid_t, owner != getpid(),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let x = b["X"] ?? 0, y = b["Y"] ?? 0, width = b["Width"] ?? 0, height = b["Height"] ?? 0
            guard width > 80, height > 80 else { continue }
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
