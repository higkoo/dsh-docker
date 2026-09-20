#!/bin/bash
set -e

# ============================================================
# DSH Docker 容器启动脚本
#
# 七个阶段：
#   [1/7] 安装 DSH 及插件（读 versions.yml），校验插件注册
#   [2/7] 渲染 Nginx 配置（注入 trusted-host 白名单与 DSH 上游地址）
#   [3/7] 生成自签 SSL 证书
#   [4/7] 启动 Nginx 反向代理（80 / 443）
#   [5/7] 启动 DSH Web UI，等待就绪并解析访问 token
#   [6/7] 输出访问地址
#   [7/7] 前台看护（服务级健康检查，容忍 dsh-ctl 计划内重启）
#
# 任何一步不成立就立即退出，让 --restart / 编排系统感知失败。
# 就绪判据、看护策略、trusted-host 的设计原理见 docs/DESIGN.md。
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

# Nginx 配置渲染相关路径
#   NGINX_SRC_DIR  源模板目录（/dsh/config/nginx，含 __XXX__ 占位符）
#   NGINX_RUN_DIR  渲染产物目录（nginx.conf 从这里 include conf.d/*.conf）
# 「模板」与「运行时产物」分开，好处是容器重启即重新渲染，
# 用户改环境变量就能生效，不必直接编辑 /dsh/config 下的模板。
NGINX_SRC_DIR="${DSH_ROOT}/config/nginx"
NGINX_RUN_DIR="${RUN_DIR}/nginx"
NGINX_RUN_CONF="${NGINX_RUN_DIR}/nginx.conf"
NGINX_RUN_CONFD="${NGINX_RUN_DIR}/conf.d"

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

# ------------------------------------------------------------
# 查询 versions.yml 中某插件的 enabled 值
#   输出：true / false（缺省或解析不到一律 true，保持向后兼容）
#
# ⚠ 这里刻意**重新实现**了一份极简解析，而非 source install-dsh.sh：
#   install-dsh.sh 末尾无条件执行 main，source 会连带跑一遍安装。
#   与 install-dsh.sh 的 parse_versions_file 保持同样的语义：
#   只在该插件自己的缩进段内找 enabled，缺省视为启用。
# ------------------------------------------------------------
plugin_enabled_in_versions() {
    local target="$1"
    local file="${DSH_ROOT}/config/dsh/versions.yml"

    [ -f "$file" ] || { printf 'true'; return 0; }

    awk -v target="$target" '
        /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", line)
            sub(/[[:space:]]*#.*$/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            gsub(/^["\x27]|["\x27]$/, "", line)
            active = (line == target)
            next
        }
        # 遇到下一个顶层段（无缩进的 key:）即结束 plugins 段
        /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ { active = 0; next }
        active && /^[[:space:]]+enabled:[[:space:]]*/ {
            v = $0
            sub(/^[[:space:]]+enabled:[[:space:]]*/, "", v)
            sub(/[[:space:]]*#.*$/, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            gsub(/^["\x27]|["\x27]$/, "", v)
            print v
            exit
        }
    ' "$file" | head -1 | tr '[:upper:]' '[:lower:]' | {
        read -r v
        case "${v:-}" in
            ""|true|1|yes|on) printf 'true' ;;
            *)                printf 'false' ;;
        esac
    }
}

# ============================================================
# trusted-host 白名单：解析 + 生成 nginx map 条目
#
# 背景：为了让插件跳第三方认证时能正确拼出回调地址，Nginx 不再改写
# Host / Origin，改为原样透传。于是需要一份「合法来访域名」名单，
# 由 entrypoint 渲染进 nginx 的 map 里做访问闸门。
#
# 名单来源（优先级从高到低）：
#   1. 环境变量 DSH_TRUSTED_HOSTS（docker run -e 注入，便于编排）
#   2. 配置文件 config/dsh/trusted-hosts.txt（便于人工维护）
#   3. 都没有 → 空名单，**只放行回环地址**（fail-closed）
#
# 支持逗号 / 分号 / 空白混合分隔，条目可带端口。
# ============================================================

TRUSTED_HOSTS_FILE="${DSH_ROOT}/config/dsh/trusted-hosts.txt"
TRUSTED_HOSTS_LIST=""
TRUSTED_HOSTS_RAW_COUNT=0

