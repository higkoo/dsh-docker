#!/bin/bash
# ============================================================
# trusted-host 白名单回归测试
#
# 覆盖：
#   - 域名规范化（协议前缀、路径、引号、大小写、FQDN 结尾点）
#   - 多分隔符（逗号 / 分号 / 空白）混合输入
#   - 「域名 + 端口」必须被完整保留（历史上被 IFS 的冒号切碎过）
#   - 去重（含大小写）与子域边界
#   - 末条不因「无尾随换行」被静默丢弃
#   - map 规则生成：精确规则 + 带端口正则（`host:*` 是无效写法）
#   - 渲染产物无占位符残留、且 `nginx -t` 通过
#   - 与 nginx 真实语义对齐：Host 带不带端口、子域欺骗、端口限定
#   - Host / Origin 原样透传（本次改动的核心目标）
#   - 空白名单 = 只放行回环（fail-closed）
#
# 凡涉及「行为」的断言，都尽量起真实 nginx 验证，而不是只看生成文本 ——
# 生成文本看着对、跑起来不生效，正是本次改动踩到的坑
# （`"host:*"` 在 nginx map 里根本不匹配带端口的 Host）。
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../script" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS+1))
        printf '  \033[32mPASS\033[0m %s\n' "$desc"
    else
        FAIL=$((FAIL+1))
        printf '  \033[31mFAIL\033[0m %s\n' "$desc"
        printf '       期望: [%s]\n' "$expected"
        printf '       实际: [%s]\n' "$actual"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$desc"
    else
        FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$desc"
        printf '       未找到: [%s]\n' "$needle"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$desc"
        printf '       不应出现: [%s]\n' "$needle"
    else
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$desc"
    fi
}

# ------------------------------------------------------------
# 构造一个只含 trusted-host 相关函数的最小执行环境。
# 直接从 entrypoint.sh 抽取函数，保证测的是**真实实现**
# （手抄一份"正确实现"来测是抓不到实现里的 bug 的）。
# ------------------------------------------------------------
TRUSTED_FUNCS=(
    normalize_trusted_host
    is_valid_trusted_host
    has_explicit_port
    collect_trusted_host_raw
    split_trusted_host_line
    load_trusted_hosts
    build_trusted_host_map
)

build_harness() {
    local out="$1"
    {
        echo '#!/usr/bin/env bash'
        echo "DSH_WEB_HOST=127.0.0.1"
        echo "DSH_WEB_PORT=3080"
        echo "NGINX_SRC_DIR='${ROOT_DIR}/config/nginx'"
        echo 'NGINX_RUN_DIR="${NGINX_RUN_DIR:-/tmp/th_render}"'
        echo 'NGINX_RUN_CONF="${NGINX_RUN_DIR}/nginx.conf"'
        echo 'NGINX_RUN_CONFD="${NGINX_RUN_DIR}/conf.d"'
        echo "TRUSTED_HOSTS_FILE='${ROOT_DIR}/config/dsh/trusted-hosts.txt'"
        echo 'export DSH_TRUSTED_HOSTS="${DSH_TRUSTED_HOSTS:-}"'
        echo 'export DSH_TRUSTED_HOST_DENY_LOG="${DSH_TRUSTED_HOST_DENY_LOG:-debug}"'
        echo 'TRUSTED_HOSTS_LIST=""; TRUSTED_HOSTS_RAW_COUNT=0'
        local f
        for f in "${TRUSTED_FUNCS[@]}"; do
            sed -n "/^${f}()/,/^}/p" "${SCRIPT_DIR}/entrypoint.sh"
        done
        sed -n '/^render_nginx_conf()/,/^}/p' "${SCRIPT_DIR}/entrypoint.sh"
    } > "$out"
}

echo "============================================"
echo " trusted-host 白名单回归测试"
echo "============================================"
echo

