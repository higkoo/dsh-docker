#!/bin/bash
# ============================================================
# parse_versions_file 回归测试
# 覆盖：行内注释、引号、注释掉的 url、GitHub 带 # 的 URL、
#       多插件、profile 继承、无 dsh 段等场景
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../script" && pwd)"
PASS=0
FAIL=0

# 从 install-dsh.sh 中抽取解析器相关函数（不执行 main）
load_parser() {
    # 提取 extract_scalar 与 parse_versions_file 两个函数
    sed -n '/^extract_scalar()/,/^}/p;/^parse_versions_file()/,/^}/p' "$SCRIPT_DIR/install-dsh.sh"
}

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

run_case() {
    local desc="$1" yaml="$2"
    local f
    f="$(mktemp /tmp/versions_XXXX.yml)"
    printf '%s\n' "$yaml" > "$f"

    (
        eval "$(load_parser)"
        DSH_VERSION=""; DSH_URL=""; PLUGINS=""
        parse_versions_file "$f"
        echo "RESULT_VERSION=$DSH_VERSION"
        echo "RESULT_URL=$DSH_URL"
        echo "RESULT_PLUGINS<<EOF"
        printf '%s' "$PLUGINS"
        echo "EOF"
    ) > /tmp/_pres 2>/dev/null

    local ver url plugs
    ver="$(grep '^RESULT_VERSION=' /tmp/_pres | sed 's/^RESULT_VERSION=//')"
    url="$(grep '^RESULT_URL=' /tmp/_pres | sed 's/^RESULT_URL=//')"
    plugs="$(sed -n '/^RESULT_PLUGINS<<EOF$/,/^EOF$/p' /tmp/_pres | sed '1d;$d')"

    printf '%s\n' "$desc"
    echo "$ver" > /tmp/_v; echo "$url" > /tmp/_u; echo "$plugs" > /tmp/_p
    rm -f "$f"
}

echo "============================================"
echo " parse_versions_file 回归测试"
echo "============================================"
echo

# ---------- 用例1: 真实仓库配置（含行内注释）----------
echo "[用例1] 真实仓库 config/dsh/versions.yml"
(
    eval "$(load_parser)"
    parse_versions_file "${SCRIPT_DIR}/../config/dsh/versions.yml"
    echo "V=[$DSH_VERSION]"
    echo "U=[$DSH_URL]"
    echo "PLUGINS_START"
    printf '%s' "$PLUGINS"
    echo "PLUGINS_END"
) > /tmp/_c1
V1="$(grep '^V=' /tmp/_c1 | sed 's/^V=\[//;s/\]$//')"
U1="$(grep '^U=' /tmp/_c1 | sed 's/^U=\[//;s/\]$//')"
P1="$(sed -n '/^PLUGINS_START$/,/^PLUGINS_END$/p' /tmp/_c1 | sed '1d;$d')"

assert_eq "dsh 版本剥离行内注释 => latest" "latest" "$V1"
assert_eq "dsh url（注释掉的行）应为空" "" "$U1"
assert_eq "插件行数应为 3" "3" "$(printf '%s' "$P1" | grep -c .)"
assert_eq "插件1 完整字段" "dsh-web-lan-access|latest||web|" "$(printf '%s\n' "$P1" | sed -n '1p')"
assert_eq "插件2 完整字段" "dsh-ctl|latest||web|" "$(printf '%s\n' "$P1" | sed -n '2p')"
assert_eq "插件3 完整字段（scope 包名含 @ 与 /）" "@chengxianglibra/dsh-data-analysis|latest||web|false" "$(printf '%s\n' "$P1" | sed -n '3p')"
echo

# ---------- 用例2: 启用 URL 安装方式 ----------
echo "[用例2] 启用 dsh.url（URL 优先于 version）"
run_case "(setup)" 'dsh:
  version: "0.1.5-rc.1"
  url: https://registry.npmjs.com/@deepseek-ai/dsh/-/dsh-0.1.5-rc.1.tgz
plugins:
  - name: demo
    version: latest
    profile: web'
assert_eq "dsh version 保留引号内内容" "0.1.5-rc.1" "$(cat /tmp/_v)"
assert_eq "dsh url 正确解析" "https://registry.npmjs.com/@deepseek-ai/dsh/-/dsh-0.1.5-rc.1.tgz" "$(cat /tmp/_u)"
assert_eq "插件字段不受 dsh 段污染" "demo|latest||web|" "$(cat /tmp/_p)"
echo

# ---------- 用例3: 关键回归 —— 旧实现会把 url 串成 version ----------
echo "[用例3] 回归：dsh 段无 version、只有 url 时，version 不得被插件值污染"
run_case "(setup)" 'dsh:
  url: https://example.com/dsh.tgz
plugins:
  - name: p1
    version: 2.3.4
    profile: web'
assert_eq "dsh version 应为空（旧实现在此会误取 2.3.4）" "" "$(cat /tmp/_v)"
assert_eq "dsh url 正确" "https://example.com/dsh.tgz" "$(cat /tmp/_u)"
assert_eq "插件 version 未被 dsh 段污染" "p1|2.3.4||web|" "$(cat /tmp/_p)"
echo

