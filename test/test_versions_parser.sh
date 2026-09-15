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
assert_eq "插件1 完整字段" "dsh-web-lan-access|latest||web" "$(printf '%s\n' "$P1" | sed -n '1p')"
assert_eq "插件2 完整字段" "dsh-ctl|latest||web" "$(printf '%s\n' "$P1" | sed -n '2p')"
assert_eq "插件3 完整字段（scope 包名含 @ 与 /）" "@chengxianglibra/dsh-data-analysis|latest||web" "$(printf '%s\n' "$P1" | sed -n '3p')"
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
assert_eq "插件字段不受 dsh 段污染" "demo|latest||web" "$(cat /tmp/_p)"
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
assert_eq "插件 version 未被 dsh 段污染" "p1|2.3.4||web" "$(cat /tmp/_p)"
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
assert_eq "插件名引号剥离" "quoted-plugin|||web" "$(cat /tmp/_p)"
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
assert_eq "插件a" "a|1.0.0||web" "$(printf '%s\n' "$P6" | sed -n '1p')"
assert_eq "插件b" "b||https://x/b.tgz|cli" "$(printf '%s\n' "$P6" | sed -n '2p')"
assert_eq "插件c" "c|||web" "$(printf '%s\n' "$P6" | sed -n '3p')"
assert_eq "插件d（末行无后续字段）" "d|4.0.0||" "$(printf '%s\n' "$P6" | sed -n '4p')"
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
assert_eq "被注释的 version 不生效" "x|||web" "$(cat /tmp/_p)"
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

echo "============================================"
printf " 通过: \033[32m%d\033[0m   失败: \033[31m%d\033[0m\n" "$PASS" "$FAIL"
echo "============================================"
[ "$FAIL" -eq 0 ] || exit 1