HARNESS="$(mktemp /tmp/th_harness_XXXX.sh)"
export HARNESS
build_harness "$HARNESS"
bash -n "$HARNESS" || { echo "错误：无法从 entrypoint.sh 抽取函数（语法错误）"; exit 1; }

# 只执行「加载白名单并打印规范结果」的片段。
#
# ⚠ 不要把待测值拼进 `bash -c` 的脚本文本里 —— 那会再经历一层 shell 解析，
#   引号与空格被吃掉，测的就不是 parse 逻辑本身了。统一走环境变量传值。
probe_list() {   # $1 = DSH_TRUSTED_HOSTS 原始值
    DSH_TRUSTED_HOSTS="$1" bash -c '
        source "$HARNESS"
        load_trusted_hosts
        printf "%s" "$TRUSTED_HOSTS_LIST"
        printf "COUNT=%s\n" "$TRUSTED_HOSTS_RAW_COUNT"
    ' 2>/dev/null
}

probe_map() {    # $1 = DSH_TRUSTED_HOSTS 原始值
    DSH_TRUSTED_HOSTS="$1" bash -c '
        source "$HARNESS"
        load_trusted_hosts
        build_trusted_host_map
    ' 2>/dev/null
}

# ---------- 用例1: 规范化 —— 协议前缀 / 路径 / 引号 / 大小写 / 结尾点 ----------
echo "[用例1] 域名规范化（协议、路径、引号、大小写、FQDN 结尾点）"
T1="$(probe_list '"Example.COM.", https://dsh.corp.com/some/path, http://10.0.0.8:3080/')"
assert_eq "结尾点被剥离"        "1" "$(printf '%s' "$T1" | grep -c '^example\.com$')"
assert_eq "协议前缀 + 路径被剥离" "1" "$(printf '%s' "$T1" | grep -c '^dsh\.corp\.com$')"
assert_eq "带端口的 URL 保留端口" "1" "$(printf '%s' "$T1" | grep -c '^10\.0\.0\.8:3080$')"
assert_eq "共解析出 3 条"        "1" "$(printf '%s' "$T1" | grep -c '^COUNT=3$')"
echo

# ---------- 用例2: 多分隔符混合 ----------
echo "[用例2] 逗号 / 分号 / 空白混合分隔"
T2="$(probe_list 'a.com,b.com; c.com  d.com')"
for h in a.com b.com c.com d.com; do
    assert_eq "解析出 $h" "1" "$(printf '%s' "$T2" | grep -c "^${h}$")"
done
assert_eq "共解析出 4 条" "1" "$(printf '%s' "$T2" | grep -c '^COUNT=4$')"
echo

# ---------- 用例3: 关键回归 —— 域名:端口 不得被冒号切碎 ----------
# 回归背景：曾用 `for host in $line`（默认 IFS 含冒号）分词，
# `dsh.corp.com:9443` 被切成 `dsh.corp.com` + `9443`，端口静默丢失、
# 还多出一个纯数字垃圾条目，导致「白名单里写了端口却完全没生效」。
echo "[用例3] 回归：域名:端口 必须完整保留（不得被冒号切碎）"
T3="$(probe_list 'dsh.corp.com:9443')"
assert_eq "带端口条目完整保留"   "1" "$(printf '%s' "$T3" | grep -c '^dsh\.corp\.com:9443$')"
assert_eq "不得出现被切碎的域名" "0" "$(printf '%s' "$T3" | grep -c '^dsh\.corp\.com$')"
assert_eq "不得出现纯数字垃圾项" "0" "$(printf '%s' "$T3" | grep -c '^9443$')"
assert_eq "只有 1 条（未重复计数）" "1" "$(printf '%s' "$T3" | grep -c '^COUNT=1$')"
echo

