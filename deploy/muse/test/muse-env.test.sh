#!/bin/bash
# muse.env 回写规则的单测（ops/muse-env-lib.sh 里的纯函数；不需要 root、systemd、jq）：
#   bash deploy/muse/test/muse-env.test.sh
# 另外把 bootstrap.sh 的 write_muse_env 原样抠出来，在临时目录里跑一遍「上次的 muse.env → 回写」，核对整条路径。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MUSE="$(cd "$HERE/.." && pwd)"
# shellcheck source=../ops/muse-env-lib.sh
. "$MUSE/ops/muse-env-lib.sh"

pass=0 fail=0
eq() { # $1 = 说明  $2 = 实际  $3 = 期望
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  实际：%s\n  期望：%s\n' "$1" "$2" "$3"; fi
}
has() { # $1 = 说明  $2 = 实际  $3 = 应包含的片段
  case "$2" in *"$3"*) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); printf 'FAIL %s\n  实际：%s\n  应包含：%s\n' "$1" "$2" "$3" ;; esac
}

B="bridge cf-relay-api cf-relay-edge cf-relay-edge2 muse-tunnel muse-tunnel-2 bridge-sentinel bridge-probe bridge-recorder"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# —— merge_services ——
eq "新装：只有内置" "$(merge_services "$B" "")" "$B"
eq "上次跟内置一样" "$(merge_services "$B" "$B")" "$B"
eq "保留自己加的服务" "$(merge_services "$B" "$B claude-relay")" "$B claude-relay"
eq "自有服务保持原顺序" "$(merge_services "$B" "bridge my-b cf-relay-api my-a")" "$B my-b my-a"
eq "去重" "$(merge_services "$B" "$B x x bridge")" "$B x"
eq "新版本新增的内置服务不会被旧清单漏掉" "$(merge_services "$B new-builtin" "$B claude-relay")" "$B new-builtin claude-relay"
eq "人工删掉的内置服务回来（内置的总在）" "$(merge_services "$B" "bridge muse-tunnel")" "$B"
eq "退役的内置服务不当成自有服务留下" "$(merge_services "bridge muse-tunnel" "$B mine" "cf-relay-api cf-relay-edge cf-relay-edge2 muse-tunnel-2 bridge-sentinel bridge-probe bridge-recorder")" "bridge muse-tunnel mine"
eq "不合法的名字丢掉" "$(merge_services "$B" 'ok.service $(touch /tmp/x) a;b *')" "$B ok.service"
eq "多余空白" "$(merge_services "$B" "  bridge    extra  ")" "$B extra"

# —— pick_cloudflared ——
printf '#!/bin/sh\n' > "$TMP/cf-persist"; chmod +x "$TMP/cf-persist"
printf 'x\n' > "$TMP/cf-noexec"; chmod -x "$TMP/cf-noexec"
mkdir -p "$TMP/bin" "$TMP/dir-not-file"; printf '#!/bin/sh\n' > "$TMP/bin/cloudflared"; chmod +x "$TMP/bin/cloudflared"
eq "上次的路径还能执行：沿用" "$(pick_cloudflared "$TMP/cf-persist")" "$TMP/cf-persist"
eq "上次的路径没了：按 PATH 现找" "$(PATH="$TMP/bin:/usr/bin:/bin" pick_cloudflared "$TMP/gone")" "$TMP/bin/cloudflared"
eq "上次的不可执行：按 PATH 现找" "$(PATH="$TMP/bin:/usr/bin:/bin" pick_cloudflared "$TMP/cf-noexec")" "$TMP/bin/cloudflared"
eq "上次的是目录：按 PATH 现找" "$(PATH="$TMP/bin:/usr/bin:/bin" pick_cloudflared "$TMP/dir-not-file")" "$TMP/bin/cloudflared"
eq "上次为空：按 PATH 现找" "$(PATH="$TMP/bin:/usr/bin:/bin" pick_cloudflared "")" "$TMP/bin/cloudflared"
eq "哪都找不到：deb 默认位置" "$(PATH="$TMP/empty" pick_cloudflared "")" "/usr/bin/cloudflared"

