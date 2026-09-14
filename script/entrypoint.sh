#!/bin/bash
set -e

# ============================================================
# DSH Docker 容器启动脚本
# 流程：
#   1. 检查/安装 DSH 及插件（读取 versions.yml），并验证插件注册
#   2. 生成自签 SSL 证书
#   3. 启动 DSH Web UI（日志 tee 到终端 + 文件）
#   4. 启动 Nginx 反向代理（80 / 443）
#   5. 重启 DSH 确保插件生效（以 LAN: 日志行为准，最多 3 轮）
#   6. 输出访问地址
#   7. 前台跟踪日志
# ============================================================

# 加载用户环境变量（/dsh/profile.env，可手动修改后重启容器生效）
if [ -f /dsh/profile.env ]; then
    # shellcheck source=/dev/null
    source /dsh/profile.env
fi

# DSH_ROOT: 绿色安装根目录（app, config, log, script 等）
export DSH_ROOT="${DSH_ROOT:-/dsh}"
# DSH_HOME: DSH 的数据目录（profile、插件等）
export DSH_HOME="${DSH_HOME:-/dsh/home}"
export PATH="${DSH_ROOT}/app/nodejs/bin:${DSH_ROOT}/app/python/bin:${DSH_ROOT}/app/python/venv/bin:${PATH}"

DSH_LOG_DIR="${DSH_ROOT}/log/dsh"
NGINX_LOG_DIR="${DSH_ROOT}/log/nginx"
RUN_DIR="${DSH_ROOT}/run"
SSL_DIR="${DSH_ROOT}/config/nginx/ssl"
DSH_LOG="${DSH_LOG_DIR}/dsh-web.log"

mkdir -p "$DSH_LOG_DIR" "$NGINX_LOG_DIR" "$RUN_DIR" "$SSL_DIR" "$DSH_HOME"

# ------------------------------------------------------------
# 启动/重启 DSH：kill 旧进程后重拉，输出同时写日志文件并实时打到终端
# ------------------------------------------------------------
start_dsh() {
    if [ -n "$DSH_PID" ] && kill -0 "$DSH_PID" 2>/dev/null; then
        kill "$DSH_PID" 2>/dev/null || true
        wait "$DSH_PID" 2>/dev/null || true
        sleep 1
    fi
    : > "$DSH_LOG"
    dsh web --no-open > >(tee -a "$DSH_LOG") 2>&1 &
    DSH_PID=$!
    echo "$DSH_PID" > "${RUN_DIR}/dsh.pid"
}

# ------------------------------------------------------------
# 验证插件注册，未注册则补装
# （安装日志显示成功 ≠ 注册成功，必须以 plugin list 为准）
# ------------------------------------------------------------
ensure_plugin() {
    local name="$1"
    local profile="${2:-web}"

    if dsh plugin --profile "$profile" list 2>/dev/null | grep -q "$name"; then
        echo "插件 $name 已注册 (profile: $profile)"
        return 0
    fi

    echo "插件 $name 未注册，补装..."
    for attempt in 1 2 3; do
        echo "  补装 ${name}@latest (尝试 ${attempt}/3)..."
        if dsh plugin --profile "$profile" add "${name}@latest"; then
            if dsh plugin --profile "$profile" list 2>/dev/null | grep -q "$name"; then
                echo "  插件 $name 补装并注册成功"
                return 0
            fi
            echo "  命令成功但 plugin list 未出现，重试..."
        else
            echo "  补装失败，重试..."
        fi
        sleep 2
    done
    echo "警告: 插件 $name 补装失败（不影响启动，但相关功能不可用）"
    return 1
}

# ============================================================
# 1. 安装 DSH 及插件（如果尚未安装）
# ============================================================
if ! command -v dsh &>/dev/null; then
    echo "============================================================"
    echo "DSH 尚未安装，执行安装脚本..."
    echo "============================================================"
    bash "${DSH_ROOT}/script/install-dsh.sh"
else
    echo "DSH 已安装: $(dsh --version 2>&1)"
fi

# 关键：验证插件已注册（profiles/web 目录存在 ≠ 注册成功，以 plugin list 为准）
ensure_plugin "dsh-web-lan-access" "web" || true
ensure_plugin "dsh-ctl" "web" || true

# ============================================================
# 2. 生成自签 SSL 证书（仅在证书不存在时生成）
#    供 Nginx 443 HTTPS 使用
# ============================================================
if [ ! -f "${SSL_DIR}/dsh.crt" ]; then
    echo "生成自签证书..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "${SSL_DIR}/dsh.key" \
        -out "${SSL_DIR}/dsh.crt" \
        -days 3650 \
        -subj "/C=CN/ST=Shanghai/L=Shanghai/O=Marivo/OU=DevOps/CN=higkoo" \
        -addext "subjectAltName=IP:0.0.0.0,DNS:*"
    echo "自签证书已生成: ${SSL_DIR}/"