# 规范化单个条目：去空白/引号、去协议前缀、去路径、去结尾点、转小写。
# 这样 `https://DSH.Corp.COM/path` 与 `dsh.corp.com.` 都能归一到同一形态，
# 避免「用户写的和浏览器发的对不上」而莫名 403。
normalize_trusted_host() {
    local h="$1"
    h="${h#"${h%%[![:space:]]*}"}"                     # 去前导空白
    h="${h%"${h##*[![:space:]]}"}"                     # 去尾随空白
    h="${h%\"}"; h="${h#\"}"                           # 去双引号
    h="${h%\'}"; h="${h#\'}"                           # 去单引号
    h="${h#http://}"; h="${h#https://}"                # 去协议前缀
    h="${h%%/*}"                                       # 去路径
    while [ "${h%%.}" != "$h" ]; do h="${h%.}"; done   # 去结尾的点（FQDN 写法）
    printf '%s' "$h" | tr '[:upper:]' '[:lower:]'      # 统一小写（Host 头大小写不敏感）
}

# 合法性校验：只允许域名/IP 里可能出现的字符。
# 目的是拦住明显写错的条目（含空格、中文、通配符等），
# 而不是做严格的 DNS 校验 —— 过严会把合法用例挡在外面。
is_valid_trusted_host() {
    case "$1" in
        "") return 1 ;;
        *[!A-Za-z0-9._:\[\]-]*) return 1 ;;
        *) return 0 ;;
    esac
}

# 判断条目是否显式带了端口（决定生成哪种 nginx 规则）。
# 形如：dsh.corp.com:9080 → 有端口；dsh.corp.com → 无；[::1]:80 → 有。
# 注意 `a:b:c`、`host:`（空端口）都算「没有合法端口」。
has_explicit_port() {
    local host="$1" rest port
    case "$host" in
        \[*\]*)  rest="${host#*\]}" ;;     # 带方括号的 IPv6：方括号之后才是端口部分
        *)       rest="$host" ;;
    esac
    case "$rest" in
        :*) ;;                             # 形如 `[::1]:9080`
        *:*) rest="${rest##*:}" ;;         # 形如 `dsh.corp.com:9080`，取最后一段
        *)  return 1 ;;                    # 压根没有冒号 → 无端口
    esac
    # rest 现在是「冒号之后」的那一段，必须非空且全为数字
    port="${rest#:}"
    case "$port" in
        "") return 1 ;;
        *[!0-9]*) return 1 ;;
    esac
    # 端口之前必须还有内容 —— 光杆 `:9080` 不是合法主机
    [ "$port" != "$host" ] || return 1
    return 0
}

# 输出「原始未清洗」的条目流，一行一个。
collect_trusted_host_raw() {
    if [ -n "${DSH_TRUSTED_HOSTS:-}" ]; then
        # 环境变量支持逗号 / 分号 / 空白混合分隔：
        #   先把分隔符统一成换行，再逐行清洗，避免用户纠结该用哪种。
        printf '%s' "$DSH_TRUSTED_HOSTS" | tr ',;' '\n'
        printf '\n'   # 见下方「尾随换行」说明
        return 0
    fi
    if [ -f "$TRUSTED_HOSTS_FILE" ]; then
        # 去掉行尾注释后输出（注释符 '#' 之后一律忽略）
        sed -e 's/#.*$//' "$TRUSTED_HOSTS_FILE"
        printf '\n'   # 见下方「尾随换行」说明
        return 0
    fi
    return 0
}

# ⚠ 上面两个分支末尾都必须补一个换行 —— 这是踩过的坑：
#
#   `while IFS= read -r line; do ...; done < <(producer)`
#   在 producer 输出**不以换行结尾**时，会静默丢弃最后一行。
#   （bash 的 read 在 EOF 处遇到不完整行返回非 0，循环体不执行。）
#
#   这正好击中两种最常见的用户写法：
#     - `-e DSH_TRUSTED_HOSTS="a.com,b.com"`  → tr 之后末行无换行 → b.com 被丢
#     - 白名单文件用 `printf ... > file` 写出、没有行尾换行
#   → 表现为「白名单里明明写了这个域名，却一直 403」，极难排查。
#
#   补一个空行是最稳的做法：空行在 load_trusted_hosts 里会被跳过。

# 把一行按逗号 / 分号 / 空白切成多个条目。
# ⚠ 必须显式设置 IFS：默认 IFS 含**冒号**，会把 `dsh.corp.com:9443`
#   切成 `dsh.corp.com` 与 `9443` 两段 —— 端口静默丢失，
#   还多出一个纯数字垃圾条目。
split_trusted_host_line() {
    local line="$1" host
    local IFS=$' \t,;'
    # shellcheck disable=SC2086  # 这里就是要按 IFS 分词，加引号反而失去作用
    for host in $line; do
        [ -n "$host" ] && printf '%s\n' "$host"
    done
}

