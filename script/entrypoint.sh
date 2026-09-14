#!/bin/bash
set -e

# ============================================================
# DSH Docker 容器启动脚本
# 流程：
#   1. 检查/安装 DSH 及插件（读取 versions.yml）
#   2. 生成自签 SSL 证书（可选）
#   3. 启动 DSH Web UI
#   4. 等待 DSH 就绪
#   5. 启动 Nginx 反向代理（80 端口）
#   6. 触发 DSH 重启确保插件生效
#   7. 前台跟踪日志
# ============================================================

# DSH_ROOT: 绿色安装根目录（apps, config, log, script 等）
export DSH_ROOT="${DSH_ROOT:-/dsh}"
# DSH_HOME: DSH 的数据目录（profile、插件等）
export DSH_HOME="${DSH_HOME:-/dsh/home}"
export PATH="${DSH_ROOT}/apps/nodejs/bin:${DSH_ROOT}/apps/python/bin:${DSH_ROOT}/apps/python/venv/bin:${PATH}"

DSH_LOG_DIR="${DSH_ROOT}/log/dsh"
NGINX_LOG_DIR="${DSH_ROOT}/log/nginx"
RUN_DIR="${DSH_ROOT}/run"
DSH_LOG="${DSH_LOG_DIR}/dsh-web.log"

mkdir -p "$DSH_LOG_DIR" "$NGINX_LOG_DIR" "$RUN_DIR" "$DSH_HOME"

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
# 2. 启动 DSH Web UI（后台，日志重定向到文件）
# ============================================================
echo "启动 DSH Web UI..."
: > "$DSH_LOG"
dsh web --no-open > "$DSH_LOG" 2>&1 &
DSH_PID=$!
echo "$DSH_PID" > "${RUN_DIR}/dsh.pid"
echo "  DSH PID: $DSH_PID"

# ============================================================
# 3. 等待 DSH 就绪
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
# 4. 启动 Nginx 反向代理（80 端口）
# ============================================================
echo "启动 Nginx 反向代理 (port 80/8233)..."
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
# 5. 触发 DSH 重启（确保插件生效后重启一次）
# ============================================================
echo "触发 DSH 重启 (curl POST /dshctl/restart)..."
curl -s -X POST http://127.0.0.1:3080/dshctl/restart || echo "  重启请求失败，继续..."

echo "等待 DSH 重新就绪..."
: > "$DSH_LOG"
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
# 6. 提取访问 token
# ============================================================
TOKEN=""
for i in $(seq 1 15); do
    TOKEN=$(grep -oE 'token=[A-Za-z0-9_-]+' "$DSH_LOG" | head -1 | cut -d= -f2)
    [ -n "$TOKEN" ] && break
    sleep 1
done

if [ -n "$TOKEN" ]; then
    echo "============================================================"
    echo "  DSH 已启动！请访问: http://<Your-IP>:8233/?token=${TOKEN}"
    echo "  健康检查页面: http://<Your-IP>/health"
    echo "============================================================"
else
    echo "  未抓到 token，请查看日志: $DSH_LOG"
fi

# ============================================================
# 7. 前台跟踪日志（Nginx + DSH）
# ============================================================
echo "开始跟踪日志..."
tail -f \
    "${NGINX_LOG_DIR}/access.log" \
    "${NGINX_LOG_DIR}/error.log" \
    "$DSH_LOG" \
    2>/dev/null || tail -f /dev/null
