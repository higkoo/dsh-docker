#!/bin/bash
set -e
# pipefail: 保证 `dsh plugin add ... | tee` 中 dsh 的真实退出码不被 tee 吞掉
set -o pipefail

# ============================================================
# DSH 及插件安装脚本
#
# 读取 config/dsh/versions.yml，按配置安装 DSH 与插件。
# 支持两种方式（可混用）：
#   1. 组件名 + 版本号  → npm install -g 包名@版本
#   2. 直接指定 URL     → npm install -g URL
# ============================================================

DSH_ROOT="${DSH_ROOT:-/dsh}"

VERSIONS_FILE="${DSH_ROOT}/config/dsh/versions.yml"
LOG_DIR="${DSH_ROOT}/log/dsh"
PLUGIN_LOG_DIR="${DSH_ROOT}/log/plugins"

mkdir -p "$LOG_DIR" "$PLUGIN_LOG_DIR"

# ------------------------------------------------------------
# 提取标量值：剥离行内注释、引号与首尾空白
#   latest        # 使用 latest    →  latest
# 注意：URL 中可能含 '#'（如 git+https://host/repo#tag），
#       因此仅当 '#' 前存在空白时才视为注释起始。
# ------------------------------------------------------------
extract_scalar() {
    local raw="$1"

    # 剥离行内注释：'#' 之前须为空白（或 '#' 位于行首）
    if [[ "$raw" =~ ^[[:space:]]*# ]]; then
        raw=""
    elif [[ "$raw" =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]]; then
        raw="${BASH_REMATCH[1]}"
    fi

    # 先去首尾空白，再剥引号（顺序不可颠倒：'v' 加尾部空格需先 trim）
    raw="$(echo "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    raw="${raw%\"}"; raw="${raw#\"}"
    raw="${raw%\'}"; raw="${raw#\'}"

    # 剥引号后可能再次出现空白，再 trim 一次
    raw="$(echo "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    printf '%s' "$raw"
}

# ------------------------------------------------------------
# 解析版本配置文件，输出到全局变量：
#   DSH_VERSION / DSH_URL  —— 仅取 dsh: 段内的字段
#   PLUGINS                —— 每行 "name|version|url|profile|enabled"
#
# 字段解析严格限定在所属缩进段内，避免 dsh 段与 plugins 段的
# version:/url: 互相污染。解析器会自动剥离行尾注释。
#
# enabled 语义（缺省即启用，保证老配置无需改动）：
#   不写 enabled        → true（启用）
#   enabled: true       → 启用
#   enabled: false      → 跳过安装，但配置区块完整保留
# 本文件是纯 bash 正则解析，不经过 YAML 库，故 "false" 就是字符串，
# 直接字符串比较即可（YAML 库会把 false 解析成布尔，注意区分）。
# ------------------------------------------------------------
parse_versions_file() {
    local file="$1"

    DSH_VERSION=""
    DSH_URL=""
    PLUGINS=""

    local section=""                                  # 当前顶层段：dsh / plugins / 其他
    local cur_name="" cur_version="" cur_url="" cur_profile="" cur_enabled=""

    flush_plugin() {
        if [ -n "$cur_name" ]; then
            PLUGINS="${PLUGINS}${cur_name}|${cur_version}|${cur_url}|${cur_profile}|${cur_enabled}"$'\n'
        fi
    }

    # `read ... || [ -n "$line" ]`：最后一行无换行符时也能处理，
    # 同时避免 set -e 在读到 EOF 时终止脚本
    while IFS= read -r line || [ -n "$line" ]; do
        # 整行注释 / 空行跳过
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue

        # ---- 顶层段切换（行首无缩进且以 xxx: 结尾）----
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*$ ]]; then
            if [ "$section" = "plugins" ]; then
                flush_plugin
                cur_name=""; cur_version=""; cur_url=""; cur_profile=""; cur_enabled=""
            fi
            section="${BASH_REMATCH[1]}"
            continue
        fi

        # ---- dsh 段：只认本段内的 version / url ----
        if [ "$section" = "dsh" ]; then
            if [[ "$line" =~ ^[[:space:]]+version:[[:space:]]*(.*)$ ]]; then
                DSH_VERSION="$(extract_scalar "${BASH_REMATCH[1]}")"
            elif [[ "$line" =~ ^[[:space:]]+url:[[:space:]]*(.*)$ ]]; then
                DSH_URL="$(extract_scalar "${BASH_REMATCH[1]}")"
            fi
            continue
        fi

        # ---- plugins 段：按 "- name:" 切分新插件 ----
        if [ "$section" = "plugins" ]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*name:[[:space:]]*(.*)$ ]]; then
                flush_plugin
                cur_name="$(extract_scalar "${BASH_REMATCH[1]}")"
                cur_version=""; cur_url=""; cur_profile=""; cur_enabled=""
            elif [[ "$line" =~ ^[[:space:]]+version:[[:space:]]*(.*)$ ]]; then
                cur_version="$(extract_scalar "${BASH_REMATCH[1]}")"
            elif [[ "$line" =~ ^[[:space:]]+url:[[:space:]]*(.*)$ ]]; then
                cur_url="$(extract_scalar "${BASH_REMATCH[1]}")"
            elif [[ "$line" =~ ^[[:space:]]+profile:[[:space:]]*(.*)$ ]]; then
                cur_profile="$(extract_scalar "${BASH_REMATCH[1]}")"
            elif [[ "$line" =~ ^[[:space:]]+enabled:[[:space:]]*(.*)$ ]]; then
                cur_enabled="$(extract_scalar "${BASH_REMATCH[1]}")"
            fi
            continue
        fi
    done < "$file"

    # 文件结束时若仍在 plugins 段，保存最后一个插件
    if [ "$section" = "plugins" ]; then
        flush_plugin
    fi
}

