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
# DSH_WEB_HOST / DSH_WEB_PORT: DSH Web UI 监听地址（Nginx 反代目标）
export DSH_WEB_HOST="${DSH_WEB_HOST:-127.0.0.1}"
export DSH_WEB_PORT="${DSH_WEB_PORT:-3080}"

# TZ: 容器时区（默认北京时间）
# profile.env 或 docker run -e TZ=... 均可覆盖；
# 此处同步 /etc/localtime 与 /etc/timezone，确保 date、nginx 日志等
# 系统级时间戳与 TZ 一致（镜像构建时已固化，这里兜底处理运行时变更）。
export TZ="${TZ:-Asia/Shanghai}"
if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    if [ "$(readlink -f /etc/localtime 2>/dev/null)" != "/usr/share/zoneinfo/${TZ}" ]; then
        ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
        echo "${TZ}" > /etc/timezone
        echo "  时区已切换为 ${TZ}"
    fi
else
    echo "  警告: 时区 ${TZ} 在 /usr/share/zoneinfo 中不存在，沿用镜像默认时区"
fi

export PATH="${DSH_ROOT}/app/nodejs/bin:${DSH_ROOT}/app/python/bin:${DSH_ROOT}/app/python/venv/bin:${PATH}"

DSH_LOG_DIR="${DSH_ROOT}/log/dsh"
NGINX_LOG_DIR="${DSH_ROOT}/log/nginx"
RUN_DIR="${DSH_ROOT}/run"
SSL_DIR="${DSH_ROOT}/config/nginx/ssl"
DSH_LOG="${DSH_LOG_DIR}/dsh-web.log"
NGINX_PID_FILE="${RUN_DIR}/nginx.pid"

# DSH Web UI 健康检查地址（跟随 profile.env 的配置，不再硬编码）
DSH_HEALTH_URL="http://${DSH_WEB_HOST}:${DSH_WEB_PORT}"

mkdir -p "$DSH_LOG_DIR" "$NGINX_LOG_DIR" "$RUN_DIR" "$SSL_DIR" "$DSH_HOME"

# ------------------------------------------------------------
# 清理上一轮残留的 PID 文件，避免 nginx 因 pid 冲突拒绝启动
# ------------------------------------------------------------
cleanup_stale_pid() {
    if [ -f "$NGINX_PID_FILE" ]; then
        local old_pid
        old_pid="$(cat "$NGINX_PID_FILE" 2>/dev/null || echo '')"
        # PID 文件存在但进程已不在 => 残留文件，直接删除
        if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
            rm -f "$NGINX_PID_FILE"
        fi
    fi
}

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
# 等待 DSH Web UI 就绪
#   返回 0 = 就绪，1 = 超时
# ------------------------------------------------------------
wait_dsh_ready() {
    local label="${1:-DSH}"
    local i
    for i in $(seq 1 60); do
        if curl -s "$DSH_HEALTH_URL" >/dev/null 2>&1; then
            echo "  $label 已就绪 (等待 ${i}s)"
            return 0
        fi
        sleep 1
    done
    echo "  $label 启动超时，请检查日志: $DSH_LOG"
    cat "$DSH_LOG"
    return 1
}

# ------------------------------------------------------------
# 验证插件注册，未注册则补装
# （安装日志显示成功 ≠ 注册成功，必须以 plugin list 为准）
# ------------------------------------------------------------
plugin_registered() {
    local name="$1"
    local profile="${2:-web}"
    # 按词边界匹配，避免 dsh-ctl 误匹配 dsh-ctl-helper 之类的子串
    dsh plugin --profile "$profile" list 2>/dev/null | grep -qE "(^|[^A-Za-z0-9._-])${name}([^A-Za-z0-9._-]|$)"
}