# ---------- 用例4: 去重与子域不误伤 ----------
echo "[用例4] 去重（含大小写）与子域边界"
T4="$(probe_list 'a.com,A.COM,a.com')"
assert_eq "同一域名三次出现只算一条" "1" "$(printf '%s' "$T4" | grep -c '^COUNT=1$')"
assert_eq "去重后只保留一份"         "1" "$(printf '%s' "$T4" | grep -c '^a\.com$')"
# 去重用的子串匹配必须带换行边界，否则 a.com 会误伤 x.a.com
T4B="$(probe_list 'x.a.com,a.com')"
assert_eq "a.com 与 x.a.com 视为两条" "1" "$(printf '%s' "$T4B" | grep -c '^COUNT=2$')"
assert_eq "x.a.com 未被误去重"        "1" "$(printf '%s' "$T4B" | grep -c '^x\.a\.com$')"
echo

# ---------- 用例5: 非法写法被拒 ----------
# 说明：`bad host!!` 会被空白分隔成 `bad` 与 `host!!`；
# `bad` 字面上是合法主机名（无非法字符），因此会被收录，
# `host!!` 含非法字符 `!` 被拒 —— 这是「多分隔符」特性带来的预期行为。
echo "[用例5] 非法写法应被忽略并告警"
T5="$(probe_list 'good.com,ok.com,host!!')"
assert_eq "非法项 host!! 被跳过，只留两条" "1" "$(printf '%s' "$T5" | grep -c '^COUNT=2$')"
assert_eq "合法项 good.com 保留"           "1" "$(printf '%s' "$T5" | grep -c '^good\.com$')"
# 注意：告警行本身会带上非法原文（`[host!!]`），所以不能直接对整体输出断言
# 「不含 host!!」，只对**白名单内容**断言 —— 即排除告警行与 COUNT 行之后的部分。
T5_LIST_ONLY="$(printf '%s' "$T5" | grep -vE '^(COUNT=|.*警告|.*忽略非法)')"
assert_eq "非法项未进入白名单"             "0" "$(printf '%s' "$T5_LIST_ONLY" | grep -c 'host!!')"
assert_eq "非法项确实产生了告警"           "1" "$(printf '%s' "$T5" | grep -c '忽略非法 trusted-host')"
echo

# ---------- 用例5b: 关键回归 —— 末条不得因「无尾随换行」被丢弃 ----------
# 回归背景：`while read l; do ...; done < <(producer)` 在 producer 输出
# 不以换行结尾时会**静默丢掉最后一行**。而两种最常见的用户写法恰都如此：
#   - `-e DSH_TRUSTED_HOSTS="a.com,b.com"`（tr 之后末行无换行）
#   - 白名单文件用 printf 写出、没有行尾换行
# 症状是「白名单里写了却一直 403」，非常难查。
echo "[用例5b] 回归：末尾无换行时最后一条不得被丢弃"
T5B="$(probe_list 'a.com,b.com')"
assert_eq "env 末条 b.com 未丢失" "1" "$(printf '%s' "$T5B" | grep -c '^b\.com$')"
assert_eq "env 共 2 条"           "1" "$(printf '%s' "$T5B" | grep -c '^COUNT=2$')"
assert_eq "env 单条也不丢"        "1" "$(printf '%s' "$(probe_list 'only.com')" | grep -c '^only\.com$')"
# 文件分支：写一个不带尾随换行的文件
NOEOL_FILE="$(mktemp /tmp/th_noeol_XXXX)"
printf 'eol-a.com\neol-b.com' > "$NOEOL_FILE"
T5C="$(NOEOL_FILE="$NOEOL_FILE" bash -c '
    source "$HARNESS"
    unset DSH_TRUSTED_HOSTS
    TRUSTED_HOSTS_FILE="$NOEOL_FILE"
    load_trusted_hosts
    printf "%s" "$TRUSTED_HOSTS_LIST"
    printf "COUNT=%s\n" "$TRUSTED_HOSTS_RAW_COUNT"
' 2>/dev/null)"
assert_eq "文件末条 eol-b.com 未丢失" "1" "$(printf '%s' "$T5C" | grep -c '^eol-b\.com$')"
assert_eq "文件共 2 条"              "1" "$(printf '%s' "$T5C" | grep -c '^COUNT=2$')"
rm -f "$NOEOL_FILE"
echo