# ---------- 用例4: URL 中含 # （git 引用）----------
echo "[用例4] URL 含 '#'（git+https://...#v1.0）不应被当注释截断"
run_case "(setup)" 'dsh:
  url: git+https://github.com/o/r.git#v1.0.0
plugins: []'
assert_eq "含 # 的 URL 完整保留" "git+https://github.com/o/r.git#v1.0.0" "$(cat /tmp/_u)"
echo

# ---------- 用例5: 单引号 + 尾部空格 ----------
echo "[用例5] 单引号包裹与尾部空白处理"
run_case "(setup)" "dsh:
  version: '0.2.0'   
plugins:
  - name: 'quoted-plugin'
    profile: 'web'"
assert_eq "单引号剥离" "0.2.0" "$(cat /tmp/_v)"
assert_eq "插件名引号剥离" "quoted-plugin|||web|" "$(cat /tmp/_p)"
echo

# ---------- 用例6: 多插件顺序与边界 ----------
echo "[用例6] 多插件（4个）解析完整性与顺序"
run_case "(setup)" 'dsh:
  version: latest
plugins:
  - name: a
    version: 1.0.0
    profile: web
  - name: b
    url: https://x/b.tgz
    profile: cli
  - name: c
    profile: web
  - name: d
    version: 4.0.0'
P6="$(cat /tmp/_p)"
assert_eq "插件总数" "4" "$(printf '%s' "$P6" | grep -c .)"
assert_eq "插件a" "a|1.0.0||web|" "$(printf '%s\n' "$P6" | sed -n '1p')"
assert_eq "插件b" "b||https://x/b.tgz|cli|" "$(printf '%s\n' "$P6" | sed -n '2p')"
assert_eq "插件c" "c|||web|" "$(printf '%s\n' "$P6" | sed -n '3p')"
assert_eq "插件d（末行无后续字段）" "d|4.0.0|||" "$(printf '%s\n' "$P6" | sed -n '4p')"
echo

# ---------- 用例7: 注释与空行干扰 ----------
echo "[用例7] 注释行、空行、缩进注释不得影响解析"
run_case "(setup)" '# 顶部注释
dsh:
  # 这是 dsh 段内的注释
  version: latest        # 行尾注释

plugins:
  # 插件段注释
  - name: x
    # version: 9.9.9   <- 被注释掉的版本
    profile: web'
assert_eq "版本为 latest（未被注释干扰）" "latest" "$(cat /tmp/_v)"
assert_eq "被注释的 version 不生效" "x|||web|" "$(cat /tmp/_p)"
echo

# ---------- 用例8: 无 plugins 段 ----------
echo "[用例8] 无 plugins 段时 PLUGINS 为空"
run_case "(setup)" 'dsh:
  version: 1.0.0'
assert_eq "version 正常" "1.0.0" "$(cat /tmp/_v)"
assert_eq "PLUGINS 为空" "" "$(cat /tmp/_p)"
echo

# ---------- 用例9: 解析器在 set -e 下不得中途退出 ----------
# 回归：旧实现在 dsh.url 缺失时 grep 返回非零，set -e 会直接杀掉脚本
echo "[用例9] 回归：set -e 下解析器与主流程不得中途退出"
cat > /tmp/_sete_test.sh <<'SETEEOF'
#!/bin/bash
set -e
set -o pipefail
eval "$(sed -n '/^extract_scalar()/,/^}/p;/^parse_versions_file()/,/^}/p' "$1")"
parse_versions_file "$2"
echo "PARSE_OK version=[$DSH_VERSION] url=[$DSH_URL]"
# 模拟 main() 中的插件列表打印（herestring 形态）
if [ -n "$PLUGINS" ]; then
    while IFS='|' read -r name version url profile || [ -n "$name" ]; do
        [ -n "$name" ] || continue
        echo "LIST $name"
    done <<< "$PLUGINS"
fi
echo "ALL_DONE"
SETEEOF
chmod +x /tmp/_sete_test.sh

# 场景：dsh 段只有 version，没有 url（旧实现在此崩溃）
SETE_OUT="$(/tmp/_sete_test.sh "$SCRIPT_DIR/install-dsh.sh" "$SCRIPT_DIR/../config/dsh/versions.yml" 2>&1)"
SETE_RC=$?
assert_eq "set -e 下脚本正常退出（退出码 0）" "0" "$SETE_RC"
assert_eq "解析后打印 PARSE_OK" "1" "$(printf '%s' "$SETE_OUT" | grep -c 'PARSE_OK')"
assert_eq "主流程执行到 ALL_DONE（不再中途退出）" "1" "$(printf '%s' "$SETE_OUT" | grep -c 'ALL_DONE')"
assert_eq "插件列表打印 3 条" "3" "$(printf '%s' "$SETE_OUT" | grep -c '^LIST ')"
echo

# ---------- 用例10: read 到 EOF 不得被 set -e 中断 ----------
echo "[用例10] 回归：末行无换行的配置文件也能被完整解析"
NONL="$(mktemp /tmp/versions_nonl_XXXX.yml)"
printf 'dsh:\n  version: 9.9.9\nplugins:\n  - name: tail-plugin\n    profile: web' > "$NONL"   # 故意不加结尾换行
NONL_OUT="$(/tmp/_sete_test.sh "$SCRIPT_DIR/install-dsh.sh" "$NONL" 2>&1)"
NONL_RC=$?
assert_eq "无结尾换行时正常退出" "0" "$NONL_RC"
assert_eq "版本解析正确" "1" "$(printf '%s' "$NONL_OUT" | grep -c 'version=\[9.9.9\]')"
assert_eq "末行插件被捕获" "1" "$(printf '%s' "$NONL_OUT" | grep -c '^LIST tail-plugin')"
rm -f "$NONL"
echo