# —— env_change_note ——
eq "新装不提示" "$(env_change_note SERVICES "" "$B")" ""
eq "没变不提示" "$(env_change_note SERVICES "$B x" "$B x")" ""
has "新增内置服务时提示" "$(env_change_note SERVICES "$B" "$B y")" "新增：y"
has "去掉时提示" "$(env_change_note SERVICES "$B bad;name" "$B")" "去掉：bad;name"
has "只是顺序变了也提示" "$(env_change_note SERVICES "bridge-recorder bridge-probe bridge-sentinel muse-tunnel-2 muse-tunnel cf-relay-edge2 cf-relay-edge cf-relay-api bridge" "$B")" "顺序"
has "CLOUDFLARED 变了提示新旧路径" "$(env_change_note CLOUDFLARED "/old/cf" "/usr/bin/cloudflared")" "/old/cf 已经不存在或不能执行，改用 /usr/bin/cloudflared"
eq "CLOUDFLARED 没变不提示" "$(env_change_note CLOUDFLARED "/usr/bin/cloudflared" "/usr/bin/cloudflared")" ""

# —— 整条路径：bootstrap.sh 的 prev() + write_muse_env，按上次的 muse.env 回写 ——
BOOT="$MUSE/bootstrap.sh"
fn() { sed -n "/^$1() {/,/^}/p" "$BOOT"; }
prev_def="$(grep -E '^prev\(\) \{' "$BOOT")"
wme_def="$(fn write_muse_env)"
[ -n "$prev_def" ] && [ -n "$wme_def" ] || { echo "FAIL 在 bootstrap.sh 里找不到 prev / write_muse_env"; exit 1; }
SERVICES_LINE="$(grep -E '^SERVICES=' "$BOOT" | head -1)"
run_write() { # 在子 shell 里模拟一次回写；$1 = 预置的 muse.env 内容（空 = 新装）
  (
    OPS="$TMP/ops"; rm -rf "$OPS"; mkdir -p "$OPS"
    [ -z "$1" ] || printf '%s\n' "$1" > "$OPS/muse.env"
    PERSIST=/home/hatch RELS=/home/hatch/bridge-releases DATA=/home/hatch/bridge-srv PORT=8787 SVC_USER=bridge EDGE=e PROXY=p
    AGENTS=claude USERS_MODE=solo TUNNEL_MODE=quick PUBLIC_HOSTNAME="" CHANNEL="" AUTO_UPDATE=0 UI_LANG=zh
    SERVICES_RETIRED=""
    eval "$SERVICES_LINE"
    install() { mkdir -p "${@: -1}"; }   # write_muse_env 里只用 install -d 建目录
    warn() { printf 'WARN %s\n' "$*"; }
    eval "$prev_def"; eval "$wme_def"
    PATH="$TMP/bin:/usr/bin:/bin" write_muse_env
    printf -- '---\n'; cat "$OPS/muse.env"
  )
}
out="$(run_write "")"
has "新装：SERVICES 是内置清单" "$out" "SERVICES=\"$B\""
has "新装：CLOUDFLARED 按 PATH 找" "$out" "CLOUDFLARED=$TMP/bin/cloudflared"
eq "新装：不打提示" "$(grep -c '^WARN' <<<"$out")" "0"

out="$(run_write "SERVICES=\"$B claude-relay\"
CLOUDFLARED=$TMP/cf-persist")"
has "更新：保留自有服务" "$out" "SERVICES=\"$B claude-relay\""
has "更新：沿用还能执行的 cloudflared" "$out" "CLOUDFLARED=$TMP/cf-persist"
eq "更新：值没变不打提示" "$(grep -c '^WARN' <<<"$out")" "0"

out="$(run_write "SERVICES=\"bridge claude-relay\"
CLOUDFLARED=$TMP/gone")"
has "更新：补回内置服务、自有服务接在后面" "$out" "SERVICES=\"$B claude-relay\""
has "更新：旧 cloudflared 没了就现找" "$out" "CLOUDFLARED=$TMP/bin/cloudflared"
has "更新：CLOUDFLARED 变了打提示" "$out" "WARN muse.env 的 CLOUDFLARED 变了"
has "更新：SERVICES 变了打提示" "$out" "WARN muse.env 的 SERVICES 变了"
has "文件头写清回写规则" "$out" "这里多出来的服务"