# ---------- 用例6: map 规则生成（纯域名）----------
echo "[用例6] map 规则：纯域名 → 精确 + 带端口正则"
M6="$(probe_map 'dsh.corp.com')"
assert_contains     "生成无端口精确规则"   '"dsh.corp.com" 0;' "$M6"
assert_contains     "生成带端口正则规则"   '"~^dsh\.corp\.com:" 0;' "$M6"
assert_not_contains "不得生成无效的 host:* 通配" '"dsh.corp.com:*"' "$M6"
echo

# ---------- 用例7: map 规则生成（含端口）----------
echo "[用例7] map 规则：域名:端口 → 只生成该字面 Host"
M7="$(probe_map 'dsh.corp.com:9443')"
assert_contains     "生成含端口的精确规则" '"dsh.corp.com:9443" 0;' "$M7"
assert_not_contains "不得写成转义后的字面量" '"dsh\.corp\.com:9443"' "$M7"
assert_not_contains "不得生成多余的正则规则" '"~^dsh\.corp\.com:9443:"' "$M7"
echo

# ---------- 用例8: has_explicit_port 边界 ----------
echo "[用例8] has_explicit_port 边界判定"
HP="$(mktemp /tmp/th_hp_XXXX.sh)"
sed -n '/^has_explicit_port()/,/^}/p' "${SCRIPT_DIR}/entrypoint.sh" > "$HP"
export HP_UNDER_TEST="$HP"
hp_check() {
    HOST_UNDER_TEST="$1" bash -c '
        source "$HP_UNDER_TEST"
        if has_explicit_port "$HOST_UNDER_TEST"; then echo PORT; else echo noport; fi
    '
}
assert_eq "纯域名 → 无端口"          "noport" "$(hp_check 'dsh.corp.com')"
assert_eq "域名:数字 → 有端口"        "PORT"   "$(hp_check 'dsh.corp.com:9080')"
assert_eq "IP:数字 → 有端口"          "PORT"   "$(hp_check '10.0.0.8:3080')"
assert_eq "[::1] → 无端口"           "noport" "$(hp_check '[::1]')"
assert_eq "[::1]:3080 → 有端口"      "PORT"   "$(hp_check '[::1]:3080')"
assert_eq "host:（空端口）→ 无端口"   "noport" "$(hp_check 'host:')"
assert_eq "a:b:c（非端口）→ 无端口"   "noport" "$(hp_check 'a:b:c')"
rm -f "$HP"
echo

# ---------- 用例9: 空白名单 = 只放行回环（fail-closed）----------
# 说明：回环规则是**模板里静态写的**（不随白名单变化），
# 所以这里要断言模板里仍有这些规则，而不是断言生成的 map 片段。
echo "[用例9] 空白名单时 fail-closed（不放行任意域名）"
TEMPLATE="${ROOT_DIR}/config/nginx/conf.d/dsh-proxy.conf"
TEMPLATE_TEXT="$(cat "$TEMPLATE")"
assert_contains "模板保留回环精确规则" '"127.0.0.1"          0;' "$TEMPLATE_TEXT"
assert_contains "模板保留带端口回环正则" '"~^127\.0\.0\.1:"' "$TEMPLATE_TEXT"
assert_contains "模板保留 localhost"    '"localhost"          0;' "$TEMPLATE_TEXT"
assert_contains "模板保留 IPv6 回环"    '"\[::1\]"' "$TEMPLATE_TEXT"
# 空白名单时生成的 map 片段应为空（既不报错，也不放行任何域名）
M9="$(probe_map '')"
assert_eq "空白名单生成的 map 为空" "" "$(printf '%s' "$M9" | tr -d '[:space:]')"
assert_not_contains "不得出现放行全部的通配" '"0.0.0.0"' "$M9"
# 模板里 default 必须是 1（拒绝），否则空白名单会变成放行全部
DENY_DEFAULT="$(sed -n '/^map \$http_host \$dsh_host_denied/,/^}/p' "$TEMPLATE" | grep -cE '^[[:space:]]*default[[:space:]]+1;')"
assert_eq "模板 default 为拒绝(1)" "1" "$DENY_DEFAULT"
echo

