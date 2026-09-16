#!/usr/bin/env node
/**
 * `testhud` 命令行 —— 给 bash / make / CI 这类非模型流程用，和 `test_hud` 工具同一套逻辑、
 * 同一个进度文件，所以脚本和 agent 可以交替往上写。
 *
 *   testhud start "标题" "测试对象" [anchor]
 *   testhud step  "步骤名" "期待" "实际" [ok|fail|run|info]
 *   testhud note  "补充一行"
 *   testhud done  ok|fail ["结论一行"]
 *   testhud stop
 *   testhud status
 */
import { PROGRESS_FILE, hudState, readProgress, runAction } from '../lib/hud.js'

const [command = 'help', ...rest] = process.argv.slice(2)

function status() {
  const p = readProgress()
  if (!p) return console.log(`还没有进度：${PROGRESS_FILE}`)
  const steps = Array.isArray(p.steps) ? p.steps.length : 0
  console.log(`${p.status ?? '?'} ｜ ${steps} 步 ｜ 浮层 ${hudState()} ｜ ${p.title ?? ''}`)
  if (p.note) console.log(`结论：${p.note}`)
}

try {
  switch (command) {
    case 'start': {
      const [title, target = '', anchor = 'auto'] = rest
      console.log(runAction('start', { title, target, anchor }).summary)
      break
    }
    case 'step': {
      const [name, expect = '', actual = '', state = 'info'] = rest
      console.log(runAction('step', { name, expect, actual, state }).summary)
      break
    }
    case 'note':
      console.log(runAction('note', { text: rest.join(' ') }).summary)
      break
    case 'done': {
      const [verdict = 'ok', ...conclusion] = rest
      console.log(runAction('done', { failed: verdict !== 'ok', conclusion: conclusion.join(' ') }).summary)
      break
    }
    case 'stop':
      console.log(runAction('stop').summary)
      break
    case 'status':
      status()
      break
    default:
      console.log('用法：\n'
        + '  testhud start "标题" "测试对象" [anchor]\n'
        + '  testhud step  "步骤名" "期待" "实际" [ok|fail|run|info]\n'
        + '  testhud note  "补充一行"\n'
        + '  testhud done  ok|fail ["结论一行"]\n'
        + '  testhud stop\n'
        + '  testhud status')
      if (command !== 'help' && command !== '--help') process.exitCode = 1
  }
} catch (error) {
  console.error(`testhud: ${error instanceof Error ? error.message : String(error)}`)
  process.exitCode = 1
}