# ---------- 用例11: 插件名校验必须带词边界 ----------
# install-dsh.sh 与 entrypoint.sh 各有一份「插件是否已注册」的校验，
# 两处表达式必须一致，且必须带词边界 —— 否则 dsh-ctl 会在 dsh-ctl-helper
# 存在时被误判为「已注册」，导致真正缺失的插件不被补装。
echo "[用例11] 插件名校验词边界（dsh-ctl 不得匹配 dsh-ctl-helper）"
WB_LIST_WITH_HELPER='dsh-web-lan-access@1.3.2
dsh-ctl-helper@9.9.9'
WB_LIST_REAL='dsh-web-lan-access@1.3.2
dsh-ctl@0.1.1'

# 校验两个脚本都含词边界写法，且都不再有无词边界的旧写法。
# 用固定子串判断，避免在测试里嵌套正则转义（易错且难读）。
WB_SUBSTR='(^|[^A-Za-z0-9._-])'          # 词边界表达式独有的片段
assert_eq "install-dsh.sh 使用词边界表达式" "1" "$(grep -cF "$WB_SUBSTR" "$SCRIPT_DIR/install-dsh.sh")"
assert_eq "entrypoint.sh 使用词边界表达式" "1" "$(grep -cF "$WB_SUBSTR" "$SCRIPT_DIR/entrypoint.sh")"
# 旧写法：grep -q "$name"（无 -E、无边界）——两脚本都不该再有。
# 注意排除注释行（注释里可能提到这个反面写法作为说明）。
for f in install-dsh.sh entrypoint.sh; do
    old_cnt="$(grep -v '^[[:space:]]*#' "$SCRIPT_DIR/$f" | grep -cF 'grep -q "$name"')"
    assert_eq "$f 已无无词边界写法（代码中）" "0" "$old_cnt"
done

# 行为验证：复刻新表达式的判定
wb_match() {
    printf '%s\n' "$1" | grep -qE "(^|[^A-Za-z0-9._-])dsh-ctl([^A-Za-z0-9._-]|\$)"
}
if wb_match "$WB_LIST_WITH_HELPER"; then
    assert_eq "仅存在 dsh-ctl-helper 时不得判定 dsh-ctl 已注册" "未匹配" "匹配"
else
    assert_eq "仅存在 dsh-ctl-helper 时不得判定 dsh-ctl 已注册" "未匹配" "未匹配"
fi
if wb_match "$WB_LIST_REAL"; then
    assert_eq "dsh-ctl 确实存在时应判定为已注册" "匹配" "匹配"
else
    assert_eq "dsh-ctl 确实存在时应判定为已注册" "匹配" "未匹配"
fi
echo

# ============================================================
# 用例12：访问地址必须保留 token，且地址块标题可定制
#
# 回归背景：parse_dsh_access 曾用 sed 主动删掉 ?token=，
# 结果「容器内直连 / LAN 访问」两行复制即 401；
# 另外看护期复用「已就绪」标题，与「只是 token 变了」的语义不符。
# ============================================================
echo "[用例12] 访问地址保留 token 且标题可定制"
ACCESS_TMP="$(mktemp /tmp/access_XXXX.log)"
ACCESS_SCRIPT="$(mktemp /tmp/access_XXXX.sh)"
cat > "$ACCESS_SCRIPT" <<'ACCESS_EOF'
#!/usr/bin/env bash
DSH_LOG="$1"; DSH_HTTP_PORT=9080; DSH_HTTPS_PORT=9443
ACCESS_EOF
{
    sed -n '/^parse_dsh_access()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^print_access_info()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    cat <<'ACCESS_EOF'
parse_dsh_access
printf 'TOKEN=%s\n' "$TOKEN"
printf 'WEB_HAS_TOKEN=%s\n' "$(printf '%s' "$WEB_URL"  | grep -c 'token=TK1')"
printf 'LAN_HAS_TOKEN=%s\n' "$(printf '%s' "$LAN_URL"  | grep -c 'token=TK1')"
printf 'TITLE_DEFAULT=%s\n' "$(print_access_info "[5/6]" | sed -n '2p')"
printf 'TITLE_CUSTOM=%s\n'  "$(print_access_info "[看护]" "DSH 已重启，token 已更新，新访问地址" | sed -n '2p')"
ACCESS_EOF
} >> "$ACCESS_SCRIPT"

