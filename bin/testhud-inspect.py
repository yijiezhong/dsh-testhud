#!/usr/bin/env python3
"""观测工具：用浮层自己导出的 panel-frame.json 精确裁出面板区域，报告它的纹理与文字。

为什么需要它：判断"面板下的背景文字有没有透上来"时，工具侧一直靠 OCR 结果反推面板范围，
而面板的位置和尺寸都是动态的 —— 于是三次把面板外的内容（终端左半、浏览器标签页）当成了
"穿透文字"，得出误导性结论。这里改成读浮层写下的**精确几何**，不再猜。

用法：
    bin/testhud-inspect.py [--shot 已有截图.png] [--json]
"""

import json
import os
import re
import subprocess
import sys
from glob import glob

from collections import Counter

from PIL import Image, ImageStat

HOME = os.path.expanduser("~")
FRAME_FILE = f"{HOME}/.dsh/dsh-testhud/panel-frame.json"
PROGRESS_FILE = f"{HOME}/.dsh/test-progress.json"


def _lum(c):
    return (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255


def _contrast(a, b):
    la, lb = _lum(a), _lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def find_ocr():
    candidates = sorted(glob(f"{HOME}/Library/Caches/dsh-ios/bin/ocr/*/ocr"), reverse=True)
    return candidates[0] if candidates else None


def panel_rect(frame):
    """NS 坐标（原点左下，单位点）→ 截图物理像素（原点左上）。"""
    scale = frame.get("scale", 2)
    top_pt = frame["screenTop"] - (frame["y"] + frame["height"])
    left_pt = frame["x"] - frame.get("screenOriginX", 0)
    return (
        int(round(left_pt * scale)),
        int(round(top_pt * scale)),
        int(round((left_pt + frame["width"]) * scale)),
        int(round((top_pt + frame["height"]) * scale)),
    )


# 面板里代码写死的文案：不在进度文件里，但确实属于面板（色带、各行的前缀、状态行）。
FIXED_TEXT = [
    "DSH 自动测试",
    "正在进行：先别动鼠标键盘",
    "已结束，可以收回鼠标键盘的控制权",
    "已结束（有失败）",
    "已完成",
    "有失败",
    "测试对象：",
    "开始 ",
    "已用",
    "期待：",
    "实际：",
    "结论：",
]


def panel_strings():
    """面板自己的文字（用来区分 OCR 到的哪些行来自面板、哪些来自背景）。"""
    try:
        data = json.load(open(PROGRESS_FILE))
    except Exception:
        return list(FIXED_TEXT)
    out = [data.get("title", ""), data.get("target", ""), data.get("note", "")]
    for step in data.get("steps", []):
        out += [step.get("name", ""), step.get("expect", ""), step.get("actual", "")]
    return FIXED_TEXT + [s.strip() for s in out if s and len(s.strip()) >= 3]


def belongs(text, known):
    """OCR 的行是否属于面板自己的内容。
    用**任意连续 4 字片段**匹配，而不是整段前缀 —— OCR 常把个别字认错
    （实测把面板自己的"穿透检查"读成"穿透检査"，整段匹配就会误报成背景穿透）。"""
    flat = re.sub(r"\s+", "", text)
    for k in known:
        k2 = re.sub(r"\s+", "", k)
        if len(k2) < 3:                      # 短关键字（"开始"、"已用"）整段找
            if k2 in flat:
                return True
            continue
        n = min(3, len(k2))                  # 长关键字用 3-gram：OCR 认错一个字也能匹配上
        for i in range(len(k2) - n + 1):
            if k2[i:i + n] in flat:
                return True
    return False


def main():
    args = sys.argv[1:]
    shot = None
    if "--shot" in args:
        shot = args[args.index("--shot") + 1]

    if not os.path.exists(FRAME_FILE):
        print("找不到 panel-frame.json —— 浮层还没导出几何（先让它跑起来）")
        return 1
    frame = json.load(open(FRAME_FILE))
    age = __import__("time").time() - frame.get("updatedAt", 0)
    x0, y0, x1, y1 = panel_rect(frame)
    print(f"面板（由浮层导出，{age:.1f}s 前更新）")
    print(f"  点坐标 {frame['width']:.0f}x{frame['height']:.0f} @ ({frame['x']:.0f},{frame['y']:.0f})，缩放 {frame.get('scale')}x")
    print(f"  截图像素 x {x0}..{x1}  y {y0}..{y1}")

    if shot is None:
        shot = "/tmp/testhud-inspect.png"
        subprocess.run(["screencapture", "-x", shot], check=True)
    im = Image.open(shot).convert("RGB")
    if im.width < x1 or im.height < y1:
        print(f"  截图只有 {im.size}，裁不到面板区域")
        return 1

    # 环境自检放在最前面 —— 它是唯一挡住"测了半天其实压错了应用"的东西，
    # 而前面几轮栽的正是这个（忘了切前台、面板被避让规则推离文字区）。
    front = subprocess.run(
        ["osascript", "-e", 'tell application "System Events" to get name of first process whose frontmost is true'],
        capture_output=True, text=True).stdout.strip()
    print(f"前台应用: {front or '(读不到)'}   ← 面板应该压在它上面；不是你想测的那个就先切前台再跑")

    # 一、面板内的纹理：逐行算 stddev。面板自己的文字之间是大片被压平的底 —— 那里应该很平。
    crop = im.crop((x0, y0, x1, y1))
    gray = crop.convert("L")
    rows = []
    seg = 8
    for y in range(0, gray.height - seg, seg):
        band = gray.crop((0, y, gray.width, y + seg))
        rows.append(ImageStat.Stat(band).stddev[0])
    flat = [r for r in rows if r < 12]
    print("\n面板内纹理（每 8px 一行，数值 = 该行的明暗标准差）")
    print(f"  低方差行占比 {len(flat)/max(1,len(rows))*100:.0f}%   中位数 {sorted(rows)[len(rows)//2]:.1f}   最高 {max(rows):.1f}")
    print("  （面板文字之间的底应该很平；这里的低方差行占比就是'背景被压平'的程度）")
    median = sorted(rows)[len(rows) // 2]
    if median < 8:
        print("  ⚠️ 面板内几乎没有纹理 —— 底下是纯色区域，这次测不出'面板文字与背景文字叠加'的问题")

    # 二、面板内的文字：与面板自己的内容比对，不匹配的行很可能是从背景透上来的
    # 三、面板自己每一行的对比度（用 OCR 的行框，逐行量"文字 vs 它所在的那片底"）
    ocr = find_ocr()
    if ocr:
        out = subprocess.run([ocr, shot], capture_output=True, text=True)
        try:
            items = json.loads(out.stdout)["items"]
        except Exception:
            items = []
        inside = [i for i in items if x0 <= i["x"] <= x1 and y0 <= i["y"] <= y1]
        known = panel_strings()
        foreign = [i for i in inside if not belongs(i["text"], known)]
        print(f"\n面板内的文字（OCR）")
        print(f"  共 {len(inside)} 行，其中属于面板自己的 {len(inside)-len(foreign)} 行")
        if len(inside) == 0:
            print("  ⚠️ 面板区域内一行文字都没读到 —— 面板可能根本没显示在这个位置（先核对浮层是否在跑）")
        print(f"  不属于面板内容的（= 从背景透上来的嫌疑）: {len(foreign)} 行")
        mine_n = len(inside) - len(foreign)
        if len(foreign) > 5 and len(foreign) > mine_n:
            print("  ⚠️ 背景文字比面板自己的还多 —— 多半是压错了应用：先看上面那行'前台应用'")
        for i in sorted(foreign, key=lambda i: i["y"])[:8]:
            print(f"    y={i['y']:5d}  {i['text'][:56]}")

        mine = [i for i in inside if belongs(i["text"], known)]
        print("\n面板自己每一行的对比度")
        worst, worst_text = 99.0, ""
        for i in sorted(mine, key=lambda i: i["y"]):
            bx0, by0 = max(0, i["x"] - 2), max(0, i["y"] - 2)
            bx1, by1 = min(im.width, i["x"] + i["w"] + 2), min(im.height, i["y"] + i["h"] + 2)
            px = [im.getpixel((x, y)) for y in range(by0, by1) for x in range(bx0, bx1)]
            if not px:
                continue
            plate = Counter(px).most_common(1)[0][0]
            core = sorted(px, key=lambda c: abs(_lum(c) - _lum(plate)), reverse=True)[:max(4, len(px) // 50)]
            text = tuple(sum(c[k] for c in core) // len(core) for k in range(3))
            r = _contrast(plate, text)
            if r < worst:
                worst, worst_text = r, i["text"][:36]
            mark = "AAA" if r >= 7 else ("AA" if r >= 4.5 else "低")
            print(f"  {mark:>3}  {r:5.1f}:1  {i['text'][:40]}")
        if worst < 99:
            print(f"  最低 {worst:.1f}:1  ← {worst_text}")
    else:
        print("\n（没找到 OCR 工具，跳过文字比对）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