# 解析白名单，结果写入全局 TRUSTED_HOSTS_LIST（每行一个）与计数。
load_trusted_hosts() {
    TRUSTED_HOSTS_LIST=""
    TRUSTED_HOSTS_RAW_COUNT=0

    # seen 以换行开头：保证第一条域名在 seen 里也带前边界，
    # 否则查重模式 $'\n'"a.com"$'\n' 匹配不上（缺前边界），
    # 导致 `a.com,A.COM,a.com` 重复生成规则。
    local line host candidate seen=$'\n'
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # 一行可能有多个条目（配置文件里一行写了多个），逐个取
        while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            host="$(normalize_trusted_host "$candidate")"
            [ -n "$host" ] || continue
            if ! is_valid_trusted_host "$host"; then
                echo "  警告：忽略非法 trusted-host 写法：[$candidate]"
                continue
            fi
            # 去重：同一个域名只生成一次规则。
            # 必须用「前后各一个换行做边界」的整体子串匹配 ——
            # 若只匹配 `${host}` + 换行，`a.com` 会误伤 `x.a.com`
            #（两者都含 "a.com\n"）。
            case "${seen}" in
                *$'\n'"${host}"$'\n'*) continue ;;
            esac
            seen="${seen}${host}"$'\n'
            TRUSTED_HOSTS_LIST="${TRUSTED_HOSTS_LIST}${host}"$'\n'
            TRUSTED_HOSTS_RAW_COUNT=$((TRUSTED_HOSTS_RAW_COUNT + 1))
        done < <(split_trusted_host_line "$line")
    done < <(collect_trusted_host_raw)
}

# 生成 nginx map 的条目文本。两种形态：
#   纯域名（dsh.corp.com）→ 精确规则 + 带端口正则，两种 Host 形态都放行
#   域名+端口（x.com:9443）→ 仅精确匹配该 Host 字面量
#
# ⚠ 带端口那条**必须用正则** `~^dsh\.corp\.com:`，不能写成 `"host:*"`：
#   nginx map 的通配只支持「前缀 *」「后缀 *」「*.中间.*」三种，
#   而 `*` 与 `:` 之间没有点分隔，`dsh.corp.com:*` 会被当成**字面量**，
#   永远匹配不上 → 所有带端口的访问（也就是绝大多数）全被判成 403。
build_trusted_host_map() {
    local host escaped
    while IFS= read -r host; do
        [ -n "$host" ] || continue
        if has_explicit_port "$host"; then
            # 用户显式写了端口：按**精确 Host 字面量**匹配，不做正则转义 ——
            # 精确规则里的 `\.` 不生效，会把反斜杠也当成 Host 的一部分。
            printf '    "%s" 0;\n' "$host"
        else
            # 只有域名：无端口（80/443）与任意端口都放行。
            # 正则中 `.` 必须转义，否则 `a.com` 会顺带匹配 `axcom`。
            escaped="$(printf '%s' "$host" | sed -e 's/\./\\./g')"
            printf '    "%s" 0;\n    "~^%s:" 0;\n' "$host" "$escaped"
        fi
    done <<< "$TRUSTED_HOSTS_LIST"
}

