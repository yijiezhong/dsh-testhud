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

from PIL import Image, ImageStat

HOME = os.path.expanduser("~")
FRAME_FILE = f"{HOME}/.dsh/dsh-testhud/panel-frame.json"
PROGRESS_FILE = f"{HOME}/.dsh/test-progress.json"


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
    return FIXED_TEXT + [s.strip() for s in out if s and len(s.strip()) >= 4]


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

    # 二、面板内的文字：与面板自己的内容比对，不匹配的行很可能是从背景透上来的
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
        print(f"  不属于面板内容的（= 从背景透上来的嫌疑）: {len(foreign)} 行")
        for i in sorted(foreign, key=lambda i: i["y"])[:8]:
            print(f"    y={i['y']:5d}  {i['text'][:56]}")
    else:
        print("\n（没找到 OCR 工具，跳过文字比对）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
