/**
 * 浮层本体：进度文件 + HUD 进程（编译、启动、停止）。
 *
 * 进度文件沿用与 `tools/testhud.sh`（AICode 仓库里那个 bash 版）**完全相同的 schema**，
 * 所以先写脚本、后用插件的流程能接着跑，谁写的都读得懂：
 *
 *   { title, target, status: "running"|"done"|"failed", startedAt, steps: [...], note }
 *
 * 浮层进程结束后（`done` 起 12 秒）自己退出，这里不用定时器去杀。
 */
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const PKG_DIR = dirname(dirname(fileURLToPath(import.meta.url)))
const HUD_SOURCE = join(PKG_DIR, 'hud', 'testhud.swift')

/** 插件自己的状态目录（编译产物 + 可选的进度文件覆盖）。 */
export const STATE_DIR = process.env.DSH_TESTHUD_HOME ?? join(homedir(), '.dsh', 'dsh-testhud')
/** 进度文件：默认与 bash 版共用同一个，机器上只有一个浮层，谁都能往上写。 */
export const PROGRESS_FILE = process.env.DSH_TESTHUD_FILE ?? join(homedir(), '.dsh', 'test-progress.json')
export const HUD_BIN = join(STATE_DIR, 'bin', 'testhud')

/** 三个靠上的位置，按"不挡被测对象"之外的优先级排：居中 > 左 > 右（见 testhud.swift）。 */
export const ANCHORS = ['auto', 'center', 'left', 'right']

/**
 * 浮层顶边往下让出多少点（躲开浏览器自己的标签栏/地址栏/收藏栏）。
 * 想让浮层跟 DeepSeek 页面 logo 齐平就调这个值（屏幕顶部算起），
 * 可用配置项 `topInset` 或环境变量 `DSH_TESTHUD_TOP_INSET` 覆盖。
 */
export const TOP_INSET = (() => {
  const raw = Number(process.env.DSH_TESTHUD_TOP_INSET)
  return Number.isFinite(raw) && raw >= 0 ? raw : 155
})()

/** 读进度文件；没有或坏了都当"还没有进度"。 */
export function readProgress() {
  try {
    const parsed = JSON.parse(readFileSync(PROGRESS_FILE, 'utf8'))
    return parsed && typeof parsed === 'object' ? parsed : null
  } catch {
    return null
  }
}

function writeProgress(value) {
  mkdirSync(dirname(PROGRESS_FILE), { recursive: true })
  const tmp = `${PROGRESS_FILE}.tmp`
  writeFileSync(tmp, JSON.stringify(value), 'utf8')
  renameSync(tmp, PROGRESS_FILE)
}

/**
 * 保证浮层二进制在、且不比源码旧。
 * 编译要 Xcode 命令行工具（macOS 上 `swiftc`）；没有就如实报告，进度照样记。
 */
export function ensureBinary() {
  if (!existsSync(HUD_SOURCE)) return { ok: false, reason: `浮层源码缺失：${HUD_SOURCE}` }
  try {
    if (existsSync(HUD_BIN) && statSync(HUD_BIN).mtimeMs >= statSync(HUD_SOURCE).mtimeMs) {
      return { ok: true, path: HUD_BIN, compiled: false }
    }
  } catch { /* 读不了就当需要重编 */ }

  mkdirSync(dirname(HUD_BIN), { recursive: true })
  const build = spawnSync('swiftc', ['-O', HUD_SOURCE, '-o', HUD_BIN], { encoding: 'utf8' })
  if (build.error) return { ok: false, reason: `编译浮层失败：${build.error.message}（需要 Xcode 命令行工具，装一个：xcode-select --install）` }
  if (build.status !== 0) return { ok: false, reason: `编译浮层失败：${(build.stderr || '').trim().split('\n').slice(-3).join(' / ')}` }
  return { ok: true, path: HUD_BIN, compiled: true }
}

function hudPids() {
  const out = spawnSync('pgrep', ['-f', `${HUD_BIN} `], { encoding: 'utf8' })
  if (out.status !== 0 || !out.stdout) return []
  return out.stdout.trim().split('\n').filter(Boolean)
}

export function isRunning() {
  return hudPids().length > 0
}

/** 关掉正在跑的浮层（幂等）。 */
export function stopHud() {
  const pids = hudPids()
  for (const pid of pids) {
    try { process.kill(Number(pid), 'SIGTERM') } catch { /* 已经没了 */ }
  }
  return pids.length
}

/**
 * 拉起浮层：同一时刻只留一个，所以先停旧的再起。
 * `anchor` 决定放哪个角（auto = 躲开其它窗口）。
 */