# 渲染 Nginx 配置：把模板里的占位符替换成实际值。
#
#   __TRUSTED_HOST_MAP__ → 白名单 map 条目
#   __DSH_WEB_HOST__     → DSH 监听地址
#   __DSH_WEB_PORT__     → DSH 监听端口
#   __DSH_DENY_LOG__     → 被拒请求是否留痕（"1" 记录 / "0" 不记）
#
# 渲染产物写到 NGINX_RUN_DIR（默认 /dsh/run/nginx），nginx.conf 从这里加载。
# 之所以不直接改 /dsh/config 下的模板，是为了让「用户可编辑的源文件」
# 与「运行时产物」分开 —— 容器重启即重新渲染，模板保持干净。
render_nginx_conf() {
    # 被拒请求的留痕开关：off（大小写不敏感）→ "0" 不记；其余 → "1" 记录。
    # ⚠ 只接受 1/0 这种「非空即真」的取值，因为 nginx 的 `access_log ... if=`
    #   仅把 `0` 与空串视为假。不要把 nginx 的日志级别名（debug/warn…）传进来，
    #   它会被当成非零值 → 恒记录，看起来像开关失效。
    local deny_log="1"
    case "$(printf '%s' "${DSH_TRUSTED_HOST_DENY_LOG:-debug}" | tr '[:upper:]' '[:lower:]')" in
        off|no|0|false) deny_log="0" ;;
    esac
    local host_map

    load_trusted_hosts
    host_map="$(build_trusted_host_map)"

    mkdir -p "$NGINX_RUN_CONFD"
    # 反向代理模板里引用 /dsh/log/nginx/denied.log —— 目录必须先存在，
    # 否则 nginx -t 就会因 open() 失败而拒绝启动（不是运行时才报错）。
    mkdir -p "$NGINX_LOG_DIR"

    # 主配置：整体原样复制（模板里没有需要替换的占位符）
    cp "${NGINX_SRC_DIR}/nginx.conf" "$NGINX_RUN_CONF"

    # 反代配置：替换上游地址、留痕开关与白名单 map。
    # 用 | 作分隔符，避免域名里的 / 冲突；$ 不是分隔符，无需转义 $http_host 之类。
    # 多行替换用 sed 的 `r` 读文件更稳（避免把整段 map 挤进替换串）：
    #   先把占位符单独替换成一个哨兵行，再用 `r` 把 map 内容读进来。
    sed -e "s|__DSH_WEB_HOST__|${DSH_WEB_HOST}|g" \
        -e "s|__DSH_WEB_PORT__|${DSH_WEB_PORT}|g" \
        -e "s|__DSH_DENY_LOG__|${deny_log}|g" \
        -e "s|^[[:space:]]*__TRUSTED_HOST_MAP__[[:space:]]*$|__TRUSTED_HOST_MAP_PLACEHOLDER__|" \
        "${NGINX_SRC_DIR}/conf.d/dsh-proxy.conf" > "${NGINX_RUN_CONFD}/dsh-proxy.conf"

    if [ -n "$host_map" ]; then
        local map_tmp="${NGINX_RUN_CONFD}/.trusted-host-map.tmp"
        printf '%s\n' "$host_map" > "$map_tmp"
        sed -i -e "/^__TRUSTED_HOST_MAP_PLACEHOLDER__$/r ${map_tmp}" \
               -e "/^__TRUSTED_HOST_MAP_PLACEHOLDER__$/d" "${NGINX_RUN_CONFD}/dsh-proxy.conf"
        rm -f "$map_tmp"
    else
        sed -i -e "/^__TRUSTED_HOST_MAP_PLACEHOLDER__$/d" "${NGINX_RUN_CONFD}/dsh-proxy.conf"
    fi

    # 渲染残留检查：任何一个 __XXX__ 没换干净都说明模板与脚本不同步，
    # 此时 nginx 会以「unknown directive」之类的方式报错，不如在这里直接失败。
    # ⚠ 必须排除注释行：模板的说明性注释里**故意**写了占位符的名字
    #   （例如「由 entrypoint.sh 注入 __TRUSTED_HOST_MAP__」），
    #   一并检查会把正常渲染判成失败。
    if grep -nE '__[A-Z_]+__' "$NGINX_RUN_CONF" "${NGINX_RUN_CONFD}/dsh-proxy.conf" \
        | grep -vE ':[[:space:]]*#'; then
        echo "  错误：Nginx 配置渲染后仍残留占位符（模板与 entrypoint.sh 不同步）" >&2
        exit 1
    fi

    # 报告渲染结果，让「为什么被拒」在启动阶段就可回答
    local n="${TRUSTED_HOSTS_RAW_COUNT}"
    if [ "$n" -eq 0 ]; then
        echo "  警告：未配置 trusted-host 白名单，当前**只允许**回环地址访问"
        echo "        配置方式：编辑 ${TRUSTED_HOSTS_FILE}，或加环境变量"
        echo "                  -e DSH_TRUSTED_HOSTS=\"你的域名或IP\""
    else
        echo "  trusted-host 白名单（${n} 条，仅这些域名可访问）："
        while IFS= read -r t; do
            [ -n "$t" ] || continue
            echo "    - ${t}"
        done <<< "$TRUSTED_HOSTS_LIST"
    fi
    echo "  被拒的访问会记入 ${NGINX_LOG_DIR}/denied.log（首列即 Host）；"
    echo "  不想留痕：-e DSH_TRUSTED_HOST_DENY_LOG=off"
}

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
    echo "[1/7] DSH 尚未安装，执行安装脚本..."
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
    echo "[1/7] DSH 已安装: $(dsh --version 2>&1)"
fi

# 安装后再确认一次，避免 install-dsh.sh 静默失败导致后面 command not found
if ! command -v dsh &>/dev/null; then
    echo "错误：dsh 命令不可用，安装未成功"
    exit 1
