#!/bin/bash
# 本地哨兵（bridge-sentinel.service 的 ExecStart），由 bootstrap.sh 装到 bridge-ops/，配置读同目录的 muse.env。
#
# 为什么要它：平台看门狗以「本机经公网探自己」为准、每分钟才一轮，而且只会重启隧道、治不了中继
# （中继假死时它重启隧道也还是走同一条死中继）。双连接器（muse-tunnel + muse-tunnel-2）上线后，
# 重启任何一条连接对用户都不可见，本地哨兵就可以更勤、更准地修：每 10 秒一轮，只修坏掉的那一条。
#
# 管辖范围（只动这四条）：muse-tunnel、muse-tunnel-2（仅 named 模式）、cf-relay-edge、cf-relay-edge2。
# bridge 本体只记一行日志、不动手——它的重启归平台看门狗与更新流程管。探针与记录组件不在管辖内。
#
# 判定口径照服务端 public-access 的官方逻辑：连接器只认 cloudflared 自己的 /ready（回环 metrics 口，
# 见 ops/muse-env-lib.sh 的 connector_ready_connections），不拿本机公网探活当依据；中继只认监听口在不在。
# 动手门槛（防雪崩）：连续 3 轮（约 30 秒）失败才重启；每条组件自本次启动起 120 秒内不动作（启动宽限，
# 重启后 ActiveEnterTimestamp 刷新，宽限自动续上）；每条组件每小时至多重启 3 次（状态在 $OPS/sentinel/）。
set -u
DIR="$(dirname "$(readlink -f "$0")")"
STATE_SRC="$DIR/muse.env"
STATE_DIR=""
LOG=""

setup() {
  set -a; . "$STATE_SRC"; set +a
  [ -f "$DIR/muse-env-lib.sh" ] && . "$DIR/muse-env-lib.sh"
  STATE_DIR="$OPS/sentinel"; install -d -m 0770 "$STATE_DIR"
  LOG="$STATE_DIR/sentinel.log"
}
log() {
  printf '%s %s\n' "$(date '+%F %T %z')" "$*" >> "$LOG" 2>/dev/null || true
  # 日志封顶：超过 1MB 只留后半
  if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    tail -c 524288 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}
started_epoch() { # $1 = unit；输出 ActiveEnterTimestamp 的 epoch，拿不到输出 0
  local v; v="$(systemctl show -p ActiveEnterTimestamp --value "$1" 2>/dev/null || true)"
  [ -n "$v" ] && date -d "$v" +%s 2>/dev/null || echo 0
}
fail_get() { cat "$STATE_DIR/fail.$1" 2>/dev/null || echo 0; }
fail_set() { printf '%s\n' "$2" > "$STATE_DIR/fail.$1" 2>/dev/null || true; }
budget_ok() { # $1 = 组件键；过去 1 小时内重启次数 < 3 才放行
  local now cnt; now="$(date +%s)"
  cnt="$(awk -v k="$1" -v t="$now" '$1 == k && $2 > t - 3600 { c++ } END { print c + 0 }' "$STATE_DIR/restarts.log" 2>/dev/null || echo 0)"
  [ "${cnt:-0}" -lt 3 ]
}
note_restart() { # $1 = 组件键；记一笔，并顺手清掉 1 小时前的旧记录
  local now; now="$(date +%s)"
  printf '%s %s\n' "$1" "$now" >> "$STATE_DIR/restarts.log"
  awk -v t="$now" '$2 > t - 3600' "$STATE_DIR/restarts.log" > "$STATE_DIR/restarts.log.tmp" 2>/dev/null \
    && mv "$STATE_DIR/restarts.log.tmp" "$STATE_DIR/restarts.log"
}
in_grace() { # $1 = unit；启动未满 120 秒 = 1（在宽限内）
  local st; st="$(started_epoch "$1")"
  [ "$st" != 0 ] && [ $(( $(date +%s) - st )) -lt 120 ]
}
maybe_restart() { # $1 = 组件键 $2 = unit $3 = 原因
  if budget_ok "$1"; then
    log "重启 $2：$3"
    systemctl restart "$2" 2>/dev/null || log "重启 $2 失败（systemctl 返回非 0）"
    note_restart "$1"
  else
    log "想重启 $2（$3），但已到每小时 3 次上限，这一小时不再动手"
  fi
  fail_set "$1" 0
}
check_connector() { # $1 = 组件键 $2 = unit
  local key="$1" unit="$2" n c
  systemctl is-active --quiet "$unit" || { fail_set "$key" 0; return 0; }   # 没在跑归 heal / 看门狗拉起，哨兵不抢
  in_grace "$unit" && { fail_set "$key" 0; return 0; }
  n="$(connector_ready_connections "$unit")"
  if [ "${n:-"-1"}" -ge 1 ] 2>/dev/null; then fail_set "$key" 0; return 0; fi
  c=$(( $(fail_get "$key") + 1 )); fail_set "$key" "$c"
  [ "$c" -ge 3 ] && maybe_restart "$key" "$unit" "/ready 连续 $c 轮无注册连接（进程在、连接没了）"
}
check_relay() { # $1 = 组件键 $2 = unit $3 = 监听口
  local key="$1" unit="$2" port="$3" c
  systemctl is-active --quiet "$unit" || { fail_set "$key" 0; return 0; }
  in_grace "$unit" && { fail_set "$key" 0; return 0; }
  if ss -tln 2>/dev/null | grep -qE "127\.0\.0\.1:$port[[:space:]]"; then fail_set "$key" 0; return 0; fi
  c=$(( $(fail_get "$key") + 1 )); fail_set "$key" "$c"
  [ "$c" -ge 3 ] && maybe_restart "$key" "$unit" "监听口 127.0.0.1:$port 连续 $c 轮不在"
}
check_bridge_note() { # bridge 本体：只在状态翻转时记一行，绝不重启
  local code now
  code="$(curl --noproxy '*' -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$PORT/healthz" 2>/dev/null || echo 000)"
  if [ "$code" = 200 ]; then now=ok; else now="down($code)"; fi
  if [ "$now" != "$(cat "$STATE_DIR/bridge.state" 2>/dev/null || echo '')" ]; then
    printf '%s\n' "$now" > "$STATE_DIR/bridge.state" 2>/dev/null || true
    log "bridge 本地 /healthz 状态变为 $now（只记录：它的重启归平台看门狗与更新流程管）"
  fi
}

setup
log "哨兵启动（管辖：muse-tunnel、muse-tunnel-2、cf-relay-edge、cf-relay-edge2）"
while true; do
  set -a; . "$STATE_SRC"; set +a   # 每轮重读 muse.env：TUNNEL_MODE 等改了不用重启哨兵
  check_connector tunnel1 muse-tunnel
  if [ "${TUNNEL_MODE:-quick}" = named ]; then check_connector tunnel2 muse-tunnel-2; fi
  check_relay relay1 cf-relay-edge 7844
  check_relay relay2 cf-relay-edge2 7845
  check_bridge_note
  sleep 10
done
