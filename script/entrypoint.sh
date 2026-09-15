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
# Python 由构建参数 PYTHON_MODE 控制（apt 装发行版自带（默认）/ source 源码
# 编译指定版本 / none 不装，但 none 会让依赖 Python 的插件加载失败）。
# 这里做存在性判断，避免 none 模式下 PATH 里残留指向空目录的条目
# （虽不影响执行，但会让 `which python` 之类的排查产生误导）。
DSH_PATH="${DSH_ROOT}/app/nodejs/bin"
if [ -x "${DSH_ROOT}/app/python/bin/python3" ]; then
    DSH_PATH="${DSH_PATH}:${DSH_ROOT}/app/python/bin:${DSH_ROOT}/app/python/venv/bin"
fi
export PATH="${DSH_PATH}:${PATH}"

# ------------------------------------------------------------
# 显式告知插件 Python 的位置（DSH_DATA_ANALYSIS_* 系列环境变量）
#
# 背景：内置插件 @chengxianglibra/dsh-data-analysis 的 cordis.patch.yml
#   里这样声明配置：
#     pythonExecutable:          !!js process.env.DSH_DATA_ANALYSIS_PYTHON
#     bootstrapPythonExecutable: !!js process.env.DSH_DATA_ANALYSIS_BOOTSTRAP_PYTHON
#   插件加载时会执行 `<bootstrap> -m venv <runtimeRoot>/.venv` 建**它自己的**
#   托管运行时，再在其中安装 marivo/pandas，要求 Python >= 3.10 且带
#   venv/ensurepip。
#
#   它默认靠 PATH 找 `python3`。本镜像虽已把 python 路径拼进 PATH，
#   但若用户自行覆盖 PATH、或从其它 profile（如 dsh-ctl 进程外重启）
#   拉起 DSH，`python3` 就可能不在搜索路径里 —— 插件随即抛
#   "Could not validate local Python"，整棵插件树加载失败、DSH 起不来。
#   这里把解释器**绝对路径**显式写进环境变量，插件无需再猜。
#
#   ⚠ 只设置 BOOTSTRAP，**不要**设置 PYTHON（pythonExecutable）：
#     插件把 pythonExecutable 理解为「它自己托管运行时里的解释器」——
#     validatedExisting() 会拿它和 record.pythonExecutable
#     （即 <runtimeRoot>/.venv/bin/python）做严格相等比较，不一致就
#     判定运行时失效、重新安装一遍。若我们指到 /dsh/app/python/venv，
#     反而会让插件每次都重建自己的运行时。
#     正确做法：只给"引导解释器"，让插件按自身设计创建/复用自己的 venv。
# ------------------------------------------------------------
if [ -x "${DSH_ROOT}/app/python/bin/python3" ]; then
    export DSH_DATA_ANALYSIS_BOOTSTRAP_PYTHON="${DSH_DATA_ANALYSIS_BOOTSTRAP_PYTHON:-${DSH_ROOT}/app/python/bin/python3}"
    echo "  Python 引导解释器: ${DSH_DATA_ANALYSIS_BOOTSTRAP_PYTHON}"
else
    echo "  警告: 未检测到 Python，依赖 Python 的插件将无法加载"