# ---------- 用例10: 渲染产物无占位符残留 ----------
echo "[用例10] 渲染产物必须无占位符残留"
RENDER_DIR="$(mktemp -d /tmp/th_render_XXXX)"
DSH_TRUSTED_HOSTS="check.example" NGINX_RUN_DIR="$RENDER_DIR" bash -c '
    source "$HARNESS"
    render_nginx_conf
' > /dev/null 2>&1
# 只检查非注释行 —— 模板注释里本就写了占位符名字（用于说明），属正常
LEFTOVER="$(grep -hE '__[A-Z_]+__' "$RENDER_DIR/nginx.conf" "$RENDER_DIR/conf.d/dsh-proxy.conf" 2>/dev/null | grep -vE '^[[:space:]]*#' | wc -l)"
assert_eq "非注释行无 __XXX__ 残留" "0" "$LEFTOVER"
# 说明性注释里保留占位符名是**有意为之**（方便读模板的人知道有哪些变量），
# 所以断言的是「非注释行」干净，而不是整份文件不含该字符串。
RENDERED_NONCOMMENT="$(grep -hvE '^[[:space:]]*#' "$RENDER_DIR/conf.d/dsh-proxy.conf" 2>/dev/null)"
assert_not_contains "非注释行不再出现占位符" '__TRUSTED_HOST_MAP__' "$RENDERED_NONCOMMENT"
assert_contains "上游地址已注入" "proxy_pass http://127.0.0.1:3080;" "$RENDERED_NONCOMMENT"
assert_contains "白名单已注入"   '"check.example" 0;' "$RENDERED_NONCOMMENT"
assert_contains "白名单端口正则已注入" '"~^check\.example:" 0;' "$RENDERED_NONCOMMENT"
# 主配置也必须被渲染（include 指向渲染产物目录，保证 nginx 不加载模板）
assert_contains "主配置 include 指向渲染产物" 'include /dsh/run/nginx/conf.d/*.conf;' "$(cat "$RENDER_DIR/nginx.conf")"
rm -rf "$RENDER_DIR"
echo

# ---------- 用例11: nginx 真实语义验证（Host 带端口 / 子域欺骗 / 端口限定）----------
# 这是本套测试最重要的一组：只看生成文本会漏掉「语法对但语义不生效」的问题。
# 若环境里没有 nginx，则跳过（CI 的 lint job 不装 nginx，build job 有）。
echo "[用例11] nginx 真实语义验证（需要本机 nginx）"
if ! command -v nginx >/dev/null 2>&1; then
    printf '  \033[33mSKIP\033[0m 未检测到 nginx，跳过真实语义验证\n'
else
    E2E_DIR="$(mktemp -d /tmp/th_e2e_XXXX)"
    mkdir -p "$E2E_DIR/conf.d" "$E2E_DIR/log" "$E2E_DIR/ssl" "$E2E_DIR/run"
    DSH_TRUSTED_HOSTS="example.com,example.org:9443,10.0.0.8" NGINX_RUN_DIR="$E2E_DIR/render" bash -c '
        source "$HARNESS"
        render_nginx_conf
    ' > /dev/null 2>&1
    # 端口/路径替换，使其可在非特权端口上独立运行
    python3 - "$E2E_DIR" <<'PY'