# 回写出来的 muse.env 能被 heal.sh / 看门狗 source
( . "$TMP/ops/muse.env" && [ "$SERVICES" = "$B claude-relay" ] ) && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL 回写的 muse.env source 后 SERVICES 不对"; }

# —— cloudflared 持久副本（#9：VM 重启清掉 /usr/bin/cloudflared）——
CF="$TMP/cf/usr/bin/cloudflared" BK="$TMP/cf/ops/cloudflared"; mkdir -p "$TMP/cf/ops" "$(dirname "$CF")"
printf '#!/bin/sh\necho v1\n' > "$CF"; chmod +x "$CF"
keep_cloudflared "$CF" "$BK"
eq "keep：存了副本" "$(cat "$BK" 2>/dev/null)" "$(cat "$CF")"
[ -x "$BK" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL keep：副本不可执行"; }
# 软链两条只在真 Linux 上测（Git Bash 的 ln -s 是复制）
mkdir -p "$TMP/cf/usr/local/bin"; ln -sf "$CF" "$TMP/cf/usr/local/bin/cloudflared" 2>/dev/null
[ -L "$TMP/cf/usr/local/bin/cloudflared" ] && LINKS=1 || LINKS=0
printf '#!/bin/sh\necho v2\n' > "$CF"; chmod +x "$CF"
if [ "$LINKS" = 1 ]; then keep_cloudflared "$TMP/cf/usr/local/bin/cloudflared" "$BK"; else keep_cloudflared "$CF" "$BK"; fi
has "keep：原件更新了副本也更新（Linux 上经软链）" "$(cat "$BK")" "v2"
keep_cloudflared "$TMP/cf/gone" "$BK"
has "keep：原件不在不碰副本" "$(cat "$BK")" "v2"
eq "restore：原件还在什么都不做" "$(restore_cloudflared "$CF" "$BK"; echo "rc=$?")" "rc=0"
rm -rf "$TMP/cf/usr"   # 模拟 VM 重启：/usr 下的原件和软链都没了
out="$(restore_cloudflared "$CF" "$BK"; echo "rc=$?")"
has "restore：从副本补回并说一声" "$out" "已从 $BK 补回 $CF"
has "restore：补回成功" "$out" "rc=0"
[ -x "$CF" ] && [ "$(cat "$CF")" = "$(cat "$BK")" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL restore：补回的文件不对"; }
if [ "$LINKS" = 1 ]; then
  mkdir -p "$TMP/cf/usr/local/bin"; ln -sf "$TMP/cf/nowhere" "$TMP/cf/usr/local/bin/cloudflared"
  restore_cloudflared "$TMP/cf/usr/local/bin/cloudflared" "$BK" >/dev/null
  [ -x "$TMP/cf/usr/local/bin/cloudflared" ] && [ ! -L "$TMP/cf/usr/local/bin/cloudflared" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL restore：断链没换成真文件"; }
fi
rm -f "$CF"
eq "restore：没有副本 = 1" "$(restore_cloudflared "$CF" "$TMP/cf/ops/none"; echo "rc=$?")" "rc=1"
eq "restore：路径为空 = 1" "$(restore_cloudflared "" "$BK"; echo "rc=$?")" "rc=1"
# 三处都接上了：安装存副本、heal.sh 和 cf-wrap.sh 补回
has "bootstrap 把函数库装进 bridge-ops" "$(cat "$BOOT")" 'ops/muse-env-lib.sh" "$OPS/muse-env-lib.sh"'
has "bootstrap 存副本" "$(cat "$BOOT")" 'keep_cloudflared "$(prev CLOUDFLARED)" "$OPS/cloudflared"'
has "bootstrap 下载前先试副本" "$(cat "$BOOT")" 'restore_cloudflared "$(prev CLOUDFLARED)" "$OPS/cloudflared"'
has "heal.sh 补回" "$(cat "$MUSE/ops/heal.sh")" 'restore_cloudflared "$CLOUDFLARED" "$OPS/cloudflared"'
has "cf-wrap.sh 启动前补回" "$(cat "$MUSE/ops/cf-wrap.sh")" 'restore_cloudflared "$CLOUDFLARED" "$OPS/cloudflared"'

# —— connector_ready_connections：按固定 metrics 口直查 /ready（2026-11-11 哨兵误判的回归）——
# 桩件钉在 $STUB 里顶掉真命令：假 systemctl（MainPID 由 FAKE_MAINPID 控制）、假 curl（按口返回
# FAKE_READY_<口> 的内容，值 FAIL = 连接失败；每次调用把 URL 记进 FAKE_CURL_LOG 好核对查的是哪个口）、
# 假 ss（FAKE_SS=real 时是真机形态：metrics 监听行没有进程属主标注；=empty 时干脆什么都不输出）。
# 旧实现拿 MainPID 去 ss 里找口，在这两种 ss 下都恒落空、恒 -1；新实现不看 ss，按 unit 直查固定口。
STUB="$TMP/stub"; mkdir -p "$STUB"
cat > "$STUB/systemctl" <<'EOF'
#!/bin/bash
echo "${FAKE_MAINPID:-4242}"
EOF
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
url="${@: -1}"
echo "$url" >> "$FAKE_CURL_LOG"
port="$(printf '%s' "$url" | grep -oE ':[0-9]+/' | tr -d ':/')"
eval "body=\$FAKE_READY_$port"
[ "$body" = FAIL ] && exit 7
printf '%s' "$body"
EOF
cat > "$STUB/ss" <<'EOF'
#!/bin/bash
[ "${FAKE_SS:-real}" = empty ] && exit 0
 cat <<'OUT'
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      4096       127.0.0.1:20241      0.0.0.0:*
LISTEN 0      4096       127.0.0.1:20242      0.0.0.0:*
OUT
EOF
chmod +x "$STUB/systemctl" "$STUB/curl" "$STUB/ss"
ready() { # $1 = unit；结果留在 $READY_OUT，这轮查过的 URL 留在 $READY_URLS
  export FAKE_CURL_LOG="$TMP/curl.log"; : > "$FAKE_CURL_LOG"
  READY_OUT="$( ( export PATH="$STUB:/usr/bin:/bin"; connector_ready_connections "$1" ) )"
  READY_URLS="$(cat "$FAKE_CURL_LOG")"
}
export FAKE_SS=real FAKE_MAINPID=4242
export FAKE_READY_20241='{"readyConnections": 1}' FAKE_READY_20242='{"readyConnections": 2}'
ready muse-tunnel
eq "主隧道：读固定口的 readyConnections" "$READY_OUT" "1"
eq "主隧道：查的就是 20241" "$READY_URLS" "http://127.0.0.1:20241/ready"
ready muse-tunnel-2
eq "第二隧道：读固定口的 readyConnections" "$READY_OUT" "2"
eq "第二隧道：查的就是 20242（不串口）" "$READY_URLS" "http://127.0.0.1:20242/ready"
eq "真机形态 ss（监听无属主标注）在场：结果不受它影响" "$READY_OUT" "2"
export FAKE_SS=empty
ready muse-tunnel
eq "ss 干脆没输出：照样读到固定口的连接数" "$READY_OUT" "1"
export FAKE_SS=real FAKE_READY_20241='{"readyConnections": 0}'
ready muse-tunnel
eq "readyConnections 为 0：如实输出 0（进程在、连接没了），不许说成 -1" "$READY_OUT" "0"
export FAKE_READY_20241=FAIL
ready muse-tunnel
eq "/ready 不通：-1" "$READY_OUT" "-1"
export FAKE_READY_20241='{"readyConnections": 1}' FAKE_MAINPID=0
ready muse-tunnel
eq "进程不在（MainPID=0）：-1" "$READY_OUT" "-1"
export FAKE_MAINPID=4242
ready no-such-unit
eq "不认识的 unit：-1" "$READY_OUT" "-1"
# 两个 wrap 把 metrics 口钉死，函数才有固定口可查
has "cf-wrap.sh 钉死 metrics 口 20241" "$(cat "$MUSE/ops/cf-wrap.sh")" '--metrics 127.0.0.1:20241'
has "cf-wrap2.sh 钉死 metrics 口 20242" "$(cat "$MUSE/ops/cf-wrap2.sh")" '--metrics 127.0.0.1:20242'

printf '%d 通过，%d 失败\n' "$pass" "$fail"
[ "$fail" = 0 ]