printf 'dsh web: http://127.0.0.1:3080/?token=TK1 (LAN: http://10.0.0.9:3080/?token=TK1)\n' > "$ACCESS_TMP"
ACCESS_OUT="$(bash "$ACCESS_SCRIPT" "$ACCESS_TMP" 2>/dev/null)"
assert_eq "token 解析正确"           "TOKEN=TK1"      "$(printf '%s' "$ACCESS_OUT" | sed -n '1p')"
assert_eq "容器内直连保留 token"      "WEB_HAS_TOKEN=1" "$(printf '%s' "$ACCESS_OUT" | sed -n '2p')"
assert_eq "LAN 访问保留 token"       "LAN_HAS_TOKEN=1" "$(printf '%s' "$ACCESS_OUT" | sed -n '3p')"
assert_eq "默认标题为「已就绪」"      "TITLE_DEFAULT=  [5/6] DSH 已就绪，请访问:" "$(printf '%s' "$ACCESS_OUT" | sed -n '4p')"
assert_eq "看护标题可定制"           "TITLE_CUSTOM=  [看护] DSH 已重启，token 已更新，新访问地址:" "$(printf '%s' "$ACCESS_OUT" | sed -n '5p')"
rm -f "$ACCESS_TMP" "$ACCESS_SCRIPT"
echo

# ============================================================
# 用例13：DSH_PID 必须指向 dsh 进程，而非日志转发管道
#
# 回归背景：`DSH_PID=$!` 曾紧跟 `tail|sed|grep &`，而管道后台作业的 $!
# 是**管道最后一段（grep）的 PID**，于是 DSH_PID 记成了 grep：
# kill -0 永远成功 → DSH 真崩溃也判不出「进程已退出」→ 容器永卡启动态。
# ============================================================
echo "[用例13] DSH_PID 必须指向 dsh 进程，而非日志转发进程"
PID_TEST="$(mktemp /tmp/pidtest_XXXX.sh)"
{
    echo '#!/usr/bin/env bash'
    echo '# dsh 用 sleep 冒充真身；其余语句直接从 entrypoint.sh 的 start_dsh 抽取，'
    echo '# 保证测的是**源码真实顺序**，而不是手写的正确版本。'
    echo 'dsh() { exec sleep 300; }'
    echo 'DSH_ROOT=/tmp; DSH_LOG=/tmp/pidtest_log_$$.txt; touch "$DSH_LOG"; RUN_DIR=/tmp'
    echo 'NGINX_LOG_DIR=/tmp; DSH_START_COUNT=0; sync_dsh_log_alias() { :; }; DSH_PID=""'
    # start_dsh 依赖日志转发相关的一整套函数，按源码原样抽取。
    sed -n '/^LOG_TAIL_PID=""/,/^LOG_FILES_SNAPSHOT=""/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^collect_log_files()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^start_log_follow()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^log_files_changed()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^stop_log_follow()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^collect_tail_children()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^collect_pids_by_ppid()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    # 抽取 start_dsh 的完整函数体（含 dsh 启动、DSH_PID 赋值、日志转发），
    # 顺序完全由源码决定 —— 旧顺序会让 DSH_PID 最终指向转发进程。
    sed -n '/^start_dsh()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    echo 'start_dsh >/dev/null 2>&1'
    echo 'echo "DSH_PID_NAME=$(cat /proc/$DSH_PID/comm 2>/dev/null)"'
    echo 'echo "TAIL_PID_SET=$([ -n "$LOG_TAIL_PID" ] && echo yes || echo no)"'
    echo 'kill "$DSH_PID" 2>/dev/null || true; sleep 1'
    echo 'kill -0 "$DSH_PID" 2>/dev/null && echo "AFTER_KILL=alive" || echo "AFTER_KILL=dead"'
    echo 'stop_log_follow'
    echo '# 只统计本次测试那一份日志对应的 tail，避免被历史残留干扰'
    echo 'LEFT=0'
    echo 'for _p in /proc/[0-9]*; do'
    echo '  _c=$(tr "\0" " " < "$_p/cmdline" 2>/dev/null) || continue'
    echo '  case "$_c" in *"tail -F "*) case "$_c" in *"$DSH_LOG"*) LEFT=$((LEFT+1));; esac;; esac'
    echo 'done'
    echo 'echo "ORPHAN_TAIL=$LEFT"'
    echo 'rm -f "$DSH_LOG"'
} > "$PID_TEST"
# ⚠ 输出到文件而不是 $( ) 命令替换：日志转发 supervisor 是后台子 shell，
#   若用命令替换，bash 会等管道 stdout 关闭才返回 —— 而 supervisor 一直
#   持有它，形成死等。重定向到文件 + </dev/null 才不会被它拖住。
PID_OUT_FILE="$(mktemp /tmp/pidout_XXXX.txt)"
timeout 30 bash "$PID_TEST" </dev/null > "$PID_OUT_FILE" 2>/dev/null || true
PID_OUT="$(cat "$PID_OUT_FILE")"
assert_eq "DSH_PID 指向 dsh 真身（非转发进程）" "DSH_PID_NAME=sleep" "$(printf '%s' "$PID_OUT" | sed -n '1p')"
assert_eq "日志转发 supervisor 已记录"          "TAIL_PID_SET=yes"  "$(printf '%s' "$PID_OUT" | sed -n '2p')"
assert_eq "dsh 退出后 kill -0 判据生效"         "AFTER_KILL=dead"   "$(printf '%s' "$PID_OUT" | sed -n '3p')"
assert_eq "停止转发后不留孤儿 tail"              "ORPHAN_TAIL=0"     "$(printf '%s' "$PID_OUT" | sed -n '4p')"
rm -f "$PID_TEST" "$PID_OUT_FILE"
echo