import sys, pathlib
d = pathlib.Path(sys.argv[1])
repl_main = [('user  www-data;','user  root;'),
             ('pid  /dsh/run/nginx.pid;', f'pid  {d}/run/nginx.pid;'),
             ('error_log  /dsh/log/nginx/error.log  warn;', f'error_log  {d}/log/error.log  warn;'),
             ('include /etc/nginx/modules-enabled/*.conf;','# none'),
             ('access_log  /dsh/log/nginx/access.log  main;', f'access_log  {d}/log/access.log  main;'),
             ('include /dsh/run/nginx/conf.d/*.conf;', f'include {d}/conf.d/*.conf;')]
s = (d/'render/nginx.conf').read_text()
for a,b in repl_main:
    s = s.replace(a,b)
(d/'nginx.conf').write_text(s)
port = 18080
s2 = (d/'render/conf.d/dsh-proxy.conf').read_text()
# 关键：关掉 443 的同时必须**把 SSL 相关指令一并注释掉**，
# 否则 nginx 会因为找不到证书而拒绝启动（表现为所有请求 000）。
ssl_lines = ('ssl_certificate', 'ssl_certificate_key', 'ssl_protocols',
             'ssl_ciphers', 'ssl_prefer_server_ciphers')
out = []
for ln in s2.splitlines():
    if any(ln.lstrip().startswith(k) for k in ssl_lines):
        out.append('# ' + ln)
    else:
        out.append(ln)
s2 = '\n'.join(out) + '\n'
for a,b in [('listen 80;', f'listen {port};'),
            ('listen 443 ssl;', '# https off for test'),
            ('# listen 443 ssl;', '# https off for test'),
            # 日志路径指向沙箱目录（/dsh/log/... 在测试机上不存在）
            ('access_log /dsh/log/nginx/denied.log dsh_denied if=$dsh_deny_log;',
             f'access_log {d}/log/denied.log dsh_denied if=$dsh_deny_log;')]:
    s2 = s2.replace(a,b)
