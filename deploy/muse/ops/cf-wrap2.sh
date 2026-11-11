#!/bin/bash
# cloudflared 启动包装（muse-tunnel-2.service 的 ExecStart），由 bootstrap.sh 装到 bridge-ops/，配置读同目录的 muse.env。
# 与 cf-wrap.sh 同一套做法（私有 mount namespace 盖 hosts、降权跑 cloudflared），区别只有出站路径：
# 本进程走第二条中继 cf-relay-edge2（127.0.0.1:7845 → region2），与主隧道（7844 → region1）互为冗余——
# 同一条命名隧道挂两个连接器是 Cloudflare 官方的 replicas 形态：任一条连接被掐断，另一条照常服务，用户无感。
#
# 只在 named 模式工作：第二连接器跑的是同一条命名隧道（令牌同 cf-wrap，bridge-ops/tunnel.env，0600，
# 经环境变量 TUNNEL_TOKEN 交给 cloudflared，不出现在进程参数里）。quick 模式每起一个进程就是一条新临时隧道，
# 没有「同一条隧道」的说法，所以 muse-tunnel-2 的单元里有 ExecCondition 只在 named 时启动；这里再兜一层：
# 不是 named 就说明原因、挂住不动（不退出，免得 systemd 反复拉起刷状态）。
#
# --metrics 把就绪信号口钉死在 127.0.0.1:20242（主隧道是 20241，见 cf-wrap.sh），
# bridge-sentinel / bridge-probe 按固定口直查 /ready（见 muse-env-lib.sh 的 connector_ready_connections）。
set -e
DIR="$(dirname "$(readlink -f "$0")")"
set -a
. "$DIR/muse.env"
set +a
if [ "${TUNNEL_MODE:-quick}" != named ]; then
  echo "cf-wrap2 只在 named 模式下工作（第二连接器跑同一条命名隧道）；当前 TUNNEL_MODE=${TUNNEL_MODE:-quick}，不启动" >&2
  exec sleep infinity
fi
set -a
. "$DIR/tunnel.env"
set +a
# VM 重启清掉了 cloudflared（#9）：从 bridge-ops/ 的持久副本补回再起，不用等看门狗、也不用重跑 install
if [ -f "$DIR/muse-env-lib.sh" ]; then . "$DIR/muse-env-lib.sh"; restore_cloudflared "$CLOUDFLARED" "$OPS/cloudflared" || true; fi
exec unshare --mount --propagation private bash -c '
mount --bind "$OPS/hosts" /etc/hosts
common=(--no-autoupdate --protocol http2 --edge "region2.v2.argotunnel.com:7845" --metrics 127.0.0.1:20242)
exec setpriv --reuid="$SVC_USER" --regid="$SVC_USER" --clear-groups "$CLOUDFLARED" tunnel "${common[@]}" run
'