export function startHud(anchor = 'auto', topInset = TOP_INSET) {
  const bin = ensureBinary()
  if (!bin.ok) return { running: false, reason: bin.reason }
  stopHud()
  const child = spawn(bin.path, [PROGRESS_FILE, anchor, String(topInset)], { detached: true, stdio: 'ignore' })
  child.unref()
  return { running: true, bin: bin.path, compiled: bin.compiled === true, pid: child.pid, anchor, topInset }
}

/** 一行话说明浮层现在什么状态，给工具回执用。 */
export function hudState() {
  if (isRunning()) return 'running'
  if (!existsSync(HUD_SOURCE)) return 'no-source'
  return 'stopped'
}

// MARK: - 进度写入（工具与 CLI 共用）

const STEP_STATES = ['ok', 'fail', 'run', 'info']

/** `start`：新开一次测试，重置步骤。返回给模型看的回执。 */
export function actionStart({ title, target = '', anchor = 'auto', topInset = TOP_INSET } = {}) {
  if (!title || !String(title).trim()) throw new Error('start 需要 title（这次测试在测什么）')
  const hud = startHud(anchor, topInset)
  writeProgress({
    title: String(title).trim(),
    target: String(target ?? '').trim(),
    status: 'running',
    startedAt: Date.now() / 1000,
    steps: [],
    note: '',
  })
  return {
    action: 'start',
    hud: hud.running ? 'running' : 'unavailable',
    steps: 0,
    summary: hud.running
      ? `浮层已显示在屏幕上（位置 ${anchor}）：${title}${target ? ` ｜ 测试对象：${target}` : ''}。跑的过程中每步用 test_hud(action:"step") 上报期待与实际，结束时用 action:"done"。`
      : `进度已记录，但屏幕浮层没起来：${hud.reason}。你可以继续测试，结束时 action:"done" 仍会留下结论。`,
  }
}

export function actionStep({ name, expect = '', actual = '', state = 'info' } = {}) {
  if (!name || !String(name).trim()) throw new Error('step 需要 name（这一步在测什么）')
  const stepState = STEP_STATES.includes(state) ? state : 'info'
  const progress = readProgress()
  if (!progress) throw new Error('还没有正在进行的测试：先调用 test_hud(action:"start", title:"…")')
  progress.steps = Array.isArray(progress.steps) ? progress.steps : []
  progress.steps.push({
    name: String(name).trim(),
    expect: String(expect ?? ''),
    actual: String(actual ?? ''),
    state: stepState,
  })
  writeProgress(progress)
  const mark = { ok: '✅', fail: '❌', run: '⏳', info: '•' }[stepState]
  return {
    action: 'step',
    hud: hudState(),
    steps: progress.steps.length,
    summary: `${mark} 第 ${progress.steps.length} 步已上报：${name}${expect ? ` ｜ 期待：${expect}` : ''}${actual ? ` ｜ 实际：${actual}` : ''}`,
  }
}

export function actionNote({ text } = {}) {
  const progress = readProgress()
  if (!progress) throw new Error('还没有正在进行的测试：先调用 test_hud(action:"start", …)')
  progress.note = String(text ?? '')
  writeProgress(progress)
  return { action: 'note', hud: hudState(), steps: (progress.steps ?? []).length, summary: `已补一行说明：${progress.note}` }
}

/** `done`：写结论、把状态标成完成或失败；浮层自己再停 12 秒让人看清。 */
export function actionDone({ failed = false, conclusion = '' } = {}) {
  const progress = readProgress()
  if (!progress) throw new Error('还没有正在进行的测试：先调用 test_hud(action:"start", …)')
  progress.status = failed === true ? 'failed' : 'done'
  progress.note = String(conclusion ?? '')
  writeProgress(progress)
  const failedSteps = (progress.steps ?? []).filter((s) => s.state === 'fail').length
  return {
    action: 'done',
    hud: hudState(),
    steps: (progress.steps ?? []).length,
    summary: `测试结束（${failed === true || failedSteps > 0 ? '有失败' : '全部通过'}）：共 ${(progress.steps ?? []).length} 步`
      + `${failedSteps > 0 ? `，其中 ${failedSteps} 步失败` : ''}${conclusion ? ` ｜ 结论：${conclusion}` : ''}。`
      + `浮层上已显示「✓ 已结束，可以收回鼠标键盘的控制权了」，12 秒后自动消失。`,
  }
}

export function actionStop() {
  const killed = stopHud()
  return { action: 'stop', hud: 'stopped', steps: (readProgress()?.steps ?? []).length, summary: killed > 0 ? '浮层已关闭（进度文件保留）' : '浮层本来就没在跑' }
}

/** 按 action 分发，工具与 CLI 共用一套。 */
export function runAction(action, args = {}) {
  switch (action) {
    case 'start': return actionStart(args)
    case 'step': return actionStep(args)
    case 'note': return actionNote(args)
    case 'done': return actionDone(args)
    case 'stop': return actionStop()
    default: throw new Error(`未知 action：${action}（可用：start / step / note / done / stop）`)
  }
}
