#!/bin/bash
set -e

# ============================================================
# DSH Docker 容器启动脚本
#
# 六个阶段：
#   [1/6] 安装 DSH 及插件（读 versions.yml），校验插件注册
#   [2/6] 生成自签 SSL 证书
#   [3/6] 启动 Nginx 反向代理（80 / 443）
#   [4/6] 启动 DSH Web UI，等待就绪并解析访问 token
#   [5/6] 输出访问地址
#   [6/6] 前台看护（服务级健康检查，容忍 dsh-ctl 计划内重启）
#
# 任何一步不成立就立即退出，让 --restart / 编排系统感知失败。
# 就绪判据、看护策略等设计原理见 docs/DESIGN.md。
# ============================================================

# 加载用户环境变量（/dsh/profile.env，改完重启容器生效）
if [ -f /dsh/profile.env ]; then
    # shellcheck source=/dev/null
    source /dsh/profile.env
fi

export DSH_ROOT="${DSH_ROOT:-/dsh}"                # 绿色安装根目录
export DSH_HOME="${DSH_HOME:-/dsh/home}"           # DSH 数据目录
export DSH_WEB_HOST="${DSH_WEB_HOST:-127.0.0.1}"   # DSH 监听地址（Nginx 反代目标）
export DSH_WEB_PORT="${DSH_WEB_PORT:-3080}"

