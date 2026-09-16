/**
 * dsh-testhud —— 把自动测试的进展画在**被测界面之上**（置顶、鼠标穿透、不抢焦点）。
 *
 * 这是一个纯 Host 插件：注册一个模型可调用的工具 `test_hud`，向每个 session 的系统提示
 * 注入一小段约定，然后靠 `hud/testhud.swift` 编出来的那个浮层进程把进度显示出来。
 * 详细行为见 README.md / README.zh.md。
 */
import { defineTool } from '@deepseek-ai/dsh-tools'
import { ANCHORS, PROGRESS_FILE, runAction } from './hud.js'

export const name = 'dsh-testhud'

/** 宿主必须提供的两个注册表：工具、系统提示分区。 */
export const inject = ['tools', 'systemPrompt']

/** 注入到每个 session 的约定：什么时候用、怎么用。 */
const GUIDANCE = '本机已安装 dsh-testhud 插件（自动测试的屏幕浮层）：跑任何超过十几秒的自动化验证'
  + '（GUI 驱动、截图比对、批量渲染）时，用 `test_hud` 工具把进展画在被测界面之上——'
  + 'action:"start" 先说明这次测什么、测谁；每个断言 action:"step" 一次，写清**期待**与**实际**；'
  + '需要时 action:"note" 补一行；结束时 action:"done" 给结论。'
  + '浮层置顶、鼠标穿透、不抢焦点，头部常驻一行明确告诉等待的人**现在能不能动鼠标键盘**，'
  + '所以等待方不用反复问"还在跑吗、我能接手了吗"。'

const STEP_STATES = ['ok', 'fail', 'run', 'info']

export function apply(ctx, config = {}) {
  const settings = {
    announceToAgent: config.announceToAgent !== false,
    defaultAnchor: ANCHORS.includes(config.defaultAnchor) ? config.defaultAnchor : 'auto',
  }

  const tool = defineTool({
    name: 'test_hud',
    description:
      'Show an automated test\'s progress ON SCREEN, above the app under test (always-on-top, click-through, never steals focus): '
      + 'what is being tested, each step\'s expectation vs actual result, elapsed time, and whether the waiting human may take back the mouse/keyboard. '
      + 'Use it for any verification that takes more than ~10 seconds (GUI driving, screenshot comparison, batch rendering) instead of leaving the user waiting blind. '
      + 'Workflow: action:"start" (title + target; resets steps) → one action:"step" per assertion with expect + actual → optional action:"note" → action:"done" with the conclusion. '
      + 'The panel auto-sizes, scrolls its step list (header stays fixed), sits in the emptiest screen corner, and disappears ~12s after done. '
      + '中文：把自动测试的进展画在被测界面之上（标题/期待/实际/耗时/能否收回鼠标键盘）；超过十几秒的验证都用它。'
      + 'start 说明测什么测谁 → 每个断言一次 step（期待 + 实际）→ done 给结论。',
    parameters: {
      action: { type: 'string', required: true, enum: ['start', 'step', 'note', 'done', 'stop'], description: 'start 开一次测试并拉起浮层；step 上报一步；note 补一行说明；done 写结论并结束；stop 直接关掉浮层。' },
      title: { type: 'string', description: 'start：这次测试在测什么（一句话标题）。' },
      target: { type: 'string', description: 'start：被测对象——哪个 app / 窗口 / 页面 / 区域。' },
      anchor: { type: 'string', enum: ANCHORS, description: `start：浮层贴哪一角，默认 ${settings.defaultAnchor}（auto = 自动躲开其它窗口；测试对象正好在某角时显式指定）。` },
      name: { type: 'string', description: 'step：这一步在测什么。' },
      expect: { type: 'string', description: 'step：期待结果。' },
      actual: { type: 'string', description: 'step：实际结果（真实观测到的，不是"应该没问题"）。' },
      state: { type: 'string', enum: STEP_STATES, description: 'step：这一步的结果，默认 info（ok = ✅ 通过，fail = ❌ 失败，run = ⏳ 进行中）。' },
      text: { type: 'string', description: 'note：补充一行说明（显示在浮层底部）。' },
      failed: { type: 'boolean', description: 'done：这次测试是否有失败（有失败时浮层显示"已结束（有失败）"）。' },
      conclusion: { type: 'string', description: 'done：结论一行（显示在浮层底部）。' },
    },
    output: {
      schema: {
        type: 'object',
        additionalProperties: false,
        properties: {
          action: { type: 'string', required: true },
          hud: { type: 'string', required: true, enum: ['running', 'stopped', 'unavailable', 'no-source'] },
          steps: { type: 'integer', required: true },
          summary: { type: 'string', required: true },
        },
      },
      render: (_args, value) => [{ type: 'text', text: value.summary }],
    },
    // start 可能要现编浮层（swiftc 几秒到十几秒），给足预算。
    timeoutMs: 120_000,
    isConcurrencySafe: () => true,
    async execute(args) {
      return runAction(args.action, { ...args, anchor: args.anchor ?? settings.defaultAnchor })
    },
  })

  ctx.effect(() => ctx.tools.register(tool), 'dsh-testhud: test_hud tool')

  if (settings.announceToAgent) {
    ctx.effect(
      () => ctx.systemPrompt.section({ name: 'plugin:dsh-testhud', order: 175, text: GUIDANCE }),
      'dsh-testhud: agent guidance',
    )
  }
}

/** 供 CLI / 文档引用：进度文件的实际位置。 */
export { PROGRESS_FILE }
