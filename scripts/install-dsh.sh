#!/bin/bash
set -e

# ============================================================
# DSH 及插件安装脚本
# 读取 /DSH/config/dsh/versions.yml，按配置安装 DSH 和插件
# 支持两种安装方式：
#   1. 组件名 + 版本号（npm install -g 包名@版本）
#   2. 直接指定下载 URL（npm install -g URL）
# ============================================================

VERSIONS_FILE="${DSH_HOME:-/DSH}/config/dsh/versions.yml"
LOG_DIR="${DSH_HOME:-/DSH}/logs/dsh"
PLUGIN_LOG_DIR="${DSH_HOME:-/DSH}/logs/plugins"

mkdir -p "$LOG_DIR" "$PLUGIN_LOG_DIR"

# ------------------------------------------------------------
# 简易 YAML 解析器（不依赖 Python/Ansible，纯 bash 实现）
# 提取 dsh.version / dsh.url 和 plugins 列表
# ------------------------------------------------------------
parse_versions_file() {
    local file="$1"
    local section=""
    local in_plugins=false
    local current_plugin=""

    # 提取 dsh 版本和 URL
    DSH_VERSION=$(grep -E '^\s*version:' "$file" | head -1 | sed 's/.*version:\s*//' | tr -d '"' | tr -d "'")
    DSH_URL=$(grep -E '^\s*url:' "$file" | head -1 | sed 's/.*url:\s*//' | tr -d '"' | tr -d "'")

    # 如果 url 行被注释或不存在，清空
    if echo "$DSH_URL" | grep -qE '^\s*#'; then
        DSH_URL=""
    fi

    # 提取插件列表（逐行解析 plugins 段）
    PLUGINS=""
    local in_plugin_section=false
    local current_name=""
    local current_version=""
    local current_url=""
    local current_profile=""

    while IFS= read -r line; do
        # 跳过注释行和空行
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$(echo "$line" | tr -d '[:space:]')" ]] && continue

        if echo "$line" | grep -qE '^plugins:'; then
            in_plugin_section=true
            continue
        fi

        if [ "$in_plugin_section" = true ]; then
            if echo "$line" | grep -qE '^\s*-\s*name:'; then
                # 保存上一个插件
                if [ -n "$current_name" ]; then
                    PLUGINS="${PLUGINS}${current_name}|${current_version}|${current_url}|${current_profile}\n"
                fi
                current_name=$(echo "$line" | sed 's/.*name:\s*//' | tr -d '"' | tr -d "'" | tr -d '[:space:]')
                current_version=""
                current_url=""
                current_profile=""
            elif echo "$line" | grep -qE '^\s*version:'; then
                current_version=$(echo "$line" | sed 's/.*version:\s*//' | tr -d '"' | tr -d "'" | tr -d '[:space:]')
            elif echo "$line" | grep -qE '^\s*url:'; then
                local url_val=$(echo "$line" | sed 's/.*url:\s*//' | tr -d '"' | tr -d "'")
                if [ -n "$url_val" ] && ! echo "$url_val" | grep -qE '^\s*#'; then
                    current_url="$url_val"
                fi
            elif echo "$line" | grep -qE '^\s*profile:'; then
                current_profile=$(echo "$line" | sed 's/.*profile:\s*//' | tr -d '"' | tr -d "'" | tr -d '[:space:]')
            fi
        fi
    done < "$file"

    # 保存最后一个插件
    if [ -n "$current_name" ]; then
        PLUGINS="${PLUGINS}${current_name}|${current_version}|${current_url}|${current_profile}"
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

    if [ -n "$url" ]; then
        echo "  方式：URL 安装"
        echo "  URL: $url"
        npm install -g "$url" 2>&1 | tee -a "$LOG_DIR/install.log"
    elif [ -n "$version" ]; then
        echo "  方式：组件名 + 版本"
        echo "  版本: $version"
        if [ "$version" = "latest" ]; then
            npm install -g @deepseek-ai/dsh 2>&1 | tee -a "$LOG_DIR/install.log"
        else
            npm install -g "@deepseek-ai/dsh@${version}" 2>&1 | tee -a "$LOG_DIR/install.log"
        fi
    else
        echo "  错误：versions.yml 中未配置 DSH 版本或 URL"
        return 1
    fi

    # 创建 dsh 软链接
    ln -sf /DSH/apps/nodejs/bin/dsh /usr/local/bin/dsh 2>/dev/null || true

    echo "  DSH 安装完成: $(dsh --version 2>&1 || echo 'unknown')"
}

# ------------------------------------------------------------
# 安装单个插件
# ------------------------------------------------------------
install_plugin() {
    local name="$1"
    local version="$2"
    local url="$3"
    local profile="$4"

    local plugin_log="${PLUGIN_LOG_DIR}/${name}.log"
    echo "------------------------------------------------------------"
    echo "安装插件: $name"
    echo "  版本: ${version:-未指定}"
    echo "  URL: ${url:-未指定}"
    echo "  Profile: ${profile:-default}"
    echo "------------------------------------------------------------"

    local install_cmd="dsh plugin --profile ${profile:-default} add"

    if [ -n "$url" ]; then
        # URL 安装方式
        $install_cmd "$url" 2>&1 | tee -a "$plugin_log"
    elif [ -n "$version" ] && [ "$version" != "latest" ]; then
        # 指定版本安装
        $install_cmd "${name}@${version}" 2>&1 | tee -a "$plugin_log"
    else
        # latest 安装
        $install_cmd "$name" 2>&1 | tee -a "$plugin_log"
    fi

    echo "  插件 $name 安装完成"
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
main() {
    if [ ! -f "$VERSIONS_FILE" ]; then
        echo "错误：版本配置文件不存在: $VERSIONS_FILE"
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
        echo -e "$PLUGINS" | while IFS='|' read -r name version url profile; do
            [ -n "$name" ] && echo "    - $name (version=${version:-latest}, profile=${profile:-default})"
        done
    else
        echo "    (无)"
    fi
    echo ""

    # 安装 DSH
    install_dsh

    # 安装插件
    if [ -n "$PLUGINS" ]; then
        echo ""
        echo "============================================================"
        echo "安装插件"
        echo "============================================================"

        echo -e "$PLUGINS" | while IFS='|' read -r name version url profile; do
            if [ -n "$name" ]; then
                install_plugin "$name" "$version" "$url" "$profile"
            fi
        done
    fi

    echo ""
    echo "============================================================"
    echo "所有组件安装完成"
    echo "  DSH: $(dsh --version 2>&1 || echo 'unknown')"
    echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================"
}

main "$@"