# ============================================================
# 用例14：stop_log_follow 必须**及时返回**，绝不能挂起
#
# 回归背景：该函数（旧名 stop_dsh_log_follow）曾用 `wait`。管道是一个 job，
# kill 掉尾端后其余段仍存活，`wait` 会等到整个 job 结束，
# 在顶层（set -e）表现为**永久挂起** → 脚本走不到 [6/6] 看护循环 →
# 容器永久 running、DSH 崩溃也无反应。v0.4.0 / v0.4.1 均有此缺陷。
#
# 判定方式：起真实多文件转发，调用函数，用后台 watchdog 计时。
# 函数若在限定时间内没返回，即判定失败。
# ============================================================
echo "[用例14] stop_log_follow 必须及时返回（不得挂起）"
HANG_TEST="$(mktemp /tmp/hangtest_XXXX.sh)"
{
    echo '#!/usr/bin/env bash'
    echo 'set -e'
    echo 'DSH_ROOT=/tmp; DSH_LOG=/tmp/hangtest_log_$$.txt; touch "$DSH_LOG"'
    echo 'NGINX_LOG_DIR=/tmp'
    sed -n '/^LOG_TAIL_PID=""/,/^LOG_FILES_SNAPSHOT=""/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^collect_log_files()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^start_log_follow()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^log_files_changed()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^stop_log_follow()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^collect_tail_children()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^collect_pids_by_ppid()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    echo 'start_log_follow'
    echo '# watchdog：3 秒后若主流程还没写入 done 标记，就认定挂起'
    echo 'DONE_F=/tmp/hangtest_done_$$.txt; rm -f "$DONE_F"'
    echo '( sleep 3; [ -f "$DONE_F" ] || { echo HUNG > /tmp/hangtest_hung_$$.txt; kill 0 2>/dev/null; } ) &'
    echo 'WD=$!'
    echo 'stop_log_follow'
    echo 'echo "AFTER_STOP=ok" > "$DONE_F"'
    echo 'kill "$WD" 2>/dev/null || true'
    echo 'echo "RETURNED=yes"'
    echo 'rm -f "$DSH_LOG"'
} > "$HANG_TEST"
HUNG_MARK="/tmp/hangtest_hung_$$.txt"; rm -f "$HUNG_MARK"
# 同样用文件重定向，避免被 supervisor 的 stdout 拖住（见用例 13 的说明）。
HANG_OUT_FILE="$(mktemp /tmp/hangout_XXXX.txt)"
timeout 10 bash "$HANG_TEST" </dev/null > "$HANG_OUT_FILE" 2>/dev/null || true
HANG_OUT="$(cat "$HANG_OUT_FILE")"
if [ -f "$HUNG_MARK" ]; then
    HANG_RESULT="HUNG"
    rm -f "$HUNG_MARK"
elif printf '%s' "$HANG_OUT" | grep -q "RETURNED=yes"; then
    HANG_RESULT="RETURNED"
else
    HANG_RESULT="UNKNOWN"
fi
assert_eq "stop_log_follow 在 3s 内返回（未挂起）" "RETURNED" "$HANG_RESULT"
rm -f "$HANG_TEST" "$HANG_OUT_FILE"
# 兜底：清掉用例可能残留的转发进程
for _p in /proc/[0-9]*; do
    [ -r "$_p/cmdline" ] || continue
    _c=$(tr '\0' ' ' < "$_p/cmdline" 2>/dev/null) || continue
    [ "$(cat "$_p/comm" 2>/dev/null)" = "tail" ] || continue
    case "$_c" in *"/tmp/log/"*) kill "${_p#/proc/}" 2>/dev/null || true;; esac
done
echo

# ============================================================
# 用例15：日志转发必须覆盖全部日志文件、带时间戳、并能纳入新建文件
#
# 回归背景（v0.4.2 修）：
#   1. 旧实现只跟 $DSH_LOG 一个文件，容器启动到 DSH 就绪前（实测约 9 分钟）
#      nginx / 插件日志在 docker logs 里完全不可见 → 用户以为「日志不刷新」；
#   2. 旧实现用 glob 一次性快照，运行中**新建**的日志文件（新装插件）
#      永远不会被转发；
#   3. 转发行没有时间戳，多文件混排时看不出发生时间。
# ============================================================
echo "[用例15] 日志转发覆盖全部文件 / 带时间戳 / 纳入新建文件"
NL_ROOT="$(mktemp -d /tmp/nltest_XXXX)"
mkdir -p "$NL_ROOT/log/dsh" "$NL_ROOT/log/plugins"
echo "旧内容" > "$NL_ROOT/log/dsh/dsh-web.log"
echo "插件内容" > "$NL_ROOT/log/plugins/p1.log"