ensure_plugin() {
    local name="$1"
    local profile="${2:-web}"

    if plugin_registered "$name" "$profile"; then
        echo "插件 $name 已注册 (profile: $profile)"
        return 0
    fi

    echo "插件 $name 未注册，补装..."
    for attempt in 1 2 3; do
        echo "  补装 ${name}@latest (尝试 ${attempt}/3)..."
        if dsh plugin --profile "$profile" add "${name}@latest"; then
            if plugin_registered "$name" "$profile"; then
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
    if ! bash "${DSH_ROOT}/script/install-dsh.sh"; then
        echo "错误: DSH 安装脚本执行失败，请检查 ${DSH_LOG_DIR}/install.log"
        exit 1
    fi
else
    echo "DSH 已安装: $(dsh --version 2>&1)"
fi

# 安装后再确认一次，避免 install-dsh.sh 静默失败导致后续 start_dsh 报 command not found
if ! command -v dsh &>/dev/null; then
    echo "错误: dsh 命令不可用，安装未成功"
    exit 1
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
wait_dsh_ready "DSH" || exit 1

# ============================================================
# 5. 启动 Nginx 反向代理（80 / 443）
#    nginx 默认以 daemon 模式运行：master 进程 fork 后父进程退出，
#    因此不能靠 `&` + $! 取 PID（拿到的是已退出的父进程）。
#    改为同步调用并检查退出码，PID 以 nginx 自己写入的 pid 文件为准。
# ============================================================
echo "启动 Nginx 反向代理 (port 80/443)..."
cleanup_stale_pid

if ! nginx -c "${DSH_ROOT}/config/nginx/nginx.conf" 2>&1; then
    echo "  错误: Nginx 启动失败，配置检查输出如下："
    nginx -t -c "${DSH_ROOT}/config/nginx/nginx.conf" 2>&1 || true
    exit 1
fi

# 等 nginx 写出 pid 文件（最多 10s）
for _ in $(seq 1 10); do
    [ -s "$NGINX_PID_FILE" ] && break
    sleep 1
done

if [ -s "$NGINX_PID_FILE" ]; then
    NGINX_PID="$(cat "$NGINX_PID_FILE")"
    if kill -0 "$NGINX_PID" 2>/dev/null; then
        echo "  Nginx PID: $NGINX_PID"
    else
        echo "  错误: Nginx pid 文件中的进程不存在 ($NGINX_PID)"
        exit 1
    fi
else
    echo "  错误: Nginx 未生成 pid 文件 ($NGINX_PID_FILE)"
    exit 1
fi

# 验证 Nginx 健康（重试若干次，避免 nginx 刚起还没监听）
NGINX_OK=false
for _ in $(seq 1 10); do
    if curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/health" 2>/dev/null | grep -q '^200$'; then
        NGINX_OK=true
        break
    fi
    sleep 1
done

if [ "$NGINX_OK" = true ]; then
    echo "  Nginx 健康检查通过"
else
    echo "  错误: Nginx 健康检查未通过，请检查 ${NGINX_LOG_DIR}/error.log"
    tail -n 20 "${NGINX_LOG_DIR}/error.log" 2>/dev/null || true
    exit 1
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
    wait_dsh_ready "DSH" || exit 1

    # 轮询提取 token（等待日志落盘）
    for _ in $(seq 1 30); do
        TOKEN="$(grep -oE 'token=[A-Za-z0-9_-]+' "$DSH_LOG" 2>/dev/null | head -1 | cut -d= -f2 || true)"
        if [ -n "$TOKEN" ]; then break; fi
        sleep 1
    done

    # LAN: 行是 dsh-web-lan-access 插件生效的标志
    LAN_URL="$(grep -oE 'LAN: [^ )]+' "$DSH_LOG" 2>/dev/null | head -1 | sed 's/LAN: //' || true)"

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
# 8. 日志跟踪（后台）+ 进程看护（前台，作为 PID 1 的主流程）
#    原实现只 tail 日志，DSH/Nginx 挂掉后容器仍显示 running。
#    关键：看护逻辑必须跑在主流程（PID 1）里，子 shell 中的 exit
#    只会终止子 shell，不会让容器退出。
# ============================================================
echo "开始跟踪日志..."
tail -F \
    "${NGINX_LOG_DIR}/access.log" \
    "${NGINX_LOG_DIR}/error.log" \
    "$DSH_LOG" \
    2>/dev/null &
TAIL_PID=$!

# 确保退出时清理子进程
cleanup() {
    kill "$TAIL_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------
# 看护循环：任一核心进程退出则记录日志并以非 0 退出，让容器一并退出
# （配合 restart_policy: unless-stopped 实现自动拉起）
# ------------------------------------------------------------
while true; do
    sleep 10

    if ! kill -0 "$DSH_PID" 2>/dev/null; then
        echo "  [watchdog] DSH 进程 ($DSH_PID) 已退出，容器即将退出"
        tail -n 50 "$DSH_LOG" 2>/dev/null || true
        exit 1
    fi

    if [ -n "$NGINX_PID" ] && ! kill -0 "$NGINX_PID" 2>/dev/null; then
        echo "  [watchdog] Nginx 进程 ($NGINX_PID) 已退出，容器即将退出"
        tail -n 50 "${NGINX_LOG_DIR}/error.log" 2>/dev/null || true
        exit 1
    fi
done