fi

# ============================================================
# 3. 启动 DSH Web UI（日志实时显示到终端 + 写入文件）
# ============================================================
echo "启动 DSH Web UI..."
start_dsh
echo "  DSH PID: $DSH_PID"

# ============================================================
# 4. 等待 DSH 就绪
# ============================================================
echo "等待 DSH 就绪..."
for i in $(seq 1 60); do
    if curl -s http://127.0.0.1:3080 >/dev/null 2>&1; then
        echo "  DSH 已就绪 (等待 ${i}s)"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "  DSH 启动超时，请检查日志: $DSH_LOG"
        cat "$DSH_LOG"
        exit 1
    fi
    sleep 1
done

# ============================================================
# 5. 启动 Nginx 反向代理（80 / 443）
# ============================================================
echo "启动 Nginx 反向代理 (port 80/443)..."
nginx -c "${DSH_ROOT}/config/nginx/nginx.conf" 2>&1 &
NGINX_PID=$!
echo "$NGINX_PID" > "${RUN_DIR}/nginx.pid"
echo "  Nginx PID: $NGINX_PID"
sleep 1

# 验证 Nginx 健康
if curl -s http://127.0.0.1/health >/dev/null 2>&1; then
    echo "  Nginx 健康检查通过"
else
    echo "  警告: Nginx 健康检查未通过"
fi

# ============================================================
# 6. 重启 DSH 确保插件生效
#    插件在 dsh 启动时加载；装完必须重启才生效。
#    以 dsh web 日志出现 "LAN:" 行为生效标志，未出现自动再重启，
#    最多 3 轮（替代手动重启，确保容器启动后 dsh-web-lan-access 生效）
# ============================================================
echo "重启 DSH 以确保插件生效..."
TOKEN=""
LAN_URL=""
for round in 1 2 3; do
    start_dsh

    echo "等待 DSH 重新就绪 (第 ${round}/3 轮)..."
    for i in $(seq 1 60); do
        if curl -s http://127.0.0.1:3080 >/dev/null 2>&1; then
            echo "  DSH 已重新就绪 (等待 ${i}s)"
            break
        fi
        if [ "$i" -eq 60 ]; then
            echo "  DSH 重新就绪超时，请检查日志: $DSH_LOG"
            cat "$DSH_LOG"
            exit 1
        fi
        sleep 1
    done

    # 轮询提取 token（等待日志落盘）
    for i in $(seq 1 30); do
        TOKEN=$(grep -oE 'token=[A-Za-z0-9_-]+' "$DSH_LOG" | head -1 | cut -d= -f2)
        if [ -n "$TOKEN" ]; then break; fi
        sleep 1
    done

    # LAN: 行是 dsh-web-lan-access 插件生效的标志
    LAN_URL=$(grep -oE 'LAN: [^ )]+' "$DSH_LOG" | head -1 | sed 's/LAN: //')

    if [ -n "$LAN_URL" ]; then
        echo "  LAN 插件已生效 (第 ${round} 轮): $LAN_URL"
        break
    fi
    echo "  第 ${round} 轮未检测到 LAN 地址，自动重启 DSH 重试..."
done

# ============================================================
# 7. 输出访问地址
# ============================================================
if [ -n "$TOKEN" ]; then
    echo "============================================================"
    echo "  DSH 已启动！请访问:"
    echo "    HTTP : http://<Your-IP>:${DSH_HTTP_PORT:-9080}/?token=${TOKEN}"
    echo "    HTTPS: https://<Your-IP>:${DSH_HTTPS_PORT:-9443}/?token=${TOKEN}"
    if [ -n "$LAN_URL" ]; then
        echo "  LAN 访问(插件已生效): $LAN_URL"
    else
        echo "  警告: 未检测到 LAN 访问地址，dsh-web-lan-access 插件未生效"
    fi
    echo "  健康检查页面: http://<Your-IP>:${DSH_HTTP_PORT:-9080}/health"
    echo "============================================================"
else
    echo "  未抓到 token，请查看日志: $DSH_LOG"
    cat "$DSH_LOG"
fi

# ============================================================
# 8. 前台跟踪日志（Nginx + DSH）
# ============================================================
echo "开始跟踪日志..."
tail -f \
    "${NGINX_LOG_DIR}/access.log" \
    "${NGINX_LOG_DIR}/error.log" \
    "$DSH_LOG" \
    2>/dev/null || tail -f /dev/null
