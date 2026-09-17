# 设计说明（DESIGN）

本文记录 **DSH Docker 的实现原理与关键决策** —— 也就是「为什么这么写」。

日常使用请看 [README](../README.md)；代码里只留结论，考证与权衡都在这里。

> 读者对象：要改这个项目的人，或遇到疑难想弄清机制的人。
> 只想知道「怎么跑起来」的同学，读完 README 就够了。

---

## 目录

1. [启动流程总览](#1-启动流程总览)
2. [就绪判定：为什么用「事件」而不是「时长」](#2-就绪判定为什么用事件而不是时长)
3. [日志落盘：为什么放弃了 FIFO + tee](#3-日志落盘为什么放弃了-fifo--tee)
4. [进程看护：为什么用 HTTP 可用性而不是 PID](#4-进程看护为什么用-http-可用性而不是-pid)
   - [4.1 `$!` 的坑：别把日志管道当成 DSH 进程](#41--的坑别把日志管道当成-dsh-进程)
   - [4.2 `wait` 的坑：管道只 kill 尾端，`wait` 会等整个 job](#42-wait-的坑管道只-kill-尾端wait-会等整个-job)
   - [4.3 日志转发：为什么不是一条 `tail -F` 就完事](#43-日志转发为什么不是一条-tail--f-就完事)
5. [访问 token 的生命周期](#5-访问-token-的生命周期)
6. [Python 与内置插件的依赖关系](#6-python-与内置插件的依赖关系)
7. [apt 与 source 两种模式的目录对齐](#7-apt-与-source-两种模式的目录对齐)
8. [locale 与中文显示](#8-locale-与中文显示)
9. [Nginx 路径软链](#9-nginx-路径软链)
   - [9.1 访问日志里的真实客户端 IP](#91-访问日志里的真实客户端-ip)
10. [插件注册校验：为什么必须用词边界](#10-插件注册校验为什么必须用词边界)

---

## 1. 启动流程总览

容器入口 `script/entrypoint.sh` 以 PID 1 的身份跑六个阶段：

| 阶段 | 做什么 | 失败时 |
|------|--------|--------|
| `[1/6]` | 未安装则跑 `install-dsh.sh`；随后校验三个插件是否注册 | `exit 1` |
| `[2/6]` | 证书不存在则生成自签证书 | `exit 1` |
| `[3/6]` | 启动 Nginx，等 pid 文件与 `/health` 就绪 | `exit 1` |
| `[4/6]` | 启动 DSH，等就绪行，解析 token | 进程退出则重试（最多 3 轮） |
| `[5/6]` | 打印访问地址块 | 拿不到 token 则 `exit 1` |
| `[6/6]` | 起整合 `tail` 转发日志，主流程转入看护循环 | — |

**设计取舍**：整个脚本是「**串行 + 快速失败**」。任何一步不成立就立刻退出，
让 `--restart` 或编排系统感知并拉起 —— 而不是带着半残状态假装 running。

看护循环必须是**主流程**（PID 1），不能放子 shell：子 shell 里的 `exit`
只会结束子 shell，容器照样活着。

---

## 2. 就绪判定：为什么用「事件」而不是「时长」

早期实现是「等固定 N 秒 + 探测端口」，两头都错：

- **等太短**（旧版 9s）：插件首次要建 venv、装 `marivo`/`pandas`，实测 1~3 分钟。
  判失败会触发无谓重启，而重启会**作废已下载的依赖**，越重启越慢。
- **探测端口**：容器内 80/443 由 Nginx 监听，Nginx 一起来端口就通，
  **哪怕后端 DSH 已经崩了** —— 这是假阳性。

正确的信号有两个，都是**事件**：

| 事件 | 含义 | 处理 |
|------|------|------|
| 日志出现 `dsh web: http...` | 插件树**全部**加载成功，token 就在这一行 | 立即成功，绝不重启 |
| DSH 进程退出 | 真崩溃 | 立即失败，重试 |

**核心原则：慢 ≠ 坏。** 只要进程还活着就继续等。所以：

- `DSH_READY_TIMEOUT`（默认 120）只是**提示频率的软上限**，不触发失败；
  超过后从「每 10s 报一次进度」转为「每 30s 报一次 + 附日志尾部」。
- `DSH_READY_HARD_TIMEOUT`（默认 0 = 不限）才是真正的放弃条件，
  仅供「不允许容器长期处于启动态」的编排场景使用。

> 为什么不干脆把软上限也去掉：长时间无输出会让人怀疑卡死。
> 低频提示的作用是证明「脚本还在等，没死」。

---

## 3. 日志落盘：为什么放弃了 FIFO + tee

**旧实现**：DSH 的 stdout 写进命名 FIFO，再由一个长驻 `tee` 拆成两路（文件 + 终端）。

理论上很优雅 —— 写入方与 DSH 生命周期解耦。但它有个**致命的静默失败模式**：

1. `tee` 是独立后台进程，会因 stdout 关闭（EPIPE）、OOM、信号误伤而退出；
2. `tee` 一死，FIFO 的写端就没了读者；
3. 此后 `dsh web >&3` 每次写都只得到 `write error: Broken pipe`；
4. 这句报错打在**脚本自己的 stderr**上，**不进日志文件**；
5. 而 `echo`/`>` 写失败**不会**触发 `set -e`。

结果：DSH 服务完全正常，日志文件却只剩脚本直接写进去的内容，
**token 永远抓不到，且没有任何迹象说明链路已断**。

**现实现**：DSH 的 stdout/stderr 直接以追加重定向写入日志文件。

```bash
dsh web --no-open >> "$DSH_LOG" 2>&1 &
```

- 没有中间进程 → 不存在「转发的进程死了」这种状态；
- 内核保证 append 语义 → 与 DSH 生命周期天然解耦；
- 跨 `dsh-ctl` 外部重启也成立（每次启动重新打开同一文件追加）。

代价是日志不再自动回显终端 —— 改由 `[4/6]` 阶段的 `tail -F` 转发（带 `[dsh]` 前缀），
`[6/6]` 之后交给覆盖全量日志目录的整合 `tail` 接管。
**前缀只加在转发流上，不污染文件**，所以解析不受影响。

---

## 4. 进程看护：为什么用 HTTP 可用性而不是 PID

`dsh-ctl` 插件执行 restart 时，行为是：

1. `spawn(relaunch.mjs, { detached: true })` —— 起一个独立接力进程；
2. 当前 DSH 进程优雅退出（**PID 变了**）；
3. 接力进程等端口空闲后拉起**新的** DSH。

早期用 `kill -0 $DSH_PID` 判断存活，会把这种**计划内重启**误判为崩溃而 `exit 1`
—— 这正是「`dshctl` 重启导致容器退出」的根因。

**现策略**：DSH 是「允许换 PID 的有状态服务」，PID 不能当唯一身份。

| 判据 | 说明 |
|------|------|
| HTTP 探测 `DSH_WEB_PORT` 有响应 | 视为存活 |
| 连续不可达超过 `DSH_DOWN_GRACE`（默认 90s） | 才判真故障、容器退出 |
| 服务可用时从端口反查实际 PID | 刷新 `$DSH_PID` 与 `dsh.pid` |

> `dsh.pid` 是本脚本写的，`dsh-ctl` 重启后**不会**更新它 ——
> 所以这个文件会过期，**不能**作为存活依据，只能用于展示。

Nginx 不参与重启交接，保持严格的 PID 判定。

**反查 PID 的做法**：容器内没有 `lsof`，所以扫 `/proc/net/tcp{,6}`
拿到监听该端口的 socket inode，再遍历 `/proc/<pid>/fd/*` 找谁持有它。

### 4.1 `$!` 的坑：别把日志管道当成 DSH 进程

`start_dsh()` 里有两处后台作业，顺序**不能**随意调换：

```bash
dsh web --no-open >> "$DSH_LOG" 2>&1 &
DSH_PID=$!                    # ← 必须紧跟在 dsh 之后
tail -F ... | sed ... | grep ... &
DSH_FOLLOW_PID=$!
```

原因：**管道后台作业的 `$!` 是「管道最后一段」的 PID**，不是整条管道的 PID。
若把 `DSH_PID=$!` 写在管道之后，它拿到的就是 `grep` 的 PID：

| 写法 | `DSH_PID` 实际指向 | 后果 |
|------|------------------|------|
| `DSH_PID=$!` 紧跟 `dsh ...&` | `dsh` 进程本身 | ✅ 正确 |
| `DSH_PID=$!` 紧跟 `tail\|sed\|grep &` | `grep` 进程 | ❌ 见下 |

`grep` 跟的是日志文件，**只要文件还在它就一直活着**。于是
`kill -0 "$DSH_PID"` 永远成功 →「进程已退出」判据**永不成立**：

- 就绪阶段：DSH 崩了也判不出来，`wait_dsh_ready` 只能靠**硬上限**兜底
  （默认 `0` = 不限）→ 容器一直打「启动中」心跳、**永久卡在启动态**，
  `--restart` 也救不了；
- 看护阶段：`[看护] DSH 进程仍在` 的提示同样是假的。

顺带一提，失败文案也得跟着判据走：`wait_dsh_ready` 有两种失败原因
（`exited` 真崩溃 / `timeout` 命中硬上限），调用方不能一律打印「进程已退出」
—— 否则会出现「达到硬上限（进程仍在运行）」紧接着「检测到启动失败（进程已退出）」
这种自相矛盾的日志。

> 回归测试见 `test/test_versions_parser.sh` 用例 13：它直接从 `entrypoint.sh`
> 抽取 `start_dsh` 的**真实语句顺序**执行，断言 `DSH_PID` 指向 `dsh` 真身
> 而非管道进程 —— 手写一份"正确顺序"来测是抓不到这个 bug 的。

### 4.2 `wait` 的坑：管道只 kill 尾端，`wait` 会等整个 job

这是 v0.4.2 修的缺陷，**v0.4.0 / v0.4.1 都有**。它是「看护循环从未运行」的真凶。

`stop_dsh_log_follow()` 曾这么写：

```bash
pkill -P "$DSH_FOLLOW_PID" 2>/dev/null || true   # ① 命令根本不存在
kill "$DSH_FOLLOW_PID" 2>/dev/null || true       # ② 只杀掉尾端 grep
wait "$DSH_FOLLOW_PID" 2>/dev/null || true       # ③ 会等到整条管道结束
```

三处问题叠加成**永久阻塞**：

| # | 问题 | 说明 |
|---|------|------|
| ① | 容器内**没有 `ps` / `pkill`** | slim 镜像，`pkill` 恒返回 127（被 `\|\| true` 吞掉），`tail`/`sed` **从未被清理** |
| ② | `$!` 只是**尾端** | 与 §4.1 同源：`DSH_FOLLOW_PID` 记的是 `grep`，`tail`/`sed` 管不着 |
| ③ | `wait` 等的是 **job**，不是 PID | 管道是一个 job；kill 掉尾端 `grep` 后 `tail`/`sed` 仍存活 → job 不结束 → `wait` 返回不了 |

`set -e` 下在顶层调用，`wait` 就是**死等**，没有任何超时或信号能救它。
后果链条：

```
[6/6] → stop_dsh_log_follow → wait 永久阻塞
                              ↘ 下面的看护 while 循环 never runs
                                 ↳ 容器永久 running、DSH 崩了也不退出
```

**实测表现**：日志停在 `[6/6] 开始跟踪日志...` 之后再无输出；
`ps`-less 环境里连 `sleep 10` 心跳进程都不存在；宿主机看 PID 1 阻塞在
`wait4(-1)`；额外代价是每轮泄漏一对孤儿 `tail`/`sed`（PPID 变 1）。

修复要点：

- 变量从单值 `DSH_FOLLOW_PID` 改为**数组** `DSH_FOLLOW_PIDS`；
- 新增 `collect_pipe_children()`，遍历 `/proc` 按 **`PPid == $$`** 反查，
  把管道三段全部收齐（无 `ps`/`pkill` 时这是唯一可行手段）；
- `stop_dsh_log_follow()` **删掉 `wait`** —— 这是挂起的直接原因；
  改为逐个 `kill`，再兜底扫一遍 `PPid == $$` 的成员。

> 容器内实测：修复前该函数**无限挂起**（2 分钟未返回）；
> 修复后 **0.064s** 返回，管道清理干净、零残留、零误伤。
> 回归测试见用例 14：起真实 `tail|sed|grep` 管道后调用函数，
> 用后台 watchdog 计时，断言「必须在 3s 内返回」。

同理，`start_dsh()` 重试路径里 `wait "$DSH_PID"` 也有同源风险（`dsh` 是
pnpm 包装壳，kill 掉壳后子进程可能仍在），已改为**限时轮询**（最多 5s）。

**通用教训**：在 shell 里，`wait` 只应对**明确的单个进程 PID** 使用；
面对管道 / 包装器这类「一个 `$!` 背后可能有多个进程」的场景，
宁可用 `kill -0` 轮询 + `/proc` 实查，也不要 `wait`。

### 4.3 日志转发：为什么不是一条 `tail -F` 就完事

把 `/dsh/log/*/*.log` 转发到终端（`docker logs`）看着简单，但要做到「可靠」，
有四件事必须一起处理，缺一件用户就会觉得「日志没刷新」：

| # | 要求 | 不做的后果 |
|---|------|-----------|
| 1 | 覆盖**全部**日志文件 | 只跟 `dsh-web.log` 时，DSH 首次启动装依赖的那 ~9 分钟里，nginx / 插件日志全不可见 |
| 2 | 每行带 `[HH:MM:SS]` | 多文件混排时分不清哪行是什么时候产生的 |
| 3 | 运行中**新建**的文件也要跟 | 新装插件新建的 `.log` 永远看不到（`tail -F` 只能重启跟踪**参数里已有**的文件） |
| 4 | 停止时**不漏孤儿** | 每次重启都泄漏一对 `tail`/`while`，越积越多 |

实现上对应四个要点：

**要点 1 —— 覆盖 + 纳新**。转发整体放进一个 **supervisor 子 shell**：

```bash
start_log_follow() {
    stop_log_follow
    (
        mapfile -t files < <(collect_log_files)      # 当前全部日志文件
        tail -F "${files[@]}" 2>/dev/null | while IFS= read -r line; do
            [ -z "$line" ] && continue
            printf '[%(%H:%M:%S)T] %s\n' -1 "$line"  # 内建格式化，零 fork
        done
    ) &
    LOG_TAIL_PID=$!
    LOG_FILES_SNAPSHOT="$(collect_log_files | tr '\n' ' ')"
}
```

看护循环每 10s 比一次 `log_files_changed`，集合变了就整体重启转发
（`tail` 没法动态加参数，只能重启）。

**要点 2 —— 时间戳为什么不用 `awk`**。最直觉的写法是
`awk '{ printf "[%s] %s\n", strftime("%H:%M:%S"), $0 }'`，但
**slim 镜像里的 mawk 不保证有 `strftime`** ——实测静默输出 0 行，非常隐蔽。
`date` 每行 fork 一次又太重。最终用 **bash 内建的
`printf '%(%H:%M:%S)T'`**：零 fork，2000 行实测 < 1s 处理完。

**要点 3 —— 清理顺序决定成败**。supervisor 是子 shell，`tail` 和 `while`
都是它的**子孙**。这里藏着一个坑：

```
先 kill supervisor → 子孙被 reparent 到 PID 1 → PPID 链断了 → 再也找不到
```

所以必须**先列全子孙、再统一 kill**：

```bash
local -a victims=("$LOG_TAIL_PID")
while IFS= read -r pid; do victims+=("$pid"); done \
    < <(collect_tail_children "$LOG_TAIL_PID")
for pid in "${victims[@]}"; do kill "$pid" 2>/dev/null || true; done
```

`collect_tail_children` 靠 `/proc/<pid>/status` 的 `PPid` 逐层 BFS
（容器内无 `pkill` / `ps`）。

**要点 4 —— [4/6] 与 [6/6] 共用同一个转发器**。早先两处各写一份，
[4/6] 只看一个文件、[6/6] 才看全部，于是「启动期看不到日志」。
现在两处都调 `start_log_follow`，行为一致。

> 回归测试见用例 15：造一个真实日志目录，断言转发覆盖全部文件、
> 每行带时间戳、新建文件能被 `log_files_changed` 检出、清理后无孤儿。

---

## 5. 访问 token 的生命周期

DSH Web UI 是 **token 鉴权**的：不带 `?token=` 访问只会得到 401。

- token 由 `randomBytes` 生成，**内存态，不持久化**；
- 每次启动（含 `dsh-ctl` 重启）都会生成**新 token**；
- 唯一可靠的来源是日志里的 `dsh web: ...?token=xxx` 行。

**日志为什么是「取最后一条」**：日志文件**追加而非截断**，
且 `dsh-ctl` 的重启日志（`dsh-ctl-relaunch.log`）经软链并入同一份日志。
所以 `tail -1` 拿到的就是当前有效 token。

**看护期自动播报**：重启后 PID 变化，看护会重新解析日志；
若 token 确实变了，就重播一次访问地址块。

> 只在 token **真的变化**时才打印，否则每 10s 轮询都会刷一屏。

**为什么 `容器内直连` / `LAN 访问` 两行也带 token**：
它们此前被 `sed` 主动删掉了 `?token=`，用户复制过去直接 401。
既然 DSH 是 token 鉴权的，这两条地址就必须带上 token 才有意义。

---

## 6. Python 与内置插件的依赖关系

**DSH 本体不依赖 Python**，但内置插件 `@chengxianglibra/dsh-data-analysis` 依赖。

该插件的 `cordis.patch.yml` 里声明：

```yaml
pythonExecutable:          !!js process.env.DSH_DATA_ANALYSIS_PYTHON
bootstrapPythonExecutable: !!js process.env.DSH_DATA_ANALYSIS_BOOTSTRAP_PYTHON
```

加载时会执行 `<bootstrap> -m venv <runtimeRoot>/.venv` 建**它自己的**托管运行时，
再在其中装 `marivo`/`pandas`，要求 **Python ≥ 3.10 且带 `venv`/`ensurepip`**。

若镜像里没有 Python，插件 `apply()` 抛 `MarivoEnvironmentError`，
导致 cordis **整棵插件树**加载失败、DSH 进程退出。
现象就是「服务起不来、拿不到 token、日志里全是 Node 崩溃栈」。

**这就是 `PYTHON_MODE` 默认 `apt` 的原因** —— 不是 DSH 需要，是这个内置插件需要。

### 为什么只设 `BOOTSTRAP_PYTHON`，不设 `PYTHON`

插件把 `pythonExecutable` 理解为「**它自己托管运行时内**的解释器」：
`validatedExisting()` 会拿它和 `record.pythonExecutable`
（即 `<runtimeRoot>/.venv/bin/python`）做**严格相等**比较，不一致就判定运行时失效、
**重新安装一遍**。

若我们把它指到 `/dsh/app/python/venv`，必然不相等 → 插件每次启动都重建自己的运行时。
所以只给「引导解释器」，让插件按自身设计创建/复用它自己的 venv。

变量对照：

| 环境变量 | 本镜像 | 用途 |
|---------|--------|------|
| `DSH_DATA_ANALYSIS_BOOTSTRAP_PYTHON` | **设置** → `/dsh/app/python/bin/python3` | 引导解释器 |
| `DSH_DATA_ANALYSIS_PYTHON` | 刻意留空 | 插件托管运行时内的解释器 |
| `DSH_DATA_ANALYSIS_RUNTIME_ROOT` | 不设 | 托管运行时根目录 |
| `DSH_DATA_ANALYSIS_PROJECT_ROOT` | 不设 | 项目根目录 |

显式导出的理由：兜底 `PATH` 被覆盖、或 `dsh-ctl` 从进程外拉起 DSH 的场景 ——
那时 `python3` 可能不在搜索路径里。

---

## 7. apt 与 source 两种模式的目录对齐

apt **无法**把 Python 装到 `/dsh`：dpkg 包的安装路径在打包时就固化了，
Debian 的 Python 把 `/usr` 编译进了 `sys.prefix`（实测 `sys.prefix=/usr`），
共享库在 `/usr/lib/<triplet>/`，整体重定位会直接破坏解释器。

所以 apt 模式用软链折中，让 `/dsh` 下的目录约定在两种模式下保持一致：

| 路径 | apt 模式 | source 模式 |
|------|---------|------------|
| `/dsh/app/python/bin/python3` | 软链 → `/usr/bin/python3` | 真实文件 |
| `/dsh/app/python/bin/pip3` | 软链 → venv 内 pip | 软链 → venv 内 pip |
| `/dsh/app/python/venv/` | venv（基于系统解释器） | venv（基于 3.14.7） |

两种模式下 `PATH` 都保持干净：先判断 `/dsh/app/python/bin/python3` 是否存在，
存在才把路径追加进去，避免 `none` 模式下残留指向空目录的条目。

构建结束时会自检「模式 vs 实际产物」是否一致，不一致直接构建失败。

| 模式 | 版本 | 体积（amd64 实测） |
|------|------|------|
| `apt`（默认） | 3.13.5 | 约 550 MB |
| `source` | 3.14.7 | 约 1.08 GB |
| `none` | — | 约 417 MB |

---

## 8. locale 与中文显示

**现象**（≤ v0.3.7）：`less script/entrypoint.sh` 提示
`"may be a binary file. See it anyway?"`，中文显示成 `<E5><8A><A0>` 之类。

**根因不在脚本编码**（脚本一直是干净的 UTF-8），而在显示层：
`debian:*-slim` 基础镜像**不设置任何 locale**，容器内 `LANG`/`LC_ALL` 为空，
glibc 回退到 POSIX/C locale（`LC_CTYPE="POSIX"`）。
此时 `less` 按**单字节**处理文本，看到 UTF-8 的中文多字节序列就误判为二进制，
并以 `cat -v` 风格逐字节转义输出。

**一句话辨别**：`head -n 20 script/entrypoint.sh` 输出正常、但 `less` 报二进制
→ 问题在 locale，不在文件内容。

**修复**（v0.3.8 起）：镜像内置 `ENV LANG=LC_ALL=C.UTF-8`
（由 glibc 内置，Debian 自带，无需 `locale-gen`），
同时装上 `less` 与 `file`（slim 镜像默认不含）。
`profile.env` 里再兜底一次，防止被 `-e LC_ALL=` 覆盖。

---

## 9. Nginx 路径软链

Nginx 二进制由 apt 安装（`/usr/sbin/nginx`），但配置与日志路径都指向 `/dsh`：

```
/etc/nginx/nginx.conf → /dsh/config/nginx/nginx.conf
/etc/nginx/conf.d     → /dsh/config/nginx/conf.d
/var/log/nginx        → /dsh/log/nginx
```

这样 `/dsh` 依然是「唯一需要挂载/备份的目录」，符合绿色部署的承诺。

**反向代理的两个关键 header**：

| Header | 值 | 作用 |
|--------|-----|------|
| `Host` | `127.0.0.1:3080` | 让 DSH 认为请求来自本地，绕过局域网限制 |
| `Origin` | `""`（清空） | 使跨站检查失效 |

同时处理 WebSocket 的 `Upgrade`/`Connection`，并把超时放宽到 3600s（长连接）。

### 9.1 访问日志里的真实客户端 IP

**问题**：`log_format main` 第一列原本用 `$remote_addr`，它记的是**最后一跳**，
不是访问者。DSH 放在端口映射 / 网关 / LB 后面时，这一列会变成 Docker 网关
（`172.17.0.1`）或容器自身 IP —— 真机反馈里看到的正是这种情况，排查问题时
看不出请求来自谁。

真实 IP 其实一直都在：上游逐跳写进 `X-Forwarded-For`，形如
`<真实客户端IP>, <代理1>, <代理2>, ...`。

**方案**：启用 nginx 内置的 `http_realip_module`（Debian 包已编译）改写
`$remote_addr`：

```nginx
set_real_ip_from  0.0.0.0/0;
set_real_ip_from  ::/0;
real_ip_header    X-Forwarded-For;
real_ip_recursive on;
```

模块从 XFF **右端往左**剔除可信地址，把第一个不可信地址写回 `$remote_addr`。
因为这里信任所有来源，效果等价于「取 XFF 最左值」。

**为什么信任所有来源**：DSH 的前置代理形态不可预知（裸 docker run、k8s、
各类网关/LB），写死可信段会让一批场景取不到真实 IP。代价是 XFF 可被伪造 ——
对**内网 / 可信网络**的排查定位场景可以接受；若暴露公网且需防伪造，
应把 `set_real_ip_from` 收敛为实际代理网段。

> 收敛时注意两点：
> 1. 要把链路上**每一跳**都列全 —— `real_ip_recursive` 从右往左剔除，
>    漏一跳就会取到中间代理的地址而不是真实客户端（实测复现过）；
> 2. `set_real_ip_from` 是**累加**语义，`0.0.0.0/0` 在场时追加的段完全无效，
>    所以收敛要**替换**而不是追加。

日志末尾保留两个辅助字段，多层代理排查时有用：

| 字段 | 取值 | 用途 |
|------|------|------|
| `hop=` | `$realip_remote_addr` | realip **改写前**的直连跳，用来看请求从哪进来的 |
| `xff=` | `$http_x_forwarded_for` | 完整 XFF 链 |

实测：

| 输入 XFF | 第 1 列 | `hop=` |
|----------|---------|--------|
| `10.88.7.123, 10.0.2.100` | `10.88.7.123` | 直连跳 |
| *(空)* | 直连跳（回退） | 直连跳 |
| `fe80::1, 10.0.2.100` | `fe80::1` | 直连跳 |
| `172.16.5.9, 10.0.2.100, 10.0.2.101` | `172.16.5.9` | 直连跳 |

---

## 10. 插件注册校验：为什么必须用词边界

校验插件是否已注册，用的是 `dsh plugin list` 的输出：

```bash
dsh plugin --profile "$profile" list | grep -qE "(^|[^A-Za-z0-9._-])${name}([^A-Za-z0-9._-]|$)"
```

**不能**写成 `grep -q "$name"`：后者是子串匹配，
当 `dsh-ctl-helper` 存在时会把 `dsh-ctl` 误判为「已注册」，
导致真正缺失的插件不被补装。

**为什么两处都写了同一份逻辑**：`entrypoint.sh` 与 `install-dsh.sh`
被 Dockerfile 分别 `COPY` 进镜像，**无法互相 source**。
所以这个表达式在两处**必须逐字一致**，改一处要同步另一处
（`test/test_versions_parser.sh` 有用例守住这点）。

**为什么日志文件名要安全化**：npm scope 包名形如 `@scope/pkg`，
直接拼进路径会得到 `.../@scope/pkg.log` —— 把 `@scope` 当成子目录，
而该目录不存在。`tee` 写入失败在 `set -o pipefail` 下会让整条管道返回非零，
安装被误判为失败。所以把 `/` 等字符统一替换为 `__`。
