// 用真实鼠标事件做一次拖拽 —— 验证"抓住色带移动面板"这类交互。
//
// 用法： swiftc -O -o /tmp/drag-mouse bin/drag-mouse.swift && /tmp/drag-mouse x1 y1 x2 y2
// 坐标是**全局屏幕坐标，左上原点**（和 CGEvent 一致），单位是点，不是像素。
//
// 为什么不用 cliclick：这台机器没装。为什么不用 python：系统 python3 没有 Quartz。
// Swift + CGEvent 是这里唯一开箱可用的路径，而且事件走 HID 层，和真人点击等效。
//
// 需要"辅助功能"权限：没有权限时 CGEvent 会被系统**静默丢弃**（不报错、位置不变），
// 所以调用方必须用 panel-frame.json 之类的观测数据确认结果，不能拿退出码当成功。

import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count == 5,
      let x1 = Double(args[1]), let y1 = Double(args[2]),
      let x2 = Double(args[3]), let y2 = Double(args[4]) else {
    FileHandle.standardError.write("usage: drag-mouse x1 y1 x2 y2\n".data(using: .utf8)!)
    exit(2)
}

func post(_ type: CGEventType, _ p: CGPoint) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type,
                        mouseCursorPosition: p, mouseButton: .left)
    event?.post(tap: .cghidEventTap)
}

post(.mouseMoved, CGPoint(x: x1, y: y1))
usleep(250_000)
post(.leftMouseDown, CGPoint(x: x1, y: y1))
usleep(250_000)

// 分步移动：一步到位的话，AppKit 可能只看到一个巨大的 delta，
// 而中间的 mouseDragged 序列才是真实拖拽的样子。
let steps = 24
for i in 1...steps {
    let t = Double(i) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: x1 + (x2 - x1) * t, y: y1 + (y2 - y1) * t))
    usleep(25_000)
}

post(.leftMouseUp, CGPoint(x: x2, y: y2))
print("dragged (\(x1),\(y1)) -> (\(x2),\(y2))")
