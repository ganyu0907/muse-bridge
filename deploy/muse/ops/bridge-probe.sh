#!/usr/bin/env bash
# 可用性探针（bridge-probe.service 的 ExecStart），由 bootstrap.sh 装到 bridge-ops/，配置读同目录的 muse.env。
# 每 60 秒采一笔写进持久区的账本：平台重启会把 journal 和 /etc 清掉，这本账放在 $OPS 底下，抹不掉，
# 后面算「到底断了多少、断在哪一层」全靠它。只采样、不动手（修是 bridge-sentinel 的事，记事件是 bridge-recorder 的事）。
#
# 账本 v2（本文件）：$OPS/probe/uptime-v2.csv。表头与 v1 不同（加了列），所以另起文件；
# v1 的 $OPS/probe/uptime.csv 原样保留、不再续写——旧口径的历史数据查旧文件，两本账以本文件第一笔的时间为界。
# 列：time,boot,local,local_ms,bridge,tunnel,tunnel2,conn1,conn2,relay1,relay2,public
#   boot    = 本次开机的 boot_id 前 8 位：它一变就是平台重启过，配合时间戳能算出机器没醒的时长
#   local   = 本地 http://127.0.0.1:$PORT/ 的状态码；local_ms = 这次请求的耗时（毫秒）
#   bridge / tunnel / tunnel2 = 三个 unit 的 systemctl is-active 原样（tunnel2 在 quick 模式恒为 inactive，正常）
#   conn1 / conn2 = 两条 cloudflared 各自 metrics /ready 上的 readyConnections（见 muse-env-lib.sh）；-1 = 拿不到
#   relay1 / relay2 = 两条中继监听口（7844 / 7845）TCP 能否连上：1 / 0
#   public  = 经平台出口自检固定域名：受出口抖动污染，只作参考（与 v1 同口径）；没有固定域名时记 -
# 体积：沿用 v1 的截断策略——超过 30 万行只留最近 20 万行。
set -u
DIR="$(dirname "$(readlink -f "$0")")"
set -a; . "$DIR/muse.env"; set +a
[ -f "$DIR/muse-env-lib.sh" ] && . "$DIR/muse-env-lib.sh"
OUT_DIR="$OPS/probe"
OUT="$OUT_DIR/uptime-v2.csv"
install -d -m 0770 "$OUT_DIR"
[ -f "$OUT" ] || echo "time,boot,local,local_ms,bridge,tunnel,tunnel2,conn1,conn2,relay1,relay2,public" > "$OUT"

tcp_open() { timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }
sample() {
  local ts boot out local_code local_ms pub_code br tun tun2 c1 c2 r1 r2 lines
  ts=$(date '+%Y-%m-%d %H:%M:%S %z')
  boot=$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
  out=$(curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}' "http://127.0.0.1:$PORT/" 2>/dev/null || echo "000 0")
  local_code=${out%% *}
  local_ms=$(awk -v t="${out##* }" 'BEGIN { printf "%d", t * 1000 }' 2>/dev/null || echo 0)
  if [ -n "${PUBLIC_HOSTNAME:-}" ]; then
    pub_code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' "https://$PUBLIC_HOSTNAME/" 2>/dev/null); [ -n "$pub_code" ] || pub_code=000
  else pub_code="-"; fi
  br=$(systemctl is-active bridge 2>/dev/null || echo unknown)
  tun=$(systemctl is-active muse-tunnel 2>/dev/null || echo unknown)
  tun2=$(systemctl is-active muse-tunnel-2 2>/dev/null || echo unknown)
  c1=$(connector_ready_connections muse-tunnel)
  c2=$(connector_ready_connections muse-tunnel-2)
  if tcp_open 7844; then r1=1; else r1=0; fi
  if tcp_open 7845; then r2=1; else r2=0; fi
  echo "$ts,$boot,$local_code,$local_ms,$br,$tun,$tun2,$c1,$c2,$r1,$r2,$pub_code" >> "$OUT"
  lines=$(wc -l < "$OUT")
  if [ "$lines" -gt 300000 ]; then tail -n 200000 "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"; fi
}
while true; do
  sample
  sleep 60
done