NL_TEST="$(mktemp /tmp/nltest_sh_XXXX.sh)"
{
    echo '#!/usr/bin/env bash'
    echo "DSH_ROOT='$NL_ROOT'"
    echo "DSH_LOG='$NL_ROOT/log/dsh/dsh-web.log'"
    echo "NGINX_LOG_DIR='$NL_ROOT/log/nginx'"
    sed -n '/^LOG_TAIL_PID=""/,/^LOG_FILES_SNAPSHOT=""/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^collect_log_files()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^start_log_follow()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^log_files_changed()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^stop_log_follow()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^collect_tail_children()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    sed -n '/^collect_pids_by_ppid()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh"
    # 用主管道的方式起转发，并把输出收集到文件（避免命令替换被拖住）
    echo 'start_log_follow'
    echo 'sleep 1'
    echo "FCOUNT=\$(printf '%s' \"\$LOG_FILES_SNAPSHOT\" | tr ' ' '\n' | grep -c .)"
    echo 'echo "FILE_COUNT=$FCOUNT"'
    echo "echo '转发内容A' >> '$NL_ROOT/log/dsh/dsh-web.log'"
    echo "echo '插件内容A' >> '$NL_ROOT/log/plugins/p1.log'"
    echo 'sleep 1'
    echo "mkdir -p '$NL_ROOT/log/newplug'"
    echo "echo 'new' > '$NL_ROOT/log/newplug/new.log'"
    echo 'if log_files_changed; then echo "CHANGED=yes"; else echo "CHANGED=no"; fi'
    echo 'stop_log_follow'
    echo 'sleep 1'
    echo '# 残留判定：只认 comm == tail 且命令行含本次测试目录'
    echo 'LEFT=0'
    echo 'for _p in /proc/[0-9]*; do'
    echo '  [ -r "$_p/cmdline" ] || continue'
    echo '  [ "$(cat "$_p/comm" 2>/dev/null)" = "tail" ] || continue'
    echo '  _c=$(tr "\0" " " < "$_p/cmdline" 2>/dev/null) || continue'
    echo "  case \"\$_c\" in *'$NL_ROOT/log/'*) LEFT=\$((LEFT+1));; esac"
    echo 'done'
    echo 'echo "ORPHAN=$LEFT"'
} > "$NL_TEST"

NL_OUT_FILE="$(mktemp /tmp/nlout_XXXX.txt)"
timeout 30 bash "$NL_TEST" </dev/null > "$NL_OUT_FILE" 2>/dev/null || true
NL_OUT="$(cat "$NL_OUT_FILE")"
rm -f "$NL_TEST" "$NL_OUT_FILE"

# 断言 1：覆盖全部日志文件（本次目录下有 2 个 .log）
assert_eq "转发覆盖全部日志文件（2 个）" "FILE_COUNT=2" "$(printf '%s' "$NL_OUT" | grep '^FILE_COUNT=' | head -1)"
# 断言 2：每行带 HH:MM:SS 时间戳（且来自两个不同文件的内容都出现了）
TIMESTAMPED="$(printf '%s' "$NL_OUT" | grep -cE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] ')"
[ "$TIMESTAMPED" -ge 2 ] && TS_RESULT="ok" || TS_RESULT="missing($TIMESTAMPED)"
assert_eq "转发内容带 [HH:MM:SS] 时间戳" "ok" "$TS_RESULT"
printf '%s' "$NL_OUT" | grep -q '转发内容A' && GOT_DSH=yes || GOT_DSH=no
printf '%s' "$NL_OUT" | grep -q '插件内容A' && GOT_PLUGIN=yes || GOT_PLUGIN=no
assert_eq "dsh 日志内容被转发"    "yes" "$GOT_DSH"
assert_eq "插件日志内容被转发"     "yes" "$GOT_PLUGIN"
# 断言 3：新建文件能被检测到
assert_eq "新建日志文件被检测到"  "CHANGED=yes" "$(printf '%s' "$NL_OUT" | grep '^CHANGED=' | head -1)"
# 断言 4：清理干净
assert_eq "全覆盖转发同样不留孤儿" "ORPHAN=0" "$(printf '%s' "$NL_OUT" | grep '^ORPHAN=' | head -1)"
rm -rf "$NL_ROOT"

# ---------- 用例16: enabled 字段解析 ----------
echo
echo "[用例16] enabled 字段解析（缺省即启用）"
run_case "enabled 字段用例" 'dsh:
  version: latest
plugins:
  - name: with-true
    version: latest
    enabled: true
  - name: with-false
    version: latest
    enabled: false
  - name: no-enabled
    version: latest
  - name: quoted-false
    version: latest
    enabled: "false"
  - name: inline-comment
    version: latest   # 保留注释
    enabled: true     # 行内注释应被剥离
'
P16="$(cat /tmp/_p)"
assert_eq "enabled 用例插件总数" "5" "$(printf '%s' "$P16" | grep -c .)"
assert_eq "enabled: true 解析"        "with-true|latest|||true"        "$(printf '%s\n' "$P16" | sed -n '1p')"
assert_eq "enabled: false 解析"       "with-false|latest|||false"      "$(printf '%s\n' "$P16" | sed -n '2p')"
assert_eq "缺省 enabled 为空（视为启用）" "no-enabled|latest|||"        "$(printf '%s\n' "$P16" | sed -n '3p')"
assert_eq "引号包裹的 false 剥离引号"  "quoted-false|latest|||false"    "$(printf '%s\n' "$P16" | sed -n '4p')"
assert_eq "enabled 行内注释被剥离"     "inline-comment|latest|||true"   "$(printf '%s\n' "$P16" | sed -n '5p')"
# 关键回归：version 行内注释不得把 enabled 吃掉
assert_eq "version 行内注释仍正确剥离"  "latest" "$(printf '%s\n' "$P16" | sed -n '5p' | cut -d'|' -f2)"

