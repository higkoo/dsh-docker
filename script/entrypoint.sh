#!/bin/bash
set -e

# ============================================================
# DSH Docker 容器启动脚本
# 流程：
#   1. 检查/安装 DSH 及插件（读取 versions.yml），并验证插件注册
#   2. 生成自签 SSL 证书
#   3. 启动 Nginx 反向代理（80 / 443）
#   4. 启动 DSH Web UI 并抓取访问 token（以 LAN: 日志行为准，最多 3 轮）
#   5. 输出访问地址
#   6. 前台看护（服务级健康检查，容忍 dsh-ctl 计划内重启）
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

# TZ: 容器时区（默认北京时间，profile.env 中已做合法性校验并回退）
# 此处同步 /etc/localtime 与 /etc/timezone，确保 date、nginx 日志等
# 系统级时间戳与 TZ 一致（镜像构建时已固化，这里处理运行时变更）。
export TZ="${TZ:-Asia/Shanghai}"
if [ "$(readlink -f /etc/localtime 2>/dev/null)" != "/usr/share/zoneinfo/${TZ}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
    echo "  时区已切换为 ${TZ}"
fi

# PATH 组装：nodejs 恒存在；python 路径仅在镜像确实装了 Python 时加入。
# Python 由构建参数 PYTHON_MODE 控制（apt 装发行版自带版本 / source 源码
# 编译指定版本 / none 不装），默认 apt。
# 这里做存在性判断，避免 none 模式下 PATH 里残留指向空目录的条目
# （虽不影响执行，但会让 `which python` 之类的排查产生误导）。
DSH_PATH="${DSH_ROOT}/app/nodejs/bin"
if [ -x "${DSH_ROOT}/app/python/bin/python3" ]; then
    DSH_PATH="${DSH_PATH}:${DSH_ROOT}/app/python/bin:${DSH_ROOT}/app/python/venv/bin"
fi
export PATH="${DSH_PATH}:${PATH}"

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
# 把 dsh-ctl 的重启日志归位到 /dsh/log/plugins/ 下
#
# 背景：dsh-ctl 插件重启 DSH 时，会用 `spawn(..., { detached: true })`
#   从「进程外」拉起新 DSH。relaunch.mjs 把新进程的 stdout 默认写到
#   $DSH_HOME/dsh-ctl-relaunch.log（DSH_HOME=/dsh/home，是个隐藏得很深
#   的数据目录，不属于日志目录），用户按惯例去 /dsh/log/ 找日志时找不到，
#   会误以为「重启后没有 token」。
#
# 做法：让 dsh-ctl 仍然写它约定好的那个路径，但把该路径做成
#   指向 /dsh/log/plugins/dsh-ctl-relaunch.log 的软链 ——
#   - 插件行为零改动（无需改第三方包）
#   - 日志物理落在统一的 /dsh/log/ 目录树下，`tail /dsh/log/*/*.log` 可见
#   - 旧路径依旧可读（软链），不会破坏任何既有引用
# ------------------------------------------------------------
DSH_CTL_LOG_DIR="${DSH_ROOT}/log/plugins"
DSH_CTL_RELAUNCH_LOG="${DSH_CTL_LOG_DIR}/dsh-ctl-relaunch.log"

sync_dsh_log_alias() {
    local legacy_log="${DSH_HOME}/dsh-ctl-relaunch.log"
    mkdir -p "$DSH_CTL_LOG_DIR"

    # 旧路径残留的是普通文件（历史日志）：内容并入新位置后清掉
    if [ -f "$legacy_log" ] && [ ! -L "$legacy_log" ]; then
        cat "$legacy_log" >> "$DSH_CTL_RELAUNCH_LOG" 2>/dev/null || true
        rm -f "$legacy_log"
    fi

    # 预先建好目标文件：一方面作为软链的落点，另一方面保证它出现在
    # `tail -F /dsh/log/*/*.log` 的通配展开结果里（首次重启前也能被跟踪）
    : >> "$DSH_CTL_RELAUNCH_LOG"

    # 旧路径改为指向新位置的软链，兼容 dsh-ctl 的硬编码写入
    ln -snf "$DSH_CTL_RELAUNCH_LOG" "$legacy_log" 2>/dev/null || true
}

# ------------------------------------------------------------
# 日志落盘：直接追加重定向 + 启动自检
#
# 历史实现用「命名 FIFO + 长驻 tee」把 DSH 输出转发到 $DSH_LOG，理由是
# 让日志写入方与 DSH 生命周期解耦（dsh-ctl 可能在进程外重启 DSH）。
#
# 但这个设计有一个**致命的静默失败模式**，实测复现：
#   tee 是独立后台进程，一旦它退出（容器 stdout 被关闭/写满触发 EPIPE、
#   被 OOM 杀掉、或被信号误伤），FD 3 的写入端就失了读者。
#   此后 `dsh web >&3` 的每一次写都只得到 "write error: Broken pipe"，
#   而这句报错打在**脚本自己的 stderr**上，不住 $DSH_LOG；
#   `echo`/`>` 写失败又不会触发 set -e。
#   结果：DSH 服务完全正常、日志文件却只剩脚本直接写进去的内容，
#   token 永远抓不到，且没有任何迹象说明链路已断
#   （正是「服务正常、日志为空、token 抓不到」这一现象的根因）。
#
# 改为最朴素可靠的方式：DSH 的 stdout/stderr 直接以追加重定向写入日志文件。
#   - 没有任何中间进程，不存在「转发的进程死了」这种状态；
#   - 内核保证 append 语义，与 DSH 生命周期天然解耦；
#   - 跨 dsh-ctl 外部重启也成立（每次启动都重新打开同一文件追加）。
# 牺牲的是「日志同时回显到容器终端」——改为由前台看护统一 `tail -F`
# 输出（见脚本末尾），效果等同且不会再有断链风险。
# ------------------------------------------------------------
# DSH 启动次数计数器，仅用于日志分隔标记（便于区分多轮重试）
DSH_START_COUNT=0

# 启动前自检：确认日志文件确实可写。若不可写则直接报错退出，
# 避免重演「默默写不进去、事后才发现」的排查困境。
prepare_log_file() {
    local dir
    dir="$(dirname "$DSH_LOG")"
    mkdir -p "$dir" 2>/dev/null || true
    if ! ( : >> "$DSH_LOG" ) 2>/dev/null; then
        echo "错误: 日志文件不可写: $DSH_LOG" >&2
        exit 1
    fi
}

prepare_log_file
# 让 relaunch 日志并入 $DSH_LOG，保证 dsh-ctl 外部重启时 token 不丢
sync_dsh_log_alias

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
# 启动/重启 DSH：kill 旧进程后重拉，stdout/stderr 直接追加到 $DSH_LOG
# ------------------------------------------------------------
start_dsh() {
    if [ -n "$DSH_PID" ] && kill -0 "$DSH_PID" 2>/dev/null; then
        kill "$DSH_PID" 2>/dev/null || true
        wait "$DSH_PID" 2>/dev/null || true
        sleep 1
    fi

    # 注意：这里不要清空 $DSH_LOG。
    #
    # 旧实现是 `: > "$DSH_LOG"`，每次启动都截断。而本脚本曾先后两次启动 DSH，
    # 前面的 token 记录会被后一次截断直接抹掉——这正是「服务正常启动，
    # 日志里却看不到启动记录」的原因之一。
    #
    # 启动日志体量极小（正常一行 `dsh web: ...`，异常时一段栈），
    # 保留历史反而便于对照每一次启动。
    #
    # 若确实需要每轮清空，把下面这行取消注释即可：
    #   : > "$DSH_LOG"
    sync_dsh_log_alias

    # 写入带时间戳的分隔标记：多轮重试（最多 3 轮）时能一眼区分第几次启动。
    if [ -w "$DSH_LOG" ]; then
        DSH_START_COUNT=$((DSH_START_COUNT + 1))
        {
            echo "----- dsh web 启动 #${DSH_START_COUNT} @ $(date '+%Y-%m-%d %H:%M:%S') -----"
        } >> "$DSH_LOG"
    fi

    # 保留 --no-open：它只表示「不要自动打开浏览器」，不影响启动日志里的
    # `dsh web: <url>?token=...` 那一行（实测该行照常输出）。
    # 容器内没有浏览器，即便不传也只是多打一行 "opening the default browser" 提示，
    # 传上更干净。
    #
    # 不要额外传 --host / --port：dsh-web-lan-access 插件已在 cordis.patch.yml
    # 里把 webserver 绑定覆写为 0.0.0.0（这正是 LAN 段能出现的前提），
    # 脚本不必也不应再干预监听参数。
    #
    # 日志：直接追加重定向到文件（不再走 FIFO + tee，理由见文件头部说明）。
    # 这里显式声明 2>&1，确保 stderr 也不会漏。
    dsh web --no-open >> "$DSH_LOG" 2>&1 &
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
# 0. 启动横幅：打印镜像版本与关键路径
#    版本号来自镜像构建期烧入的 DSH_IMAGE_VERSION（未注入时显示 dev）。
#    排查时第一眼就能确认「这台机器跑的是哪个版本」，避免对着旧镜像查新问题。
# ============================================================
echo "============================================================"
echo "  DSH Docker 容器"
echo "  镜像版本: ${DSH_IMAGE_VERSION:-dev}"
echo "  启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  根目录  : ${DSH_ROOT}"
echo "============================================================"

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
# 数据分析插件为 npm scope 包名（@scope/name），此处必须写完整包名；
# plugin_registered 的词边界匹配已兼容包名中的 '/'。
ensure_plugin "@chengxianglibra/dsh-data-analysis" "web" || true

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
# 3. 启动 Nginx 反向代理（80 / 443）
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
# 4. 启动 DSH 并抓取访问 token
#    插件在 dsh 启动时加载；以 dsh web 日志出现 "LAN:" 行作为
#    dsh-web-lan-access 生效标志，未出现则自动重启重试，最多 3 轮。
#
#    实测（dsh-web-app 0.1.5-rc.1）：
#      - 插件生效时日志为
#          dsh web: http://127.0.0.1:3080/?token=xxx (LAN: http://ip:3080/?token=xxx)
#      - 插件把 webserver 绑定改成 0.0.0.0，因此 LAN 段才会出现；
#        不带该插件时只有前半段，此时也不会重试（见下方判据）。
#      - --no-open 只表示“不要自动开浏览器”，不影响该行输出，故保留。
# ============================================================
echo "启动 DSH Web UI..."
TOKEN=""
WEB_URL=""
LAN_URL=""
for round in 1 2 3; do
    start_dsh

    echo "等待 DSH 就绪 (第 ${round}/3 轮)..."
    wait_dsh_ready "DSH" || exit 1

    # 轮询提取 token（等待日志落盘；Node 写管道有缓冲，需给足时间）
    for _ in $(seq 1 30); do
        TOKEN="$(grep -oE 'token=[A-Za-z0-9_-]+' "$DSH_LOG" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
        if [ -n "$TOKEN" ]; then break; fi
        sleep 1
    done

    # LAN: 行是 dsh-web-lan-access 插件生效的标志（取最新一次启动的记录）
    LAN_URL="$(grep -oE 'LAN: [^ )]+' "$DSH_LOG" 2>/dev/null | tail -1 | sed 's/LAN: //' || true)"

    if [ -n "$LAN_URL" ]; then
        echo "  LAN 插件已生效 (第 ${round} 轮): $LAN_URL"
        break
    fi

    # 已拿到 token 但没 LAN：说明插件没装/没生效，再重启也无益，
    # 直接退出循环，避免空转两轮（各 30 秒）。
    if [ -n "$TOKEN" ]; then
        echo "  已获取 token，但未检测到 LAN 地址（插件可能未生效），停止重试"
        break
    fi

    echo "  第 ${round} 轮未检测到 token，自动重启 DSH 重试..."
done

# ============================================================
# 5. 输出访问地址
# ============================================================
if [ -n "$TOKEN" ]; then
    echo "============================================================"
    echo "  DSH 已启动！请访问:"
    echo "    HTTP : http://<Your-IP>:${DSH_HTTP_PORT:-9080}/?token=${TOKEN}"
    echo "    HTTPS: https://<Your-IP>:${DSH_HTTPS_PORT:-9443}/?token=${TOKEN}"
    echo "  容器内直连: ${WEB_URL}"
    if [ -n "$LAN_URL" ]; then
        echo "  LAN 访问: $LAN_URL"
    fi
    echo "  健康检查页面: http://<Your-IP>:${DSH_HTTP_PORT:-9080}/health"
    echo "============================================================"
else
    echo "  未抓到 token，请查看日志: $DSH_LOG"
    cat "$DSH_LOG"
fi

# ============================================================
# 6. 日志跟踪（后台）+ 进程看护（前台，作为 PID 1 的主流程）
#    原实现只 tail 日志，DSH/Nginx 挂掉后容器仍显示 running。
#    关键：看护逻辑必须跑在主流程（PID 1）里，子 shell 中的 exit
#    只会终止子 shell，不会让容器退出。
#
#    日志跟踪改为「覆盖 /dsh/log/*/*.log 全部日志」：
#      凡是有新日志文件出现（含插件后续新增的），无需改脚本即可被看到。
#      通配符在 tail 启动时展开；`tail -F` 会按文件名跟踪并自动处理轮转
#      （文件被删除/重建后仍继续跟踪）。
# ============================================================
echo "开始跟踪日志 ($DSH_ROOT/log/*/*.log)..."
# nullglob：无匹配时数组为空，避免把字面量 "/dsh/log/*/*.log" 传给 tail
shopt -s nullglob
LOG_FILES=("${DSH_ROOT}"/log/*/*.log)
shopt -u nullglob
# 若通配无匹配（理论不会），退回已知的核心日志
if [ "${#LOG_FILES[@]}" -eq 0 ]; then
    LOG_FILES=(
        "${NGINX_LOG_DIR}/access.log"
        "${NGINX_LOG_DIR}/error.log"
        "$DSH_LOG"
    )
fi

tail -F "${LOG_FILES[@]}" 2>/dev/null &
TAIL_PID=$!

# 确保退出时清理子进程
cleanup() {
    kill "$TAIL_PID" 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------
# 看护循环（v0.2.3 重写）：以「服务可用性」为准，区分计划内重启与真崩溃
#
# 背景：dsh-ctl 插件执行 restart 时，行为是：
#     1. spawn(relaunch.mjs, detached) —— 独立接力进程
#     2. 当前 DSH 进程优雅退出（PID 变化）
#     3. relaunch.mjs 等端口空闲后拉起**新的** DSH
#   旧实现用 `kill -0 $DSH_PID` 判断，会把「计划内重启」误判为崩溃而
#   exit 1，容器随之退出 —— 这正是「dshctl 重启导致容器退出」的根因。
#
# 新判定策略：
#   DSH 是「允许换 PID 的有状态服务」，PID 不能作为唯一身份。改为：
#   a) 以 **服务可用性** 为准：HTTP 探测 DSH_WEB_PORT 有响应即视为存活
#   b) 服务连续不可达超过宽限窗口（90s，覆盖 relaunch 最长 45s 交接期）
#      才判定为真故障
#   c) 服务可用时从端口反查实际 PID，刷新 $DSH_PID 与 dsh.pid
#      （dsh.pid 由本脚本写入，dsh-ctl 重启后**不会**更新它，
#        因此该文件会过期，不能作为存活依据）
#   Nginx 不参与重启交接，保持严格的 PID 判定。
# ------------------------------------------------------------
DSH_DOWN_SINCE=0
DSH_DOWN_GRACE=90   # 容忍重启交接的最大秒数（relaunch.mjs 默认等待窗口 45s + 余量）

dsh_service_alive() {
    curl -s -o /dev/null --max-time 3 "$DSH_HEALTH_URL" 2>/dev/null
}

# 从监听端口反查真正在服务的 PID（容器内无 lsof，用 /proc 扫）
resolve_dsh_pid_by_port() {
    local hexport
    hexport="$(printf '%04X' "${DSH_WEB_PORT:-3080}")"
    local p fd inode pid
    # 用 while read 逐行消费，避免 for 循环对 awk 输出做词分割（SC2013）
    while IFS= read -r inode; do
        [ -z "$inode" ] && continue
        for p in /proc/[0-9]*; do
            pid="${p#/proc/}"
            for fd in "$p"/fd/*; do
                if [ "$(readlink "$fd" 2>/dev/null)" = "socket:[${inode}]" ]; then
                    echo "$pid"
                    return 0
                fi
            done
        done
    done < <(awk -v h=":$hexport" '
        $2 ~ h { n = split($10, a, ","); print a[n] }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null)
    return 1
}

while true; do
    sleep 10

    if dsh_service_alive; then
        # 服务可用 => 重置故障计时，并刷新实际 PID（便于日志展示）
        DSH_DOWN_SINCE=0
        live_pid="$(resolve_dsh_pid_by_port 2>/dev/null || echo '')"
        if [ -n "$live_pid" ] && [ "$live_pid" != "$DSH_PID" ]; then
            echo "  [watchdog] DSH 已由外部重启，实际 PID: $DSH_PID -> $live_pid"
            DSH_PID="$live_pid"
            # 同步 PID 文件，避免后续误读过期的旧值
            echo "$DSH_PID" > "${RUN_DIR}/dsh.pid"
        fi
    else
        if [ "$DSH_DOWN_SINCE" -eq 0 ]; then
            DSH_DOWN_SINCE=$(date +%s)
            echo "  [watchdog] DSH 服务暂不可达，进入观察窗口（最长 ${DSH_DOWN_GRACE}s）..."
        fi
        down_for=$(( $(date +%s) - DSH_DOWN_SINCE ))
        if [ "$down_for" -ge "$DSH_DOWN_GRACE" ]; then
            echo "  [watchdog] DSH 服务连续不可达 ${down_for}s（超过 ${DSH_DOWN_GRACE}s 宽限），判定为故障，容器即将退出"
            tail -n 50 "$DSH_LOG" 2>/dev/null || true
            exit 1
        fi
    fi

    # --- Nginx 存活判定（Nginx 不参与重启交接，保持严格判定）---
    if [ -n "$NGINX_PID" ] && ! kill -0 "$NGINX_PID" 2>/dev/null; then
        echo "  [watchdog] Nginx 进程 ($NGINX_PID) 已退出，容器即将退出"
        tail -n 50 "${NGINX_LOG_DIR}/error.log" 2>/dev/null || true
        exit 1
    fi
done
