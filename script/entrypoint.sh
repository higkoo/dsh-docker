#!/bin/bash
set -e

# ============================================================
# DSH Docker 容器启动脚本
# 流程：
#   1. 检查/安装 DSH 及插件（读取 versions.yml）
#   2. 生成自签 SSL 证书
#   3. 启动 DSH Web UI
#   4. 等待 DSH 就绪
#   5. 启动 Nginx 反向代理（80 / 443）
#   6. 触发 DSH 重启确保插件生效
#   7. 前台跟踪日志
# ============================================================

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

# ============================================================
# 1. 安装 DSH 及插件（如果尚未安装）
# ============================================================
if ! command -v dsh &>/dev/null; then
    echo "============================================================"
    echo "DSH 尚未安装，执行安装脚本..."
    echo "============================================================"
    bash "${DSH_ROOT}/script/install-dsh.sh"
else
    # 检查插件是否就位
    if [ ! -d "${DSH_HOME}/profiles/web" ]; then
        echo "============================================================"
        echo "DSH 插件缺失，执行安装脚本..."
        echo "============================================================"
        bash "${DSH_ROOT}/script/install-dsh.sh"
    else
        echo "DSH 已安装: $(dsh --version 2>&1)"
        echo "DSH 插件已就位"
    fi
fi

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
# 3. 启动 DSH Web UI（后台，日志重定向到文件）
# ============================================================
echo "启动 DSH Web UI..."
: > "$DSH_LOG"
dsh web --no-open > "$DSH_LOG" 2>&1 &
DSH_PID=$!
echo "$DSH_PID" > "${RUN_DIR}/dsh.pid"
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
#    手动结束进程并重拉，保证新 token 写入 DSH_LOG
#    （dshctl/restart 由 dsh 内部 fork 进程，stdout 不再进入 DSH_LOG，会抓不到 token）
# ============================================================
echo "重启 DSH 以确保插件生效..."
if [ -n "$DSH_PID" ] && kill -0 "$DSH_PID" 2>/dev/null; then
    kill "$DSH_PID" 2>/dev/null || true
    wait "$DSH_PID" 2>/dev/null || true
    sleep 1
fi

: > "$DSH_LOG"
dsh web --no-open > "$DSH_LOG" 2>&1 &
DSH_PID=$!
echo "$DSH_PID" > "${RUN_DIR}/dsh.pid"

echo "等待 DSH 重新就绪..."
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

# ============================================================
# 7. 提取访问 token 及 LAN 地址（插件生效标志）
# ============================================================
TOKEN=""
for i in $(seq 1 30); do
    TOKEN=$(grep -oE 'token=[A-Za-z0-9_-]+' "$DSH_LOG" | head -1 | cut -d= -f2)
    [ -n "$TOKEN" ] && break
    sleep 1
done

if [ -n "$TOKEN" ]; then
    # 提取 dsh web 启动行（含 LAN 地址，判断 lan 插件是否加载成功）
    WEB_LINE=$(grep -E 'dsh web:' "$DSH_LOG" | tail -1)
    LAN_URL=$(echo "$WEB_LINE" | grep -oE 'LAN: [^ )]+' | sed 's/LAN: //')
    echo "============================================================"
    echo "  DSH 已启动！请访问:"
    echo "    HTTP : http://<Your-IP>:8233/?token=${TOKEN}"
    echo "    HTTPS: https://<Your-IP>:8443/?token=${TOKEN}"
    if [ -n "$LAN_URL" ]; then
        echo "  LAN 访问(插件已生效): $LAN_URL"
    else
        echo "  警告: 未检测到 LAN 访问地址，dsh-web-lan-access 插件可能未加载成功"
    fi
    echo "  健康检查页面: http://<Your-IP>:8233/health"
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