# ---------- 用例17: plugin_enabled 判定函数 ----------
echo
echo "[用例17] plugin_enabled 判定（大小写与别名 + 环境变量覆盖）"
load_enabled_check() {
    (
        eval "$(sed -n '/^plugin_enabled()/,/^}/p' "$SCRIPT_DIR/install-dsh.sh")"
        for v in "" "true" "True" "TRUE" "1" "yes" "YES" "on" "ON" "false" "False" "0" "no" "off" "garbage"; do
            if plugin_enabled "some-plugin" "$v"; then r="on"; else r="off"; fi
            # 空值用 <empty> 占位，避免行首丢失
            printf '%s=%s\n' "${v:-<empty>}" "$r"
        done
    )
}
EN_OUT="$(load_enabled_check)"
assert_eq "缺省空值 => 启用"      "on"  "$(printf '%s' "$EN_OUT" | grep '^<empty>=' | cut -d= -f2)"
assert_eq "true => 启用"          "on"  "$(printf '%s' "$EN_OUT" | grep '^true=' | cut -d= -f2)"
assert_eq "True（大小写不敏感）"   "on"  "$(printf '%s' "$EN_OUT" | grep '^True=' | cut -d= -f2)"
assert_eq "TRUE（全大写）"        "on"  "$(printf '%s' "$EN_OUT" | grep '^TRUE=' | cut -d= -f2)"
assert_eq "1 => 启用"             "on"  "$(printf '%s' "$EN_OUT" | grep '^1=' | cut -d= -f2)"
assert_eq "yes => 启用"           "on"  "$(printf '%s' "$EN_OUT" | grep '^yes=' | cut -d= -f2)"
assert_eq "on => 启用"            "on"  "$(printf '%s' "$EN_OUT" | grep '^on=' | cut -d= -f2)"
assert_eq "false => 跳过"         "off" "$(printf '%s' "$EN_OUT" | grep '^false=' | cut -d= -f2)"
assert_eq "False => 跳过"         "off" "$(printf '%s' "$EN_OUT" | grep '^False=' | cut -d= -f2)"
assert_eq "0 => 跳过"             "off" "$(printf '%s' "$EN_OUT" | grep '^0=' | cut -d= -f2)"
assert_eq "no => 跳过"            "off" "$(printf '%s' "$EN_OUT" | grep '^no=' | cut -d= -f2)"
assert_eq "off => 跳过"           "off" "$(printf '%s' "$EN_OUT" | grep '^off=' | cut -d= -f2)"
assert_eq "未知值 => 保守跳过"     "off" "$(printf '%s' "$EN_OUT" | grep '^garbage=' | cut -d= -f2)"

# 环境变量覆盖：DSH_ENABLE_DATA_ANALYSIS 优先级最高
DA="@chengxianglibra/dsh-data-analysis"
env_check() {  # $1=环境变量值(可为空串表示不设)  $2=yml 里 enabled 值
    (
        eval "$(sed -n '/^plugin_enabled()/,/^}/p' "$SCRIPT_DIR/install-dsh.sh")"
        if [ "$1" = "__UNSET__" ]; then unset DSH_ENABLE_DATA_ANALYSIS
        else export DSH_ENABLE_DATA_ANALYSIS="$1"; fi
        if plugin_enabled "$DA" "$2"; then echo on; else echo off; fi
    )
}
assert_eq "未设环境变量 + yml false => 跳过"   "off" "$(env_check __UNSET__ false)"
assert_eq "未设环境变量 + yml true  => 启用"   "on"  "$(env_check __UNSET__ true)"
assert_eq "环境变量 true 覆盖 yml false => 启用" "on" "$(env_check true false)"
assert_eq "环境变量 false 覆盖 yml true => 跳过" "off" "$(env_check false true)"
assert_eq "环境变量空串不覆盖 yml true => 启用"  "on"  "$(env_check "" true)"
# 环境变量只对指定插件生效，不得波及其他插件
other_check() {
    (
        eval "$(sed -n '/^plugin_enabled()/,/^}/p' "$SCRIPT_DIR/install-dsh.sh")"
        export DSH_ENABLE_DATA_ANALYSIS="true"
        if plugin_enabled "some-other-plugin" "false"; then echo on; else echo off; fi
    )
}
assert_eq "环境变量不影响其他插件（other=false 仍跳过）" "off" "$(other_check)"

# ---------- 用例18: 真实仓库配置 —— 开关生效且配置保留 ----------
echo
echo "[用例18] 真实 versions.yml：data-analysis 关闭且配置完整"
REAL_YML="$SCRIPT_DIR/../config/dsh/versions.yml"
run_case "真实配置" "$(cat "$REAL_YML")"
P18="$(cat /tmp/_p)"
assert_eq "真实配置插件行数仍为 3（配置保留）" "3" "$(printf '%s' "$P18" | grep -c .)"
assert_eq "核心插件1 默认启用"        "dsh-web-lan-access|latest||web|"            "$(printf '%s\n' "$P18" | sed -n '1p')"
assert_eq "核心插件2 默认启用"        "dsh-ctl|latest||web|"                       "$(printf '%s\n' "$P18" | sed -n '2p')"
assert_eq "data-analysis 已关闭但配置保留" "@chengxianglibra/dsh-data-analysis|latest||web|false" "$(printf '%s\n' "$P18" | sed -n '3p')"
# 配置文件里必须仍能看到完整的 name / version / profile 三要素
for k in "name: '@chengxianglibra/dsh-data-analysis'" "version: latest" "profile: web"; do
    grep -qF "$k" "$REAL_YML" && GOT=yes || GOT=no
    assert_eq "配置保留字段: $k" "yes" "$GOT"
