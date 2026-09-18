#!/usr/bin/env bash
# 一次推到全部远程，避免漏推一边。
#
# 为什么需要它：这个仓库有两个远程 —— `origin` 是自建 NAS（主），`github` 是异地副本。
# 平时 `git push` 只推一个，很容易漏掉另一个，而"备份"的整个价值恰恰就在那份副本上。
# 脚本不写死远程名，有几个推几个，以后加/换远程不用改它。
#
# 用法： bin/pushall.sh   或   git pushall
#
# 一个远程推失败时会继续推其余远程，最后汇总退出码：某个远程连不上（本次 github
# 就整个不可达）不该让另一个也漏推 —— 那恰恰是"别漏推"要防的事。
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
branch=$(git rev-parse --abbrev-ref HEAD)

if [ "$branch" = "HEAD" ]; then
    echo "当前不在任何分支上（detached HEAD），先切回分支再推。" >&2
    exit 1
fi

remotes=$(git remote)
if [ -z "$remotes" ]; then
    echo "这个仓库没有配置任何远程。" >&2
    exit 1
fi

failed=""
for remote in $remotes; do
    echo "→ $remote"
    if ! git push "$remote" "$branch"; then
        echo "  ✗ $remote 推送失败（继续推其余远程）" >&2
        failed="$failed $remote"
    fi
done

# 推完核一遍，别让"推送成功"只停留在命令的退出码上。
echo
echo "各远程上 $branch 的 HEAD："
for remote in $remotes; do
    printf "  %-8s %s\n" "$remote" "$(git ls-remote "$remote" "refs/heads/$branch" 2>/dev/null | cut -f1)"
done
printf "  %-8s %s\n" "本地" "$(git rev-parse HEAD)"

if [ -n "$failed" ]; then
    echo
    echo "以下远程没推成功：$failed" >&2
    exit 1
fi