fi

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
# 等待 DSH 进入「可用」状态 —— 以日志行 + 进程存活为双重判据
#
# 为什么不再用「curl 端口 60 秒」：
#   1) 端口通 ≠ DSH 活着。80/443 由 Nginx 监听，Nginx 一起来端口就通，
#      哪怕后端 DSH 已经崩溃退出（v0.3.5 的 Python 插件崩溃就是这样：
#      "DSH 已就绪 (等待 9s)" 紧跟着 "未检测到 token"，纯属假阳性）。
#   2) 固定秒数不靠谱：内置插件要现场建 venv、装 marivo/pandas，
#      首次启动 10~40s 都正常，等 9s 就判失败会误杀并触发无谓重启。
#
# 现在的判据（按优先级）：
#   a) 日志出现 `dsh web:` 行  → 插件树已全部加载成功，**唯一可靠的就绪信号**
#      （该行在 boot 成功后才会打印，含 token，直接可用）
#   b) DSH 进程已退出          → 立即失败，无需干等到超时（崩溃能秒级暴露）
#   c) 超过超时上限            → 仍未就绪，打印最近日志
#
# 超时上限同时给出「阶段化」进度提示，让用户知道此刻在干什么。
# ------------------------------------------------------------
wait_dsh_ready() {
    local label="${1:-DSH}"
    local waited=0
    # 上限放宽到 120s：给插件首次建 venv / 装依赖留足时间，
    # 由「进程死亡」和「日志成功行」两个信号来提前结束，而不是靠猜秒数。
    local max_wait="${DSH_READY_TIMEOUT:-120}"
    local next_hint=5
    local alive

    while [ "$waited" -lt "$max_wait" ]; do
        # (a) 成功信号：日志里出现 dsh web: 行
        if grep -qE 'dsh web: http' "$DSH_LOG" 2>/dev/null; then
            echo "  ${label} 已就绪（${waited}s，插件树加载完成）"
            return 0
        fi

        # (b) 失败信号：进程已退出，立刻失败，不必干等
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
            return 1
        fi

        # 阶段化进度：让用户知道还在等、等了多久
        if [ "$waited" -ge "$next_hint" ]; then
            echo "  ${label} 启动中... ${waited}s（插件初始化中，最长 ${max_wait}s）"
            next_hint=$((next_hint + 10))
        fi

        sleep 1
        waited=$((waited + 1))
    done

    echo "  ${label} 启动超时（${max_wait}s 内未出现就绪日志）"
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
echo "  ---- 启动步骤 ----"
echo "   [1/6] 检查/安装 DSH 及插件"
echo "   [2/6] 生成自签 SSL 证书"
echo "   [3/6] 启动 Nginx 反向代理 (80/443)"
echo "   [4/6] 启动 DSH Web UI 并获取访问 token"
echo "   [5/6] 输出访问地址"
echo "   [6/6] 进入看护模式（前台）"
echo "  提示: DSH 首次启动需初始化插件（可能 10~40s），就绪以日志出现"
echo "        'dsh web:' 行为准，届时会打印访问地址。"
echo "============================================================"

# ============================================================
# 1. 安装 DSH 及插件（如果尚未安装）
# ============================================================
if ! command -v dsh &>/dev/null; then
    echo "[1/6] DSH 尚未安装，执行安装脚本..."
    if ! bash "${DSH_ROOT}/script/install-dsh.sh"; then
        echo "============================================================"
        echo "  错误: DSH 安装脚本执行失败"
        echo "  日志: ${DSH_LOG_DIR}/install.log"
        echo "  ---- 最近 30 行 ----"
        tail -n 30 "${DSH_LOG_DIR}/install.log" 2>/dev/null || true
        echo "============================================================"
        echo "  常见原因: 容器无法访问 npm registry（网络/代理/DNS）。"
        echo "  容器将退出（exit 1）。"
        exit 1
    fi
else
    echo "[1/6] DSH 已安装: $(dsh --version 2>&1)"
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
#    nginx 默认以 daemon 模式运行：master 进程 fork 后父进程退出，
#    因此不能靠 `&` + $! 取 PID（拿到的是已退出的父进程）。
#    改为同步调用并检查退出码，PID 以 nginx 自己写入的 pid 文件为准。
# ============================================================
echo "[3/6] 启动 Nginx 反向代理 (port 80/443)..."
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
#
#    流程（单轮内完成，不再"先等端口、再另起一轮抓 token"）：
#      启动 → 等待就绪（以日志出现 `dsh web:` 行为准）→ 直接从中提取 token
#
#    为什么只重启一次真正需要的情况：
#      就绪信号本身就是「插件树全部加载成功」，一旦拿到该行，token 必然
#      已经在同一行里，不存在"就绪了却没 token"的中间态。因此：
#        - 成功 → 直接结束，绝不重启
#        - 进程崩溃 → 重试（真正值得重试的情况，最多 MAX_ROUNDS 轮）
#        - 超时但进程还活着 → 视为慢启动（插件在装依赖），只告警不重启
#
#    日志期望格式（dsh-web-app，含 LAN 插件时）：
#      dsh web: http://127.0.0.1:3080/?token=xxx (LAN: http://ip:3080/?token=xxx)
#    LAN 段是 dsh-web-lan-access 插件把 webserver 绑定改成 0.0.0.0 后才出现的；
#    不带该插件时只有前半段，此时依然算成功（不重试）。
#    --no-open 只表示"不要自动开浏览器"，不影响该行输出，故保留。
# ============================================================
echo "[4/6] 启动 DSH Web UI（首次启动需初始化插件，请耐心等待）..."
TOKEN=""
WEB_URL=""
LAN_URL=""
MAX_ROUNDS=3

for round in $(seq 1 "$MAX_ROUNDS"); do
    [ "$round" -gt 1 ] && echo "--- 第 ${round}/${MAX_ROUNDS} 轮启动 ---"
    start_dsh

    if ! wait_dsh_ready "DSH"; then
        # 就绪失败：区分「进程还活着（慢启动）」与「进程已死（真崩溃）」
        if [ -n "$DSH_PID" ] && kill -0 "$DSH_PID" 2>/dev/null; then
            # 进程还活着，只是很慢（插件首次建 venv / 装依赖）。
            # **不要 kill 重启** —— 那正是"无谓重启"的来源：
            # 把正在初始化的插件打断，下一轮从零开始，反而更慢。
            # 改为再等一个完整超时周期，给足时间。
            echo "  DSH 进程仍在运行，只是尚未就绪 —— 再等一个周期（${DSH_READY_TIMEOUT:-120}s），不重启"
            if wait_dsh_ready "DSH"; then
                : # 已就绪，落到下方解析逻辑
            else
                echo "  进程存活但两个周期内仍未就绪，最近日志："
                tail -n 20 "$DSH_LOG" 2>/dev/null || true
                echo "  已放弃等待（进程仍在后台运行，容器继续看护）"
                break
            fi
        else
            # 进程已退出：这是真崩溃，值得重启重试
            if [ "$round" -lt "$MAX_ROUNDS" ]; then
                echo "  检测到 DSH 启动失败（进程已退出），自动重启重试（第 $((round+1))/${MAX_ROUNDS} 轮）..."
                continue
            fi
            echo "  已重试 ${MAX_ROUNDS} 轮仍未成功，放弃。"
            break
        fi
    fi

    # 就绪即成功：token / URL 必然在同一行，直接解析
    # 日志行形如：
    #   dsh web: http://127.0.0.1:3080/?token=xxx (LAN: http://ip:3080/?token=xxx)
    # 下面统一以「dsh web: 」之后的内容为基准，避免把前缀带进 URL。
    DSH_LINE="$(grep -oE 'dsh web: http[^ ]*' "$DSH_LOG" 2>/dev/null | tail -1 | sed 's/^dsh web: //' || true)"
    TOKEN="$(printf '%s' "$DSH_LINE" | grep -oE 'token=[A-Za-z0-9_-]+' | head -1 | cut -d= -f2 || true)"
    WEB_URL="$(printf '%s' "$DSH_LINE" | sed -E 's/[?]token=[A-Za-z0-9_-]+//' || true)"
    # LAN 段：从整行里取 LAN: 后面的 URL，去掉其 ?token= 参数
    LAN_URL="$(grep -oE 'LAN: [^ )]+' "$DSH_LOG" 2>/dev/null | tail -1 \
        | sed -E 's/^LAN: //; s/[?]token=[A-Za-z0-9_-]+//' || true)"

    if [ -n "$TOKEN" ]; then
        if [ -n "$LAN_URL" ]; then
            echo "  LAN 插件已生效: $LAN_URL"
        fi
        break
    fi

    # 理论上不会到这里（就绪行必然含 token），保留兜底
    echo "  警告: 已出现就绪行但未能解析出 token，原始行：$DSH_LINE"
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
    echo "============================================================"
    echo "  [5/6] DSH 已就绪，请访问:"
    echo "    HTTP : http://<Your-IP>:${DSH_HTTP_PORT:-9080}/?token=${TOKEN}"
    echo "    HTTPS: https://<Your-IP>:${DSH_HTTPS_PORT:-9443}/?token=${TOKEN}"
    echo "  容器内直连: ${WEB_URL}"
    if [ -n "$LAN_URL" ]; then
        echo "  LAN 访问: $LAN_URL"
    fi
    echo "  健康检查页面: http://<Your-IP>:${DSH_HTTP_PORT:-9080}/health"
    echo "============================================================"
else
    echo "============================================================"
    echo "  错误: DSH 启动失败，未能获得访问 token"
    echo "  日志: $DSH_LOG"
    echo "  ---- 最近 40 行 ----"
    tail -n 40 "$DSH_LOG" 2>/dev/null || true
    echo "============================================================"
    echo "  容器将退出（便于编排系统/用户感知失败，而不是假装 running）。"
    exit 1
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
echo "[6/6] 开始跟踪日志 ($DSH_ROOT/log/*/*.log)..."
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
            # 区分「进程还在、只是暂时不响应」与「进程已死、正在等交接」，
            # 让观察窗口里的状态不再是一句含糊的"暂不可达"。
            if [ -n "$DSH_PID" ] && kill -0 "$DSH_PID" 2>/dev/null; then
                echo "  [watchdog] DSH 进程仍在 (PID ${DSH_PID}) 但 HTTP 无响应，观察中（最长 ${DSH_DOWN_GRACE}s）..."
            else
                echo "  [watchdog] DSH 进程已退出，检测到外部重启（dsh-ctl）或崩溃，等待服务恢复（最长 ${DSH_DOWN_GRACE}s）..."
            fi
        fi
        down_for=$(( $(date +%s) - DSH_DOWN_SINCE ))
        if [ "$down_for" -ge "$DSH_DOWN_GRACE" ]; then
            echo "  [watchdog] DSH 服务连续不可达 ${down_for}s（超过 ${DSH_DOWN_GRACE}s 宽限），判定为故障，容器即将退出"
            echo "  ---- 最近 40 行日志 ----"
            tail -n 40 "$DSH_LOG" 2>/dev/null || true
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