done

# ---------- 用例19: 跨脚本的注册校验表达式必须逐字一致 ----------
echo
echo "[用例19] 跨脚本一致性（注册校验正则）"
RE_INSTALL="$(grep -oE 'grep -qE "\([^"]+\)' "$SCRIPT_DIR/install-dsh.sh" | head -1)"
RE_ENTRY="$(grep -oE 'grep -qE "\([^"]+\)' "$SCRIPT_DIR/entrypoint.sh" | head -1)"
assert_eq "install-dsh.sh 与 entrypoint.sh 的注册正则逐字一致" "$RE_INSTALL" "$RE_ENTRY"
[ -n "$RE_INSTALL" ] && assert_eq "正则确实被抽到（非空）" "yes" "yes" || assert_eq "正则确实被抽到（非空）" "yes" "no"

# ---------- 用例20: entrypoint 的 plugin_enabled_in_versions ----------
# 抽取 entrypoint.sh 里的该函数，指向临时 yml 文件求值。
# 注意该函数读 ${DSH_ROOT}/config/dsh/versions.yml，需临时搭建目录树。
echo
echo "[用例20] entrypoint 单插件开关解析（与安装侧同源）"

PROBE_ROOT="$(mktemp -d /tmp/root_XXXX)"
mkdir -p "$PROBE_ROOT/config/dsh"
write_yml() { printf '%s\n' "$1" > "$PROBE_ROOT/config/dsh/versions.yml"; }
check_enabled() {  # $1=插件名  $2=yml内容
    write_yml "$2"
    (
        DSH_ROOT="$PROBE_ROOT"
        eval "$(sed -n '/^plugin_enabled_in_versions()/,/^}/p' "$SCRIPT_DIR/entrypoint.sh")"
        plugin_enabled_in_versions "$1"
    )
}

YML_MIX='dsh:
  version: latest
plugins:
  - name: plugin-on
    version: latest
    enabled: true
  - name: plugin-off
    version: latest
    enabled: false
  - name: plugin-default
    version: latest
  - name: "@scope/plugin-off"
    version: latest
    enabled: "false"
  - name: plugin-trailing
    version: latest
    enabled: true   # 行内注释

after:
  version: 9.9.9'

assert_eq "enabled: true   => true"   "true"  "$(check_enabled plugin-on "$YML_MIX")"
assert_eq "enabled: false  => false"  "false" "$(check_enabled plugin-off "$YML_MIX")"
assert_eq "缺省 enabled    => true"   "true"  "$(check_enabled plugin-default "$YML_MIX")"
assert_eq "带 scope 的包名 + 引号 false" "false" "$(check_enabled '@scope/plugin-off' "$YML_MIX")"
assert_eq "enabled 行内注释被剥离"      "true"  "$(check_enabled plugin-trailing "$YML_MIX")"
# 不存在的插件必须回退为 true（缺省即启用），避免误判导致插件被莫名跳过
assert_eq "插件不存在     => true（回退）" "true" "$(check_enabled not-exist "$YML_MIX")"
# 段外同名 key 不得串扰：after: 段之后的 enabled 不应被读到
assert_eq "跨段不串扰（after 段后无 enabled）" "true" "$(check_enabled plugin-default "$YML_MIX")"

# 关键回归：某插件的 enabled 不得泄漏给下一个未写 enabled 的插件
YML_LEAK='plugins:
  - name: first-off
    version: latest
    enabled: false
  - name: second-default
    version: latest
  - name: third-off
    version: latest
    enabled: false'
assert_eq "enabled 不向下泄漏（first）"  "false" "$(check_enabled first-off "$YML_LEAK")"
assert_eq "enabled 不向下泄漏（second）" "true"  "$(check_enabled second-default "$YML_LEAK")"
assert_eq "enabled 不向下泄漏（third）"  "false" "$(check_enabled third-off "$YML_LEAK")"

# 真实仓库 yml：data-analysis 必须为 false，核心插件为 true
REAL_RESULT="$(check_enabled '@chengxianglibra/dsh-data-analysis' "$(cat "$SCRIPT_DIR/../config/dsh/versions.yml")")"
assert_eq "真实 yml：data-analysis => false" "false" "$REAL_RESULT"
REAL_CORE="$(check_enabled 'dsh-ctl' "$(cat "$SCRIPT_DIR/../config/dsh/versions.yml")")"
assert_eq "真实 yml：dsh-ctl => true（缺省）" "true" "$REAL_CORE"
rm -rf "$PROBE_ROOT"

echo
echo "============================================"
printf " 通过: \033[32m%d\033[0m   失败: \033[31m%d\033[0m\n" "$PASS" "$FAIL"
echo "============================================"
[ "$FAIL" -eq 0 ] || exit 1
