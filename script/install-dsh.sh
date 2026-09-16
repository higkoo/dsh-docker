#!/bin/bash
set -e
# pipefail: 保证 `dsh plugin add ... | tee` 中 dsh 的真实退出码不被 tee 吞掉
set -o pipefail

# ============================================================
# DSH 及插件安装脚本
# 读取 /dsh/config/dsh/versions.yml，按配置安装 DSH 和插件
# 支持两种安装方式：
#   1. 组件名 + 版本号（npm install -g 包名@版本）
#   2. 直接指定下载 URL（npm install -g URL）
# ============================================================

DSH_ROOT="${DSH_ROOT:-/dsh}"

VERSIONS_FILE="${DSH_ROOT}/config/dsh/versions.yml"
LOG_DIR="${DSH_ROOT}/log/dsh"
PLUGIN_LOG_DIR="${DSH_ROOT}/log/plugins"

mkdir -p "$LOG_DIR" "$PLUGIN_LOG_DIR"

# ------------------------------------------------------------
# 提取标量值：剥离行内注释、引号与首尾空白
#   输入：latest        # 使用 latest 或指定版本
#   输出：latest
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

    # 先去首尾空白，再剥引号（顺序不可颠倒：'v'  + 尾部空格需先 trim）
    raw="$(echo "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    # 剥离成对引号
    raw="${raw%\"}"; raw="${raw#\"}"
    raw="${raw%\'}"; raw="${raw#\'}"

    # 剥引号后可能再次出现空白，再 trim 一次
    raw="$(echo "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    printf '%s' "$raw"
}

# ------------------------------------------------------------
# 解析版本配置文件
#   输出到全局变量：
#     DSH_VERSION / DSH_URL   —— 仅取 dsh: 段内的字段
#     PLUGINS                 —— 每行 "name|version|url|profile"
#   关键：字段解析严格限定在所属缩进段内，避免 dsh 段与
#         plugins 段的 version:/url: 互相污染。
# ------------------------------------------------------------
parse_versions_file() {
    local file="$1"

    DSH_VERSION=""
    DSH_URL=""
    PLUGINS=""

    # 当前所处的顶层段：dsh / plugins / 其他
    local section=""
    # plugins 段内当前累积的插件字段
    local cur_name="" cur_version="" cur_url="" cur_profile=""

    # 保存当前插件到 PLUGINS
    flush_plugin() {
        if [ -n "$cur_name" ]; then
            PLUGINS="${PLUGINS}${cur_name}|${cur_version}|${cur_url}|${cur_profile}"$'\n'
        fi
    }

    # `read ... || [ -n "$line" ]` 确保最后一行无换行符时也能被处理，
    # 同时避免 set -e 在读到 EOF 时终止脚本
    while IFS= read -r line || [ -n "$line" ]; do
        # 整行注释 / 空行直接跳过（避免续读时把注释当成数据）
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue

        # ---- 顶层段切换（行首无缩进且以 xxx: 结尾）----
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*$ ]]; then
            # 离开 plugins 段时保存最后一个插件
            if [ "$section" = "plugins" ]; then
                flush_plugin
                cur_name=""; cur_version=""; cur_url=""; cur_profile=""
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
                cur_version=""; cur_url=""; cur_profile=""
            elif [[ "$line" =~ ^[[:space:]]+version:[[:space:]]*(.*)$ ]]; then
                cur_version="$(extract_scalar "${BASH_REMATCH[1]}")"
            elif [[ "$line" =~ ^[[:space:]]+url:[[:space:]]*(.*)$ ]]; then
                cur_url="$(extract_scalar "${BASH_REMATCH[1]}")"
            elif [[ "$line" =~ ^[[:space:]]+profile:[[:space:]]*(.*)$ ]]; then
                cur_profile="$(extract_scalar "${BASH_REMATCH[1]}")"
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
#    关键：安装命令返回成功 ≠ 注册成功，必须以 plugin list 为准；
#    验证失败自动重试（网络抖动/注册未落盘时常见）
# ------------------------------------------------------------
install_plugin() {
    local name="$1"
    local version="$2"
    local url="$3"
    local profile="$4"

    # 日志文件名需做安全化处理：npm scope 包名形如 @scope/pkg，
    # 直接拼接会得到 `.../@scope/pkg.log`，即把 scope 当成子目录，
    # 而该目录并不存在 —— tee 写入失败在 set -o pipefail 下会让整条
    # 管道返回非零，安装被误判为失败并重试 3 次后中断构建。
    # 因此把路径分隔符等不安全字符统一替换为 `__`。
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
            # 验证注册结果（以 plugin list 为准，而非命令退出码）。
            #
            # ⚠ 此处必须用**词边界**匹配，不能写成 `grep -q "$name"`：
            #   后者会把 dsh-ctl 误判为已在 dsh-ctl-helper 存在时注册成功。
            #   本表达式与 script/entrypoint.sh 的 plugin_registered()
            #   **必须逐字一致**（两脚本被 Docker 分别 COPY，无法互相 source），
            #   修改时请同步两处。
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

    # 解析配置文件
    parse_versions_file "$VERSIONS_FILE"

    echo "  DSH 版本: ${DSH_VERSION:-未指定}"
    echo "  DSH URL: ${DSH_URL:-未指定}"
    echo "  插件列表:"
    if [ -n "$PLUGINS" ]; then
        # 注意：此处用 herestring 而非管道，避免 while 体在子 shell 中执行
        # `read ... || [ -n "$name" ]` 防止 set -e 在读到 EOF 时终止脚本
        while IFS='|' read -r name version url profile || [ -n "$name" ]; do
            [ -n "$name" ] || continue
            echo "    - $name (版本=${version:-latest}, 配置档=${profile:-web})"
        done <<< "$PLUGINS"
    else
        echo "    (无)"
    fi
    echo ""

    # 安装 DSH
    install_dsh

    # 安装插件（herestring 循环，失败计数不丢子 shell）
    if [ -n "$PLUGINS" ]; then
        echo ""
        echo "============================================================"
        echo "安装插件"
        echo "============================================================"

        local failed=0
        while IFS='|' read -r name version url profile || [ -n "$name" ]; do
            if [ -n "$name" ]; then
                install_plugin "$name" "$version" "$url" "$profile" || failed=$((failed+1))
            fi
        done <<< "$PLUGINS"

        if [ "$failed" -gt 0 ]; then
            echo "错误：${failed} 个插件安装/注册失败"
            exit 1
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