fi

# 校验插件已注册（profiles/web 目录存在 ≠ 注册成功）
#
# ⚠ 这里与 install-dsh.sh 的插件列表**不是同一份来源** ——
# entrypoint 只做「DSH 已装但插件缺失」的补装兜底，不跑完整安装流程。
# 但「某个插件是否启用」必须与安装侧同源，否则用户在 versions.yml 里把
# enabled 改成 true 后，首次安装装上了、重启时补装逻辑却依旧跳过它，
# 造成行为不一致。故这里直接读 versions.yml，环境变量可强制覆盖。
ensure_plugin "dsh-web-lan-access" "web" || true
ensure_plugin "dsh-ctl" "web" || true

# 数据分析插件：默认关闭（versions.yml 中 enabled: false）。
# 启用方式（二选一，优先级：环境变量 > versions.yml）：
#   1. docker run -e DSH_ENABLE_DATA_ANALYSIS=true ...（本次生效）
#   2. 把 versions.yml 里该插件的 enabled 改为 true（需重建镜像或挂载配置）
DATA_ANALYSIS_PLUGIN="@chengxianglibra/dsh-data-analysis"
if [ -n "${DSH_ENABLE_DATA_ANALYSIS:-}" ]; then
    _data_analysis_on="$DSH_ENABLE_DATA_ANALYSIS"
else
    _data_analysis_on="$(plugin_enabled_in_versions "$DATA_ANALYSIS_PLUGIN")"
fi
if [ "$_data_analysis_on" = "true" ]; then
    ensure_plugin "$DATA_ANALYSIS_PLUGIN" "web" || true
else
    echo "跳过插件 $DATA_ANALYSIS_PLUGIN（未启用；"
    echo "  启用：-e DSH_ENABLE_DATA_ANALYSIS=true 或改 versions.yml 中该插件的 enabled）"
fi

# ============================================================
# 2. 渲染 Nginx 配置（注入 trusted-host 白名单与 DSH 上游地址）
# ============================================================
#    必须在启动 Nginx **之前**做：nginx 加载的是渲染产物，
#    模板里的占位符残留会让它直接启动失败。
echo "[2/7] 渲染 Nginx 配置（trusted-host 白名单）..."
render_nginx_conf

# ============================================================
# 3. 生成自签 SSL 证书（仅在证书不存在时生成）
# ============================================================
if [ ! -f "${SSL_DIR}/dsh.crt" ]; then
    echo "[3/7] 生成自签证书..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "${SSL_DIR}/dsh.key" \
        -out "${SSL_DIR}/dsh.crt" \
        -days 3650 \
        -subj "/C=CN/ST=Shanghai/L=Shanghai/O=Marivo/OU=DevOps/CN=higkoo" \
        -addext "subjectAltName=IP:0.0.0.0,DNS:*"
    echo "      自签证书已生成: ${SSL_DIR}/"
fi

# ============================================================
# 4. 启动 Nginx 反向代理（80 / 443）
#    nginx 默认 daemon 模式：master fork 后父进程即退出，
#    故不能靠 `&` + $! 取 PID，改用 nginx 自己写的 pid 文件。
# ============================================================
echo "[4/7] 启动 Nginx 反向代理 (port 80/443)..."
cleanup_stale_pid

# nginx.conf 已被软链到 /etc/nginx/nginx.conf（见 Dockerfile），
# 但这里仍显式指定，避免软链缺失时跑偏。
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
    local tag="${1:-[6/7]}"
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
# 5. 启动 DSH 并抓取访问 token
#    就绪行本身即「插件树全部加载成功」，token 必在同一行，
#    不存在「就绪了却没 token」的中间态，故无需另起一轮抓取。
#    回到这里只有两种可能：已就绪，或进程已死（→ 重试）。
# ============================================================
echo "[5/7] 启动 DSH Web UI（首次启动需初始化插件，请耐心等待）..."
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
# 6. 输出访问地址
# ============================================================
if [ -n "$TOKEN" ]; then
    print_access_info "[6/7]"
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
# 7. 日志跟踪（后台）+ 进程看护（前台，必须是 PID 1 的主流程）
#    子 shell 里的 exit 只结束子 shell，不会让容器退出。
#    日志跟踪覆盖 /dsh/log/*/*.log 全部日志：有新日志文件出现
#    无需改脚本即可被看到。
# ============================================================
echo "[7/7] 开始跟踪日志 ($DSH_ROOT/log/*/*.log)..."
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