# ------------------------------------------------------------
# 判断插件是否启用（缺省即启用）
#   ""      → 启用（老配置未写 enabled，语义保持不变）
#   true/1/yes/on  → 启用
#   其余（false/0/no/off/任意值）→ 跳过
# 大小写不敏感。注意本脚本是纯 bash 字符串比较，不经 YAML 库。
#
# 环境变量覆盖（优先级最高，便于不改 yml 就启用）：
#   DSH_ENABLE_DATA_ANALYSIS=true
#   → 强制启用 @chengxianglibra/dsh-data-analysis（与 entrypoint 侧同名同义）
# ------------------------------------------------------------
plugin_enabled() {
    local name="$1"
    local v="${2:-}"

    # 环境变量覆盖：目前仅数据分析插件有对应变量，需要时按同样模式扩展。
    case "$name" in
        "@chengxianglibra/dsh-data-analysis")
            if [ -n "${DSH_ENABLE_DATA_ANALYSIS:-}" ]; then
                v="$DSH_ENABLE_DATA_ANALYSIS"
            fi
            ;;
    esac

    v="$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')"
    case "$v" in
        ""|true|1|yes|on) return 0 ;;
        *)                return 1 ;;
    esac
}

# ------------------------------------------------------------
# 安装 DSH 核心包
# ------------------------------------------------------------
install_dsh() {
    echo "============================================================"
    echo "安装 DSH 核心包"
    echo "============================================================"

    local version="$DSH_VERSION"
    local url="$DSH_URL"
    local pkg=""

    # 版本号合法性校验：解析器已剥离注释，此处再做一道防线，
    # 避免带空格/井号的脏值拼进 npm 包名导致安装静默失败
    if [[ "$version" =~ [[:space:]#] ]]; then
        echo "  错误：解析出的版本号含非法字符：[$version]"
        echo "        请检查 $VERSIONS_FILE 中 dsh.version 的写法（行尾注释无需手动删除）"
        return 1
    fi

    if [ -n "$url" ]; then
        echo "  方式：URL 安装"
        echo "  URL: $url"
        pkg="$url"
    elif [ -n "$version" ]; then
        echo "  方式：组件名 + 版本"
        echo "  版本: $version"
        if [ "$version" = "latest" ]; then
            pkg="@deepseek-ai/dsh"
        else
            pkg="@deepseek-ai/dsh@${version}"
        fi
    else
        echo "  错误：versions.yml 中未配置 DSH 版本或 URL"
        return 1
    fi

    echo "  执行: npm install -g $pkg"
    npm install -g "$pkg" 2>&1 | tee -a "$LOG_DIR/install.log"

    # 创建 dsh 软链接（npm 全局 bin 已在 PATH 中，此处兼容非交互式 shell）
    local dsh_bin="${DSH_ROOT}/app/nodejs/bin/dsh"
    if [ -x "$dsh_bin" ]; then
        ln -sf "$dsh_bin" /usr/local/bin/dsh
    else
        echo "  警告：未找到可执行文件 $dsh_bin"
    fi

    echo "  DSH 安装完成：$(dsh --version 2>&1 || echo '未知')"
}

# ------------------------------------------------------------
# 安装单个插件
# 关键：安装命令返回成功 ≠ 注册成功，必须以 plugin list 为准，
#       验证失败自动重试（网络抖动 / 注册未落盘时常见）。
# ------------------------------------------------------------
install_plugin() {
    local name="$1"
    local version="$2"
    local url="$3"
    local profile="$4"

    # 日志文件名需安全化：npm scope 包名形如 @scope/pkg，直接拼接会得到
    # `.../@scope/pkg.log`（把 scope 当子目录），而该目录不存在 ——
    # tee 写入失败在 set -o pipefail 下会让整条管道返回非零，安装被误判为失败。
    local log_name="${name//[^A-Za-z0-9._-]/__}"
    local plugin_log="${PLUGIN_LOG_DIR}/${log_name}.log"
    mkdir -p "$PLUGIN_LOG_DIR"
    echo "------------------------------------------------------------"
    echo "安装插件: $name"
    echo "  版本: ${version:-未指定}"
    echo "  URL: ${url:-未指定}"
    echo "  配置档: ${profile:-web}"
    echo "------------------------------------------------------------"

    # 确定安装包标识：url 优先，其次 name@version，最后 name（latest）
    local pkg="$name"
    if [ -n "$url" ]; then
        pkg="$url"
    elif [ -n "$version" ] && [ "$version" != "latest" ]; then
        pkg="${name}@${version}"
    fi

    local install_cmd="dsh plugin --profile ${profile:-web} add"
    local registered=""
    for attempt in 1 2 3; do
        echo "  [${name}] 安装尝试 ${attempt}/3: $pkg"
        if $install_cmd "$pkg" 2>&1 | tee -a "$plugin_log"; then
            # 校验注册结果（以 plugin list 为准，而非命令退出码）。
            # ⚠ 必须用**词边界**：写成 `grep -q "$name"` 会在 dsh-ctl-helper
            #   存在时把 dsh-ctl 误判为已注册。
            #   本表达式与 entrypoint.sh 的 plugin_registered() **必须逐字一致**
            #   （两脚本被 Docker 分别 COPY，无法互相 source），改一处要同步另一处。
            if dsh plugin --profile "${profile:-web}" list 2>/dev/null \
                | grep -qE "(^|[^A-Za-z0-9._-])${name}([^A-Za-z0-9._-]|$)"; then
                registered=1
                break
            fi
            echo "  [${name}] 命令返回成功但 plugin list 未出现，重试..."
        else
            echo "  [${name}] 安装命令失败，重试..."
        fi
        sleep 2
    done

    if [ -n "$registered" ]; then
        echo "  插件 $name 安装并注册成功"
    else
        echo "  错误：插件 $name 安装/注册失败（已重试 3 次）"
        return 1
    fi
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
main() {
    if [ ! -f "$VERSIONS_FILE" ]; then
        echo "错误：版本配置文件不存在：$VERSIONS_FILE"
        exit 1
    fi

    echo "============================================================"
    echo "DSH 安装脚本启动"
    echo "  配置文件: $VERSIONS_FILE"
    echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"

    parse_versions_file "$VERSIONS_FILE"

    echo "  DSH 版本: ${DSH_VERSION:-未指定}"
    echo "  DSH URL: ${DSH_URL:-未指定}"
    echo "  插件列表:"
    if [ -n "$PLUGINS" ]; then
        # 用 herestring 而非管道，避免 while 体在子 shell 中执行
        while IFS='|' read -r name version url profile enabled || [ -n "$name" ]; do
            [ -n "$name" ] || continue
            if plugin_enabled "$name" "$enabled"; then
                echo "    - $name (版本=${version:-latest}, 配置档=${profile:-web})"
            else
                echo "    - $name (版本=${version:-latest}, 配置档=${profile:-web}) [未启用]"
            fi
        done <<< "$PLUGINS"
    else
        echo "    (无)"
    fi
    echo ""

    install_dsh

    if [ -n "$PLUGINS" ]; then
        echo ""
        echo "============================================================"
        echo "安装插件"
        echo "============================================================"

        # herestring 循环：失败计数不会丢在子 shell 里
        local failed=0 skipped=0
        while IFS='|' read -r name version url profile enabled || [ -n "$name" ]; do
            [ -n "$name" ] || continue

            # 未启用的插件：跳过安装，配置区块仍保留在 versions.yml 中，
            # 改 enabled: true 并重启容器即可启用（重复执行是幂等的）。
            if ! plugin_enabled "$name" "$enabled"; then
                echo "------------------------------------------------------------"
                echo "跳过插件: $name"
                echo "  原因：versions.yml 中 enabled: ${enabled:-false}"
                echo "  如需启用：把该插件的 enabled 改为 true，然后重启容器。"
                echo "------------------------------------------------------------"
                skipped=$((skipped+1))
                continue
            fi

            install_plugin "$name" "$version" "$url" "$profile" || failed=$((failed+1))
        done <<< "$PLUGINS"

        if [ "$failed" -gt 0 ]; then
            echo "错误：${failed} 个插件安装/注册失败"
            exit 1
        fi
        if [ "$skipped" -gt 0 ]; then
            echo "提示：${skipped} 个插件因 enabled: false 未安装（配置已保留，可随时启用）"
        fi
    fi

    echo ""
    echo "============================================================"
    echo "所有组件安装完成"
    echo "  DSH: $(dsh --version 2>&1 || echo '未知')"
    echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
}

main "$@"