# 上游地址留待后面按回声服务的真实端口改写
(d/'conf.d/dsh-proxy.conf').write_text(s2)
PY
    # 后端回声服务（端口由 python 自行挑选，避免与残留进程抢端口）
    cat > "$E2E_DIR/echo.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = "HOST=%s\nORIGIN=%s\n" % (self.headers.get('Host','<none>'),
                                         self.headers.get('Origin','<none>'))
        b = body.encode()
        self.send_response(200); self.send_header('Content-Length',str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
srv = HTTPServer(('127.0.0.1', 0), H)
# 把真实端口写到文件，供 shell 侧改写 nginx 上游
open(sys.argv[1], 'w').write(str(srv.server_port))
srv.serve_forever()
PY
    ECHO_PORT_FILE="$E2E_DIR/echo.port"
    python3 "$E2E_DIR/echo.py" "$ECHO_PORT_FILE" & ECHO_PID=$!
    # 等回声服务把端口写出来
    for _ in $(seq 1 50); do [ -s "$ECHO_PORT_FILE" ] && break; sleep 0.1; done
    ECHO_PORT="$(cat "$ECHO_PORT_FILE" 2>/dev/null)"
    # 把上游指向回声服务的真实端口
    sed -i -e "s|proxy_pass http://127.0.0.1:[0-9]*;|proxy_pass http://127.0.0.1:${ECHO_PORT};|" \
        "$E2E_DIR/conf.d/dsh-proxy.conf"

    # 先做语法检查：配置写错时 nginx 根本起不来，
    # 若不做这一步，下面所有断言都会以 `000`（连不上）的形式失败，
    # 看不出「是配置语法错」还是「白名单判定错」。
    if ! NGINX_TEST_OUT="$(nginx -t -c "$E2E_DIR/nginx.conf" -p "$E2E_DIR" 2>&1)"; then
        printf '  \033[31mFAIL\033[0m 渲染出的 nginx 配置无法通过 nginx -t\n'
        printf '       %s\n' "$NGINX_TEST_OUT"
        FAIL=$((FAIL+1))
    else
        PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m 渲染出的配置通过 nginx -t\n'
    fi
    nginx -c "$E2E_DIR/nginx.conf" -p "$E2E_DIR" 2>/dev/null
    sleep 1
    code_for() {   # $1 = Host 头
        curl -s -o /dev/null -w '%{http_code}' -H "Host: $1" "http://127.0.0.1:18080/echo" 2>/dev/null
    }
    assert_eq "白名单域名(带端口)放行"      "200" "$(code_for 'example.com:18080')"
    assert_eq "白名单域名(无端口)放行"      "200" "$(code_for 'example.com')"
    assert_eq "白名单 IP(带端口)放行"       "200" "$(code_for '10.0.0.8:18080')"
    assert_eq "回环地址恒放行"              "200" "$(code_for '127.0.0.1:18080')"
    assert_eq "限定端口的条目在该端口放行"  "200" "$(code_for 'example.org:9443')"
    assert_eq "限定端口的条目在其他端口拒绝" "403" "$(code_for 'example.org:18080')"
    assert_eq "白名单外域名拒绝"            "403" "$(code_for 'evil.example.com')"
    assert_eq "后缀欺骗域名拒绝"            "403" "$(code_for 'example.com.evil.com')"
    assert_eq "相近 IP 拒绝"                "403" "$(code_for '10.0.0.9:18080')"
    assert_eq "未列入的子域拒绝"            "403" "$(code_for 'sub.example.com')"
    # 正则中的 . 必须转义：否则白名单里的 a.com 会顺带放行 axcom
    assert_eq "同前缀异域(axample.com)拒绝" "403" "$(code_for 'axample.com')"
    # Host / Origin 原样透传（本次改动的核心目标）
    PASSTHRU="$(curl -s -H 'Host: example.com:18080' -H 'Origin: https://example.com:18080' http://127.0.0.1:18080/echo 2>/dev/null)"
    assert_contains "Host 原样透传（含端口）" "HOST=example.com:18080" "$PASSTHRU"
    assert_contains "Origin 原样透传（不再清空）" "ORIGIN=https://example.com:18080" "$PASSTHRU"
    NOORIGIN="$(curl -s -H 'Host: example.com:18080' http://127.0.0.1:18080/echo 2>/dev/null)"
    assert_contains "无 Origin 时不发送空 Origin 头" "ORIGIN=<none>" "$NOORIGIN"
    # /health 不受白名单限制（健康探测常以 IP 直连）
    HEALTH="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example.com' http://127.0.0.1:18080/health 2>/dev/null)"
    assert_eq "/health 不受白名单限制" "200" "$HEALTH"
    # 收尾
    nginx -s stop -c "$E2E_DIR/nginx.conf" -p "$E2E_DIR" 2>/dev/null
    kill "$ECHO_PID" 2>/dev/null || true
    rm -rf "$E2E_DIR"
fi
echo

# ---------- 用例12: 模板必须仍保留 trusted-host 闸门 ----------
echo "[用例12] 模板结构（闸门不能被误删）"
assert_contains "保留 return 403 闸门"  'return 403' "$TEMPLATE_TEXT"
assert_contains "保留 map 常量占位符"   '__TRUSTED_HOST_MAP__' "$TEMPLATE_TEXT"
assert_contains "Host 透传用 \$http_host" 'proxy_set_header Host $http_host;' "$TEMPLATE_TEXT"
assert_contains "Origin 走 map 透传"    'proxy_set_header Origin $dsh_origin;' "$TEMPLATE_TEXT"
assert_not_contains "不再改写 Host 为 127.0.0.1" 'proxy_set_header Host       127.0.0.1:3080;' "$TEMPLATE_TEXT"
assert_not_contains "不再用空串清空 Origin"      'proxy_set_header Origin     "";' "$TEMPLATE_TEXT"
echo

rm -f "$HARNESS"
echo "============================================"
printf " 通过: \033[32m%d\033[0m   失败: \033[31m%d\033[0m\n" "$PASS" "$FAIL"
echo "============================================"
[ "$FAIL" -eq 0 ] || exit 1
