# dsh-testhud

把自动测试的进展**画在被测界面之上**的浮层：置顶、鼠标穿透、不抢焦点，配一个任何 session 都能直接调的 `test_hud` 工具。

![浮层长这样](assets/panel.png)

## 为什么要有它

agent 驱动 GUI、比对截图、批量渲染，一跑就是几分钟。这段时间里等的人什么都不知道：跑到第几步、这一步期待什么、
是不是已经失败了，以及最要紧的那个问题——**现在能不能动鼠标键盘了**。

这块浮层就回答这些，画在屏幕上、不抢焦点：

- **在测什么**：标题、测试对象、开始时间与已用时。
- **每一步的期待与实际**：一行一条，✅ / ❌ / ⏳ / •
- **常驻一行控制权提示**：跑的时候「🖱️⌨️ 正在进行：先别动鼠标键盘」，结束「✅ 已结束，可以收回鼠标键盘的控制权了」。
- **不碍事**：鼠标穿透、置顶、不进 Dock 也不进 ⌘Tab，并且自动挑屏幕上最空的角，尽量少盖住被测界面。

## 安装

```sh
dsh plugin --profile web add github:yijiezhong/dsh-testhud
```

新增的 bundle 行在启动时组合，所以**重启一次 profile**（插件市场里有重启按钮）。
之后该 profile 里的**每个 session** 都有 `test_hud` 工具，以及一小段"跑长测试要报进展"的系统提示约定。

卸载：

```sh
dsh plugin --profile web remove dsh-testhud
```

## agent 工具

| `action` | 作用 | 参数 |
| --- | --- | --- |
| `start` | 开一次测试并拉起浮层 | `title`（必填）、`target`、`anchor` |
| `step` | 上报一步 | `name`（必填）、`expect`、`actual`、`state` = `ok`/`fail`/`run`/`info` |
| `note` | 底部补一行说明 | `text` |
| `done` | 写结论、结束这次测试 | `failed`（布尔）、`conclusion` |
| `stop` | 立刻关掉浮层 | — |

浮层随内容长高（上限为屏幕可见高度的 62%），**只有步骤区滚动**、头部固定；`done` 之后再停 12 秒才消失，
够看清结论。

## 命令行

同一套逻辑、同一个进度文件，给 shell 脚本和 CI 用：

```sh
testhud start "Movable 工具栏布局自检" "Movable 主窗口" [anchor]
testhud step  "工具栏居中" "分组中心 == 窗口中心" "实测 962pt，居中" ok
testhud note  "剩下交给用户判断"
testhud done  ok "3 项检查全过"
testhud stop
testhud status
```

## 配置

在 profile 的 `cordis.patch.yml` 里按行 id 覆盖：

```yaml
- id: testhud
  config:
    announceToAgent: true     # 是否给每个 session 注入"长测试要报进展"的约定
    defaultAnchor: auto       # auto | top-left | top-right | bottom-left | bottom-right
```

## 依赖

- **一个提供 `@deepseek-ai/dsh-tools` 的 dsh 宿主**——0.1.x 的 harness 都可以。本包没有任何运行时依赖：
  `defineTool` 与 `ctx.*` 都由宿主提供。
- **浮层本体要 macOS**（AppKit）。进度文件与工具本身在哪都能用。
- **要 Xcode 命令行工具**（`swiftc`）：浮层在第一次使用时现编到 `~/.dsh/dsh-testhud/bin/testhud`（约一秒），
  之后复用——所以包里带的是源码，不是二进制。没有 `swiftc` 时工具照样记录每一步、照样给结论，
  只是如实告诉你"浮层没画出来"。

## 开发自测

```sh
# 用一个一次性 profile 验，别动你日常那个
dsh --profile hudtest --from-default-profile headless --dump-config > /dev/null
dsh plugin --profile hudtest add link:"$PWD"
dsh --profile hudtest --dump-config | grep -A2 testhud        # 行进了组合
dsh --profile hudtest "调用 test_hud：start / step / done"     # 真实 session 必须看得见并调得动这个工具
rm -rf ~/.dsh/profiles/hudtest                                # 收尾
```

`node_modules/@deepseek-ai/dsh-tools` 只在脱离 dsh 单独 `node lib/index.js` 冒烟测试时需要；在 dsh 进程里由宿主解析。
它不在发布内容里。

## 实现

```
lib/index.js      Cordis 宿主插件：注册 test_hud 工具 + 一段系统提示分区
lib/hud.js        进度文件（~/.dsh/test-progress.json）与浮层进程（编译 / 启动 / 停止）
hud/testhud.swift 浮层本体：无边框 NSPanel、.statusBar 层级、鼠标穿透，每 0.4 秒读一次进度文件
bin/testhud.js    同一套核心的命令行
```

进度文件就是朴素 JSON，谁都能写：

```json
{ "title": "…", "target": "…", "status": "running|done|failed", "startedAt": 1789518613.07,
  "steps": [{ "name": "…", "expect": "…", "actual": "…", "state": "ok|fail|run|info" }], "note": "…" }
```

## 限制

- **一台机器一块浮层**：进度文件是固定路径，两场测试同时跑会共用一块浮层，后写的覆盖先写的。
- 浮层按设计鼠标穿透，所以不能用鼠标拖动或关闭：要挪位置用 `anchor`，要它消失用 `stop` / `done`。
- 屏幕被全屏窗口占满时，四个角都压着东西，`auto` 会退到左上角；想让开正在测的区域就显式传 `anchor`。

## 许可

MIT
