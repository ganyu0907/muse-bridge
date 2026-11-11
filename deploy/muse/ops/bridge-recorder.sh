#!/bin/bash
# 事件收集（bridge-recorder.service 的 ExecStart），由 bootstrap.sh 装到 bridge-ops/，配置读同目录的 muse.env。
#
# 为什么要它：这台 VM 的 journal 在临时盘上，平台每次重启就清零——事后想查「昨晚断了几次、每次多久、
# 是哪一层先倒的」时证据已经没了。这里把相关 unit 的 journal 事件实时跟随、追加到持久区，
# 平台重启抹不掉这本事件账。只记不动手（修是 bridge-sentinel 的事）。
#
# 收哪些：muse-tunnel、muse-tunnel-2、cf-relay-api、cf-relay-edge、cf-relay-edge2、bridge-sentinel、
# bridge-probe、bridge-recorder、bridge 本体的 journal（systemd 给这些 unit 打的 Started / Stopped /
# Failed 也在内）。看门狗的自愈动作（heal 补回单元、拉起服务）最终都落成这些 unit 的启停事件、同样入账；
# 看门狗脚本自己的文字输出由 Muse 的 hook 运行时托管、不落在 VM 的文件系统里，这里收不到，如实说明。
# 红线：只收 unit 运行事件，不收对话内容；脚本不读任何令牌 / 密钥文件。cloudflared 日志里的
# Connector ID、边缘节点地址属正常运行信息，照收。
#
# 落点与留存（先立规矩）：$OPS/recorder/events-YYYY-MM-DD.log，按天分文件；非当天的自动 gzip 压缩；
# 压缩档保留 90 天（按修改时间），过期删除。账本总体积由这条留存规则封顶，不再另设总量上限。
# 标记行：本服务每次启动先写一行 === BOOT / RESUME ===：boot_id 与上次不同写 BOOT
# （上一行事件到这行之间的时间空缺，就是平台重启后机器没醒的时长，可以直接量出来）；
# boot_id 没变（只是本服务自己重启）写 RESUME，避免把收集服务自身的重启误读成平台重启。
set -u
DIR="$(dirname "$(readlink -f "$0")")"
set -a; . "$DIR/muse.env"; set +a
LOG_DIR="$OPS/recorder"
install -d -m 0770 "$LOG_DIR"
UNITS=(-u muse-tunnel -u muse-tunnel-2 -u cf-relay-api -u cf-relay-edge -u cf-relay-edge2
       -u bridge-sentinel -u bridge-probe -u bridge-recorder -u bridge)
today_file() { printf '%s/events-%s.log' "$LOG_DIR" "$(date +%F)"; }
cleanup_old() {
  local f
  for f in "$LOG_DIR"/events-*.log; do
    [ -f "$f" ] || continue
    [ "$f" = "$(today_file)" ] && continue
    gzip -f "$f" 2>/dev/null || true
  done
  find "$LOG_DIR" -name 'events-*.log.gz' -mtime +90 -delete 2>/dev/null || true
}
# 启动标记
cur_boot="$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
last_boot="$(cat "$LOG_DIR/last-boot" 2>/dev/null || echo '')"
kind=BOOT; [ "$cur_boot" = "$last_boot" ] && kind=RESUME
printf '%s === %s boot=%s recorder started (pid %s) ===\n' "$(date '+%F %T %z')" "$kind" "$cur_boot" "$$" >> "$(today_file)"
printf '%s\n' "$cur_boot" > "$LOG_DIR/last-boot"
cleanup_old
last_day="$(date +%F)"
# 跟随 journal：管道断了（journal 重启等）5 秒后重连；跨天时换文件并顺手做一次轮转清理
while true; do
  while IFS= read -r line; do
    d="$(date +%F)"
    if [ "$d" != "$last_day" ]; then cleanup_old; last_day="$d"; fi
    printf '%s\n' "$line" >> "$LOG_DIR/events-$d.log"
  done < <(journalctl -f -n 0 --no-pager -o short-iso "${UNITS[@]}" 2>/dev/null)
  sleep 5
done