# 同步系统时区（镜像构建时已固化，这里处理运行时变更）
export TZ="${TZ:-Asia/Shanghai}"
if [ "$(readlink -f /etc/localtime 2>/dev/null)" != "/usr/share/zoneinfo/${TZ}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
    echo "  时区已切换为 ${TZ}"
fi

# PATH：nodejs 恒存在；python 路径仅在实际装了 Python 时加入，
# 避免 none 模式下残留指向空目录的条目。
DSH_PATH="${DSH_ROOT}/app/nodejs/bin"
if [ -x "${DSH_ROOT}/app/python/bin/python3" ]; then
    DSH_PATH="${DSH_PATH}:${DSH_ROOT}/app/python/bin:${DSH_ROOT}/app/python/venv/bin"
fi
export PATH="${DSH_PATH}:${PATH}"

# 告知插件 Python 的位置。只设 BOOTSTRAP（引导解释器），
# **不要**设 DSH_DATA_ANALYSIS_PYTHON —— 原因见 docs/DESIGN.md「6. Python 与内置插件的依赖关系」。
if [ -x "${DSH_ROOT}/app/python/bin/python3" ]; then
    export DSH_DATA_ANALYSIS_BOOTSTRAP_PYTHON="${DSH_DATA_ANALYSIS_BOOTSTRAP_PYTHON:-${DSH_ROOT}/app/python/bin/python3}"
    echo "  Python 引导解释器: ${DSH_DATA_ANALYSIS_BOOTSTRAP_PYTHON}"
else
    echo "  警告：未检测到 Python，依赖 Python 的插件将无法加载"
fi

DSH_LOG_DIR="${DSH_ROOT}/log/dsh"
NGINX_LOG_DIR="${DSH_ROOT}/log/nginx"
RUN_DIR="${DSH_ROOT}/run"
SSL_DIR="${DSH_ROOT}/config/nginx/ssl"
DSH_LOG="${DSH_LOG_DIR}/dsh-web.log"
NGINX_PID_FILE="${RUN_DIR}/nginx.pid"
DSH_HEALTH_URL="http://${DSH_WEB_HOST}:${DSH_WEB_PORT}"

mkdir -p "$DSH_LOG_DIR" "$NGINX_LOG_DIR" "$RUN_DIR" "$SSL_DIR" "$DSH_HOME"

# ------------------------------------------------------------
# 把 dsh-ctl 的重启日志归位到 /dsh/log/plugins/ 下
#
# dsh-ctl 从进程外拉起新 DSH 时，会把输出写到 $DSH_HOME/dsh-ctl-relaunch.log
# —— 藏在数据目录里，用户按惯例去 /dsh/log/ 找不到，会以为「重启后没 token」。
# 做法：该路径改成指向统一日志目录的软链，插件行为零改动，旧路径也依然可读。
# ------------------------------------------------------------
DSH_CTL_LOG_DIR="${DSH_ROOT}/log/plugins"
DSH_CTL_RELAUNCH_LOG="${DSH_CTL_LOG_DIR}/dsh-ctl-relaunch.log"

sync_dsh_log_alias() {
    local legacy_log="${DSH_HOME}/dsh-ctl-relaunch.log"
    mkdir -p "$DSH_CTL_LOG_DIR"

    # 旧路径若残留普通文件（历史日志），内容并入新位置后清掉
    if [ -f "$legacy_log" ] && [ ! -L "$legacy_log" ]; then
        cat "$legacy_log" >> "$DSH_CTL_RELAUNCH_LOG" 2>/dev/null || true
        rm -f "$legacy_log"
    fi

    # 预先建好目标文件：既是软链落点，也保证它出现在
    # `tail -F /dsh/log/*/*.log` 的通配展开结果里（首次重启前也能被跟踪）
    : >> "$DSH_CTL_RELAUNCH_LOG"

    ln -snf "$DSH_CTL_RELAUNCH_LOG" "$legacy_log" 2>/dev/null || true
}

# DSH 启动次数计数器，仅用于日志分隔标记
DSH_START_COUNT=0
DSH_PID=""

# 启动前自检：日志文件不可写就直接报错，避免「默默写不进去、事后才发现」
prepare_log_file() {
    local dir
    dir="$(dirname "$DSH_LOG")"
    mkdir -p "$dir" 2>/dev/null || true
    if ! ( : >> "$DSH_LOG" ) 2>/dev/null; then
        echo "错误：日志文件不可写：$DSH_LOG" >&2
        exit 1
    fi
}

prepare_log_file
sync_dsh_log_alias

# 清理上一轮残留的 PID 文件，避免 nginx 因 pid 冲突拒绝启动
cleanup_stale_pid() {
    if [ -f "$NGINX_PID_FILE" ]; then
        local old_pid
        old_pid="$(cat "$NGINX_PID_FILE" 2>/dev/null || echo '')"
        if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
            rm -f "$NGINX_PID_FILE"
        fi
    fi
}

# ------------------------------------------------------------
# 启动 DSH：kill 旧进程后重拉，输出直接追加到 $DSH_LOG
# ------------------------------------------------------------
start_dsh() {
    if [ -n "$DSH_PID" ] && kill -0 "$DSH_PID" 2>/dev/null; then
        kill "$DSH_PID" 2>/dev/null || true
        # ⚠ 不用 `wait "$DSH_PID"`：dsh 是 pnpm 包装壳，kill 掉壳后子进程可能
        #   仍存活，wait 会一直等下去（同 stop_dsh_log_follow 的坑）。
        #   改为限时轮询，最多等 5s；超时就放过，交给后续逻辑处理。
        local i=0
        while [ "$i" -lt 50 ] && kill -0 "$DSH_PID" 2>/dev/null; do
            sleep 0.1
            i=$((i + 1))
        done
    fi

    # 不清空 $DSH_LOG：token 解析靠「取日志最后一条」，截断会抹掉历史记录。
    sync_dsh_log_alias

    # 分隔标记只写文件、不 echo —— 否则会与 tail 转发的那一行重复输出。
    if [ -w "$DSH_LOG" ]; then
        DSH_START_COUNT=$((DSH_START_COUNT + 1))
        echo "----- dsh web 启动 #${DSH_START_COUNT} @ $(date '+%Y-%m-%d %H:%M:%S') -----" >> "$DSH_LOG"
    fi

    # --no-open：容器内无浏览器，不传只会多打一行 "opening the default browser"。
    # 不传 --host/--port：绑定由 dsh-web-lan-access 插件覆写为 0.0.0.0（LAN 段的前提）。
    touch "$DSH_LOG" 2>/dev/null || true
    dsh web --no-open >> "$DSH_LOG" 2>&1 &
    # ⚠ 必须紧跟其后取 $!：下面还要起一条 `tail | sed | grep` 管道后台作业，
    #   而管道作业的 $! 是**管道最后一段（grep）的 PID**，会把这里覆盖掉。
    #   一旦记错，kill -0 "$DSH_PID" 永远成功 → DSH 真崩溃也判不出来，
    #   容器会一直打「启动中」心跳、永卡启动态。详见 docs/DESIGN.md。
    DSH_PID=$!
    echo "$DSH_PID" > "${RUN_DIR}/dsh.pid"

    # 启动期实时转发日志到终端，让插件加载进度可见。
    # 覆盖 /dsh/log/*/*.log 全部文件 —— 启动阶段 nginx / 插件日志同样值得看，
    # 早先只跟 $DSH_LOG 一个文件时，用户会以为「日志没刷新」。详见 docs/DESIGN.md。
    start_log_follow
}

# ============================================================
# 日志转发到终端（docker logs）
#
# 设计要点（每一条都是踩过的坑）：
#   1. 覆盖 /dsh/log/*/*.log **全部**文件，而不是只跟 dsh-web.log；
#   2. 每行加 [HH:MM:SS] 时间戳，多文件混排时能看出「什么时候发生的」；
#      —— 用 bash 内建 printf '%()T'，零 fork；awk 的 strftime 在 slim 镜像里
#         不一定可用，实测 mawk 上静默不输出，故不用；
#   3. 周期性重扫 glob：运行中**新建**的日志文件（新装插件）也能自动被纳入。
#      tail 只认启动时给的参数，光靠 -F 是补不上新文件的；
#   4. 全程不用 wait（见 stop_dsh_log_follow 的注释）。
#
# 进程结构：
#   _log_tail_supervisor（后台，持有 tail） ── tail -F <文件...>
#                                          └─ while read 加时间戳 → 终端
#   LOG_TAIL_PID 记 supervisor，LOG_FILES_BAK 记本轮跟踪的文件快照
# ============================================================
LOG_TAIL_PID=""
LOG_FILES_SNAPSHOT=""

# 收集当前所有日志文件（按路径排序，保证不同轮次可比）
collect_log_files() {
    local -a found=()
    shopt -s nullglob
    found=("${DSH_ROOT}"/log/*/*.log)
    shopt -u nullglob
    if [ "${#found[@]}" -eq 0 ]; then
        found=("${NGINX_LOG_DIR}/access.log" "${NGINX_LOG_DIR}/error.log" "$DSH_LOG")
    fi
    printf '%s\n' "${found[@]}"
}

# 启动（或重启）日志转发。重复调用会先停掉旧的，避免出两份。
start_log_follow() {
    stop_log_follow
    # 把「监视文件集合 + tail + 时间戳」整体放进一个 supervisor 子 shell，
    # 这样重扫发现新文件时，内部重启 tail 不会影响主脚本。
    (
        local -a files=()
        mapfile -t files < <(collect_log_files)
        tail -F "${files[@]}" 2>/dev/null | while IFS= read -r line; do
            [ -z "$line" ] && continue                       # 丢掉空行/分隔头空行
            printf '[%(%H:%M:%S)T] %s\n' -1 "$line"          # 内建格式化，零 fork
        done
    ) &
    LOG_TAIL_PID=$!
    LOG_FILES_SNAPSHOT="$(collect_log_files | tr '\n' ' ')"
}

# 日志文件集合是否变化（有新建/删除）
log_files_changed() {
    local now
    now="$(collect_log_files | tr '\n' ' ')"
    [ "$now" != "$LOG_FILES_SNAPSHOT" ]
}

stop_log_follow() {
    [ -n "$LOG_TAIL_PID" ] || return 0
    # ⚠ 顺序很关键：**先**把子孙全列出来，**再** kill。
    #   supervisor 是子 shell，tail / while 都是它的子孙；一旦先 kill 掉它，
    #   子孙会被 reparent 到 PID 1，PPID 链就断了，再也找不到它们 → 孤儿堆积。
    local -a victims=("$LOG_TAIL_PID")
    local pid
    while IFS= read -r pid; do
        [ -n "$pid" ] && victims+=("$pid")
    done < <(collect_tail_children "$LOG_TAIL_PID")
    for pid in "${victims[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    LOG_TAIL_PID=""
    LOG_FILES_SNAPSHOT=""
}

# 列出以 $1 为祖先的所有进程 PID（含 tail / 子 shell），用于精确清理。
# 容器内无 pkill / ps，只能靠 /proc 的 PPid 关系逐层找。
collect_tail_children() {
    local root="$1" p pid ppid depth
    [ -z "$root" ] && return 0
    local -a frontier=("$root")
    while [ "${#frontier[@]}" -gt 0 ]; do
        local -a next=()
        for p in "${frontier[@]}"; do
            for pid in $(collect_pids_by_ppid "$p"); do
                echo "$pid"
                next+=("$pid")
            done
        done
        frontier=("${next[@]}")
        depth=$((depth + 1))
        [ "$depth" -gt 10 ] && break   # 防意外死循环
    done
}

# 列出所有「父进程 == $1」的 PID
collect_pids_by_ppid() {
    local want="$1" p pid ppid
    for p in /proc/[0-9]*; do
        pid="${p#/proc/}"
        [ "$pid" = "$$" ] && continue
        ppid="$(awk '/^PPid:/{print $2}' "$p/status" 2>/dev/null)" || continue
        [ "$ppid" = "$want" ] && echo "$pid"
    done
}

# ------------------------------------------------------------
# 等待 DSH 可用 —— 以「事件」而非「时长」为判据
#
#   日志出现 `dsh web:` 行 → 成功（插件树全加载完，token 就在该行）
#   DSH 进程已退出         → 失败（真崩溃，无需干等到超时）
#   进程存活但慢           → 继续等，只打进度（**不判失败**）
#
# 原则：慢 ≠ 坏。插件首次建 venv、装依赖可能要 1~3 分钟，
# 判死或 kill 重启才是真问题（会作废已下载的依赖）。详见 docs/DESIGN.md。
# ------------------------------------------------------------
wait_dsh_ready() {
    local label="${1:-DSH}"
    local waited=0
    local soft_limit="${DSH_READY_TIMEOUT:-120}"     # 软上限：之后转为低频提示
    local hard_limit="${DSH_READY_HARD_TIMEOUT:-0}"  # 硬上限：0 = 不限（推荐）
    local next_hint=5
    local alive

    while true; do
        # (a) 成功信号
        if grep -qE 'dsh web: http' "$DSH_LOG" 2>/dev/null; then
            echo "  ${label} 已就绪（${waited}s，插件树加载完成）"
            return 0
        fi

        # (b) 失败信号：进程已退出
        alive=0
        if [ -n "$DSH_PID" ] && kill -0 "$DSH_PID" 2>/dev/null; then
            alive=1
        fi
        if [ "$alive" -eq 0 ]; then
            # 进程刚退出时日志可能还在刷，给它 1s 落盘再判定
            sleep 1
            if grep -qE 'dsh web: http' "$DSH_LOG" 2>/dev/null; then
                echo "  ${label} 已就绪（${waited}s，插件树加载完成）"
                return 0
            fi
            echo "  ${label} 进程已退出（${waited}s）—— 启动失败，非超时"
            DSH_READY_REASON="exited"
            return 1
        fi

        # (c) 可选硬上限：默认关闭
        if [ "$hard_limit" -gt 0 ] && [ "$waited" -ge "$hard_limit" ]; then
            echo "  ${label} 达到硬上限 ${hard_limit}s 仍未就绪（进程仍在运行）"
            DSH_READY_REASON="timeout"
            return 1
        fi

        # 进度提示：软上限内每 10s 一次；超过后每 30s 一次并附日志尾部
        if [ "$waited" -lt "$soft_limit" ]; then
            if [ "$waited" -ge "$next_hint" ]; then
                echo "  ${label} 启动中... ${waited}s（插件初始化中，超过 ${soft_limit}s 后转为低频提示）"
                next_hint=$((next_hint + 10))
            fi
        else
            if [ "$waited" -ge "$next_hint" ]; then
                echo "  ${label} 仍在初始化... 已等待 ${waited}s（进程存活，继续等待；插件首次安装依赖可能较久）"
                echo "  ---- 日志尾部 ----"
                tail -n 5 "$DSH_LOG" 2>/dev/null | sed 's/^/    /' || true
                next_hint=$((next_hint + 30))
            fi
        fi

        sleep 1
        waited=$((waited + 1))
    done
}

# ------------------------------------------------------------
# 校验插件注册，未注册则补装
# （安装命令成功 ≠ 注册成功，必须以 plugin list 为准）
# ------------------------------------------------------------
plugin_registered() {
    local name="$1"
    local profile="${2:-web}"
    # 必须用词边界，否则 dsh-ctl 会被 dsh-ctl-helper 误判为已注册。
    # ⚠ 本表达式与 install-dsh.sh 的 install_plugin() **必须逐字一致**
    #   （两脚本被 Docker 分别 COPY，无法互相 source），改一处要同步另一处。
    dsh plugin --profile "$profile" list 2>/dev/null | grep -qE "(^|[^A-Za-z0-9._-])${name}([^A-Za-z0-9._-]|$)"
}

ensure_plugin() {
    local name="$1"
    local profile="${2:-web}"

    if plugin_registered "$name" "$profile"; then
        echo "插件 $name 已注册（配置档: $profile）"
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
    echo "警告：插件 $name 补装失败（不影响启动，但相关功能不可用）"
    return 1
}

# ============================================================
# 0. 启动横幅
# ============================================================
echo "============================================================"
echo "  DSH Docker 容器"
echo "  镜像版本: ${DSH_IMAGE_VERSION:-dev}"
echo "  启动时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  根目录  : ${DSH_ROOT}"
echo "  提示：DSH 首次启动需初始化插件（通常 10~40s），就绪以日志出现"
echo "        'dsh web:' 行为准，届时会打印访问地址。"
echo "============================================================"

# ============================================================
# 1. 安装 DSH 及插件（如果尚未安装）
# ============================================================
if ! command -v dsh &>/dev/null; then
    echo "[1/6] DSH 尚未安装，执行安装脚本..."
    if ! bash "${DSH_ROOT}/script/install-dsh.sh"; then
        echo "============================================================"
        echo "  错误：DSH 安装脚本执行失败"
        echo "  日志: ${DSH_LOG_DIR}/install.log"
        echo "  ---- 最近 30 行 ----"
        tail -n 30 "${DSH_LOG_DIR}/install.log" 2>/dev/null || true
        echo "============================================================"
        echo "  常见原因：容器无法访问 npm registry（网络/代理/DNS）。"
        echo "  容器将退出（exit 1）。"
        exit 1
    fi
else
    echo "[1/6] DSH 已安装: $(dsh --version 2>&1)"
fi

# 安装后再确认一次，避免 install-dsh.sh 静默失败导致后面 command not found
if ! command -v dsh &>/dev/null; then
    echo "错误：dsh 命令不可用，安装未成功"
    exit 1
fi

# 校验插件已注册（profiles/web 目录存在 ≠ 注册成功）
ensure_plugin "dsh-web-lan-access" "web" || true
ensure_plugin "dsh-ctl" "web" || true
# 数据分析插件是 npm scope 包名，必须写完整包名
ensure_plugin "@chengxianglibra/dsh-data-analysis" "web" || true

# ============================================================
# 2. 生成自签 SSL 证书（仅在证书不存在时生成）
# ============================================================
if [ ! -f "${SSL_DIR}/dsh.crt" ]; then
    echo "[2/6] 生成自签证书..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "${SSL_DIR}/dsh.key" \
        -out "${SSL_DIR}/dsh.crt" \
        -days 3650 \
        -subj "/C=CN/ST=Shanghai/L=Shanghai/O=Marivo/OU=DevOps/CN=higkoo" \
        -addext "subjectAltName=IP:0.0.0.0,DNS:*"
    echo "      自签证书已生成: ${SSL_DIR}/"
fi

# ============================================================
# 3. 启动 Nginx 反向代理（80 / 443）
#    nginx 默认 daemon 模式：master fork 后父进程即退出，
#    故不能靠 `&` + $! 取 PID，改用 nginx 自己写的 pid 文件。
# ============================================================
echo "[3/6] 启动 Nginx 反向代理 (port 80/443)..."
cleanup_stale_pid

if ! nginx -c "${DSH_ROOT}/config/nginx/nginx.conf" 2>&1; then
    echo "  错误：Nginx 启动失败，配置检查输出如下："
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
        echo "  Nginx 进程 PID: $NGINX_PID"
    else
        echo "  错误：Nginx pid 文件中的进程不存在 ($NGINX_PID)"
        exit 1
    fi
else
    echo "  错误：Nginx 未生成 pid 文件 ($NGINX_PID_FILE)"
    exit 1
fi

# 验证 Nginx 健康（重试若干次，避免刚起还没监听）
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
    echo "  错误：Nginx 健康检查未通过，请检查 ${NGINX_LOG_DIR}/error.log"
    tail -n 20 "${NGINX_LOG_DIR}/error.log" 2>/dev/null || true
    exit 1
fi

# ------------------------------------------------------------
# 从 $DSH_LOG 解析当前有效的 token 与访问地址。
# 取「最后一条」dsh web: 行 —— 日志追加不截断，最后一条即当前值。
# 副作用：设置全局 TOKEN / WEB_URL / LAN_URL。
# ------------------------------------------------------------
parse_dsh_access() {
    # 日志行形如：
    #   dsh web: http://127.0.0.1:3080/?token=xxx (LAN: http://ip:3080/?token=xxx)
    # WEB_URL / LAN_URL 都**保留** ?token= —— DSH 是 token 鉴权的，
    # 去掉后用户复制过去只会得到 401。
    local line
    line="$(grep -oE 'dsh web: http[^ ]*' "$DSH_LOG" 2>/dev/null | tail -1 | sed 's/^dsh web: //' || true)"
    TOKEN="$(printf '%s' "$line" | grep -oE 'token=[A-Za-z0-9_-]+' | head -1 | cut -d= -f2 || true)"
    WEB_URL="$(printf '%s' "$line" | grep -oE 'https?://[^ ]*' | head -1 || true)"
    LAN_URL="$(grep -oE 'LAN: [^ )]+' "$DSH_LOG" 2>/dev/null | tail -1 \
        | sed -E 's/^LAN: //' || true)"
}

# ------------------------------------------------------------
# 打印访问地址块
#   用法：print_access_info <标签> [标题]
#   $2 缺省为「DSH 已就绪，请访问」；看护期传自定义文案，
#   避免在「只是 token 变了」的场合又说一次「已就绪」。
# ------------------------------------------------------------
print_access_info() {
    local tag="${1:-[5/6]}"
    local title="${2:-DSH 已就绪，请访问}"
    echo "============================================================"
    echo "  $tag $title:"
    echo "    HTTP : http://<你的IP>:${DSH_HTTP_PORT:-9080}/?token=${TOKEN}"
    echo "    HTTPS: https://<你的IP>:${DSH_HTTPS_PORT:-9443}/?token=${TOKEN}"
    if [ -n "$WEB_URL" ]; then
        echo "  容器内直连: ${WEB_URL}"
    fi
    if [ -n "$LAN_URL" ] && [ "$LAN_URL" != "$WEB_URL" ]; then
        echo "  LAN 访问: $LAN_URL"
    fi
    echo "  健康检查页面: http://<你的IP>:${DSH_HTTP_PORT:-9080}/health"
    echo "============================================================"
}

# ============================================================
# 4. 启动 DSH 并抓取访问 token
#    就绪行本身即「插件树全部加载成功」，token 必在同一行，
#    不存在「就绪了却没 token」的中间态，故无需另起一轮抓取。
#    回到这里只有两种可能：已就绪，或进程已死（→ 重试）。
# ============================================================
echo "[4/6] 启动 DSH Web UI（首次启动需初始化插件，请耐心等待）..."
TOKEN=""
WEB_URL=""
LAN_URL=""
DSH_READY_REASON=""
MAX_ROUNDS=3

for round in $(seq 1 "$MAX_ROUNDS"); do
    [ "$round" -gt 1 ] && echo "--- 第 ${round}/${MAX_ROUNDS} 轮启动 ---"
    start_dsh

    if ! wait_dsh_ready "DSH"; then
        # 失败原因二选一：exited=进程已退出（真崩溃）；timeout=命中硬上限
        if [ "$round" -lt "$MAX_ROUNDS" ]; then
            if [ "$DSH_READY_REASON" = "timeout" ]; then
                echo "  DSH 达到硬上限仍未就绪，自动重启重试（第 $((round + 1))/${MAX_ROUNDS} 轮）..."
            else
                echo "  检测到 DSH 启动失败（进程已退出），自动重启重试（第 $((round + 1))/${MAX_ROUNDS} 轮）..."
            fi
            continue
        fi
        echo "  已重试 ${MAX_ROUNDS} 轮仍未成功，放弃。"
        break
    fi

    parse_dsh_access

    if [ -n "$TOKEN" ]; then
        if [ -n "$LAN_URL" ]; then
            echo "  LAN 插件已生效: $LAN_URL"
        fi
        break
    fi

    # 兜底：理论上到不了这里（就绪行必然含 token）
    echo "  警告：已出现就绪行但未能解析出 token，请检查日志：$DSH_LOG"
    if [ "$round" -lt "$MAX_ROUNDS" ]; then
        echo "  重试中..."
        continue
    fi
    break
done

# ============================================================
# 5. 输出访问地址
# ============================================================
if [ -n "$TOKEN" ]; then
    print_access_info "[5/6]"
else
    echo "============================================================"
    echo "  错误：DSH 启动失败，未能获得访问 token"
    echo "  日志: $DSH_LOG"
    echo "  ---- 最近 40 行 ----"
    tail -n 40 "$DSH_LOG" 2>/dev/null || true
    echo "============================================================"
    echo "  容器将退出（便于编排系统/用户感知失败，而不是假装 running）。"
    exit 1
fi

# ============================================================
# 6. 日志跟踪（后台）+ 进程看护（前台，必须是 PID 1 的主流程）
#    子 shell 里的 exit 只结束子 shell，不会让容器退出。
#    日志跟踪覆盖 /dsh/log/*/*.log 全部日志：有新日志文件出现
#    无需改脚本即可被看到。
# ============================================================
echo "[6/6] 开始跟踪日志 ($DSH_ROOT/log/*/*.log)..."
# 交棒给统一的转发器：覆盖全部日志文件 + 时间戳 + 自动纳入新建文件。
start_log_follow

cleanup() {
    stop_log_follow
}
trap cleanup EXIT

# ------------------------------------------------------------
# 看护循环：以「服务可用性」为准，区分计划内重启与真崩溃
#
#   dsh-ctl 重启会让 DSH 换 PID，用 kill -0 判断会把计划内重启
#   误判为崩溃、容器随之退出。改为：
#     a) HTTP 探测有响应即视为存活
#     b) 连续不可达超过 DSH_DOWN_GRACE 才判真故障
#     c) 服务可用时从端口反查实际 PID，刷新 $DSH_PID 与 dsh.pid
#   （dsh.pid 由本脚本写入，dsh-ctl 重启后不会更新，仅用于展示）
#   Nginx 不参与重启交接，保持严格 PID 判定。详见 docs/DESIGN.md。
# ------------------------------------------------------------
DSH_DOWN_SINCE=0
# 用 :- 保留 profile.env / docker -e 传入的值，否则会无条件覆盖
DSH_DOWN_GRACE="${DSH_DOWN_GRACE:-90}"

dsh_service_alive() {
    curl -s -o /dev/null --max-time 3 "$DSH_HEALTH_URL" 2>/dev/null
}

# 从监听端口反查真正在服务的 PID（容器内无 lsof，用 /proc 扫）
resolve_dsh_pid_by_port() {
    local hexport
    hexport="$(printf '%04X' "${DSH_WEB_PORT:-3080}")"
    local p fd inode pid
    # 用 while read 逐行消费，避免 for 对 awk 输出做词分割（SC2013）
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

    # 有新日志文件出现（例如运行中装了插件）就重启转发，把新文件纳入。
    # tail 只认启动时给的参数，-F 也补不上后出现的文件，只能整体重启。
    if log_files_changed; then
        echo "  [日志] 检测到日志文件变化，重新跟踪 ($DSH_ROOT/log/*/*.log)"
        start_log_follow
    fi

    if dsh_service_alive; then
        DSH_DOWN_SINCE=0
        live_pid="$(resolve_dsh_pid_by_port 2>/dev/null || echo '')"
        if [ -n "$live_pid" ] && [ "$live_pid" != "$DSH_PID" ]; then
            echo "  [看护] DSH 已由外部重启，实际 PID: $DSH_PID -> $live_pid"
            DSH_PID="$live_pid"
            echo "$DSH_PID" > "${RUN_DIR}/dsh.pid"

            # 重启会生成新 token，不刷新的话用户手里的旧链接会静默失效。
            # 仅在 token 真的变化时打印，避免每 10s 轮询都刷一屏。
            # 注意：这是顶层 while，不能用 local（ShellCheck SC2168）。
            prev_token="$TOKEN"
            parse_dsh_access
            if [ -n "$TOKEN" ] && [ "$TOKEN" != "$prev_token" ]; then
                print_access_info "[看护]" "DSH 已重启，token 已更新，新访问地址"
            fi
        fi
    else
        if [ "$DSH_DOWN_SINCE" -eq 0 ]; then
            DSH_DOWN_SINCE=$(date +%s)
            if [ -n "$DSH_PID" ] && kill -0 "$DSH_PID" 2>/dev/null; then
                echo "  [看护] DSH 进程仍在 (PID ${DSH_PID}) 但 HTTP 无响应，观察中（最长 ${DSH_DOWN_GRACE}s）..."
            else
                echo "  [看护] DSH 进程已退出，检测到外部重启（dsh-ctl）或崩溃，等待服务恢复（最长 ${DSH_DOWN_GRACE}s）..."
            fi
        fi
        down_for=$(( $(date +%s) - DSH_DOWN_SINCE ))
        if [ "$down_for" -ge "$DSH_DOWN_GRACE" ]; then
            echo "  [看护] DSH 服务连续不可达 ${down_for}s（超过 ${DSH_DOWN_GRACE}s 宽限），判定为故障，容器即将退出"
            echo "  ---- 最近 40 行日志 ----"
            tail -n 40 "$DSH_LOG" 2>/dev/null || true
            exit 1
        fi
    fi

    # Nginx 不参与重启交接，保持严格 PID 判定
    if [ -n "$NGINX_PID" ] && ! kill -0 "$NGINX_PID" 2>/dev/null; then
        echo "  [看护] Nginx 进程 ($NGINX_PID) 已退出，容器即将退出"
        tail -n 50 "${NGINX_LOG_DIR}/error.log" 2>/dev/null || true
        exit 1
    fi
done
