# 变更记录

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
`v0.4.0` 起进入稳定维护阶段，只做向后兼容的修复与打磨。

---

## [v0.4.4] — 2026-09-17 · 插件安装开关，数据分析插件默认不装

### 背景

数据分析插件 `@chengxianglibra/dsh-data-analysis` 依赖本地 Python 且要 pip 拉
`marivo`，体量大、首次装包慢，而大多数部署并不需要自然语言分析 / 图表 / 看板。
之前它是无条件安装的，没法关掉。

### 改进

- **新增通用 `enabled` 插件开关**：`config/dsh/versions.yml` 里每个插件都支持
  `enabled: true/false`。**缺省即启用**，所以老配置无需改动。

  ```yaml
  plugins:
    - name: '@chengxianglibra/dsh-data-analysis'
      version: latest
      profile: web
      enabled: false        # 跳过安装，配置完整保留
  ```

- **数据分析插件默认关闭**：`enabled: false`，配置（name / version / url / profile）
  原样保留。容器首次启动实测约 25s（此前 60s+）。

- **跳过时给明确提示**，避免用户困惑「功能怎么没了」：

  ```
  跳过插件: @chengxianglibra/dsh-data-analysis
    原因：versions.yml 中 enabled: false
    如需启用：把该插件的 enabled 改为 true，然后重启容器。
  ```

- **环境变量覆盖**：`-e DSH_ENABLE_DATA_ANALYSIS=true` 可在不改配置的情况下
  临时启用，优先级高于 `versions.yml`。

- **首装与补装逻辑对齐**：`entrypoint.sh` 的补装兜底原本只认固定插件名单，
  现在也读 `versions.yml` 并支持同样的环境变量覆盖，避免「首次装上了、
  重启后又按跳过处理」这种不一致。

### 开关语义

| 写法 | 行为 |
|------|------|
| 不写 `enabled` | 启用（向后兼容） |
| `enabled: true` | 启用；装失败则 `exit 1` |
| `enabled: false` | 跳过安装，配置保留 |
| `-e DSH_ENABLE_DATA_ANALYSIS=true` | 覆盖 `versions.yml`，强制启用该插件 |

已实测三条路径行为一致：默认关闭 / 改 yml 为 true / 环境变量覆盖。
另验证插件被手动删除后，重启容器补装逻辑只补核心插件、不误装被关闭的插件。

### 改动文件

```
 CHANGELOG.md                  | 本节
 README.md                     | 插件开关章节 + 环境变量表 + Python 说明
 profile.env                   | 登记 DSH_ENABLE_DATA_ANALYSIS
 config/dsh/versions.yml       | data-analysis 加 enabled: false
 script/install-dsh.sh         | 解析 enabled + 跳过逻辑 + 环境变量覆盖
 script/entrypoint.sh          | 补装兜底同源读 yml + 环境变量覆盖
 test/test_versions_parser.sh  | 新增用例16–20（解析/判定/真实配置/一致性）
```

测试：`test_versions_parser.sh` 82 → 100 条断言，全绿；`shellcheck -S warning` 通过。

---

## [v0.4.3] — 2026-09-17 · 访问日志显示来访者真实 IP

真机反馈：Nginx 访问日志里客户端一栏显示的是 `10.0.2.100`，不是访问者
—— 排查问题时看不出请求来自谁。

原因是 `log_format main` 第一列用了 `$remote_addr`，它记的是**最后一跳**，
不是来源。DSH 放在端口映射 / 网关 / LB 后面时，这一列会变成网关或容器地址。

### 改进

- **启用 `http_realip_module` 改写 `$remote_addr`**（Debian 的 nginx 包已编译，
  无需额外安装）。当上游在 `X-Forwarded-For` 里写了真实 IP 时，
  日志第 1 列即为真实客户端 IP：

  ```nginx
  set_real_ip_from  0.0.0.0/0;
  set_real_ip_from  ::/0;
  real_ip_header    X-Forwarded-For;
  real_ip_recursive on;
  ```

  信任所有直接来源 —— 前置代理形态不可预知，写死可信段会有一批场景取不到
  真实 IP。适用于内网 / 可信网络；若暴露到公网且需防伪造，应把
  `set_real_ip_from` 收敛为实际代理网段。

  实测四种 XFF 输入均正确解析：

  | 输入 XFF | 第 1 列 |
  |----------|---------|
  | `10.88.7.123, 10.0.2.100`（两跳） | `10.88.7.123` |
  | *(空，无 XFF)* | 直连地址（回退） |
  | `fe80::1, 10.0.2.100`（IPv6） | `fe80::1` |
  | `172.16.5.9, 10.0.2.100, 10.0.2.101`（三跳） | `172.16.5.9` |

  日志末尾保留 `hop=`（realip 改写前的直连跳）与 `xff=`（完整 XFF 链），
  多层代理排查时能看清请求经过哪些跳。

> ⚠️ **前提：上游必须真的写了 `X-Forwarded-For`。**
> realip 只能**解析**已存在的 XFF，自己不会推断来源。**裸端口映射部署下
> 无人写 XFF，本改动不生效** —— 日志第 1 列与 `hop=` 会保持相同值，且
> `xff="-"`。这种情况需要用 host 网络或保留源 IP 的转发方式，
> 详见 [README「访问日志里的客户端 IP」](README.md#访问日志里的客户端-ip)。
> 早期文档曾把「XFF 链完整存在」写成既定事实，实为误读 `xff="-"`（空值的
> 正常显示），此处已更正。

- **README 补充受限网络的 registry 配置**：两处**不读 npmrc** 的依赖，
  在访问不了公网时会导致容器 `exit 1`：

  | 变量 | 为什么必须单独设 |
  |------|-----------------|
  | `COREPACK_NPM_REGISTRY` | pnpm 是 Corepack 包装器，自举下自身二进制时**只认这个变量**，`npmrc` 与 `npm_config_registry` 均无效 |
  | `PIP_INDEX_URL` | 数据分析插件用 pip 装 `marivo`，容器内**没有 pip 配置** |

---

## [v0.4.2] — 2026-09-16 · 修复看护循环被永久阻塞 + 日志转发三处改进

本轮来自对**已发布的 v0.4.1 真实镜像**的功能测试：容器起来、DSH 就绪、
鉴权与 Web UI 都正常，但**看护循环从未运行** —— DSH 被 kill 后容器仍永久
`running`、毫无反应。定位到 `stop_dsh_log_follow()` 里的一个致命写法。
顺带修掉测试中暴露的**日志转发三处盲区**。

### 修复

- **`stop_dsh_log_follow()` 的 `wait` 会永久挂起，导致 [6/6] 看护循环永不执行**：

  三处问题叠加——

  1. `start_dsh()` 用 `tail -F ... | sed ... | grep ... &` 起日志转发，
     `$!` 拿到的是**管道最后一段（`grep`）的 PID**；
  2. 容器内**没有 `ps` / `pkill`**（slim 镜像），`pkill -P "$DSH_FOLLOW_PID"`
     恒返回 127（被 `|| true` 吞掉），`tail` / `sed` **从来没被清理过**；
  3. `stop_dsh_log_follow()` 里 `wait "$DSH_FOLLOW_PID"`：管道是一个 **job**，
     kill 掉尾端 `grep` 后 `tail` / `sed` 仍存活，`wait` 会等整个 job 结束。
     在脚本顶层（`set -e`）表现为**永久阻塞**。

  后果：`[6/6]` 段第 504 行调用 `stop_dsh_log_follow` 时**直接卡死**，
  脚本再也走不到下面的看护 `while` 循环。容器表现为：

  - 日志停在 `[6/6] 开始跟踪日志...` 之后**再无任何输出**；
  - 容器永久 `running`，DSH 崩溃也**不会退出**、`--restart` 也救不了；
  - 每轮都泄漏一对孤儿 `tail` / `sed`（PPID 变 1），实测会越积越多。

  修复：

  - `DSH_FOLLOW_PID`（单值）改为 `DSH_FOLLOW_PIDS`（**数组**），
     用 `collect_pipe_children()` 遍历 `/proc` 按 `PPid == $$` 反查，
     把管道三段（`tail` / `sed` / `grep`）**全部**收进数组；
  - `stop_dsh_log_follow()` **删除 `wait`**（这是挂起的直接原因），
     改为逐个 `kill` 数组内 PID，再兜底扫一遍 `PPid == $$` 的管道成员；
  - 顺带删掉对**不存在**的 `pkill` 的依赖。

  实测（容器内）：修复前该函数**无限挂起**（2 分钟未返回）；
  修复后 **0.064s** 返回，管道成员清理干净、零残留、零误伤。
  新增回归测试用例 14（48 项测试），断言「函数必须在 3s 内返回」。

  > 该缺陷 v0.4.0 及更早即存在（`git show e18e5d8` 可核对，代码逐字相同），
  > 非本次引入。这意味着**已发布的 v0.4.0 / v0.4.1 镜像，只要真的走到
  > `[6/6]`，看护就是完全失效的**。

- **`start_dsh()` 重试路径的 `wait "$DSH_PID"` 同源风险**：`dsh` 是 pnpm 包装壳，
  kill 掉壳后子进程可能仍存活，`wait` 会一直等下去。改为**限时轮询**
  （最多 5s），超时即放过。

- **日志转发三处盲区**（同一轮测试中发现）：

  1. **启动阶段只看 `dsh-web.log`**：[4/6] 起的转发管道只跟 `$DSH_LOG` 一个文件，
     而 DSH 首次启动要装插件的重依赖（实测约 **9 分钟**），这段时间
     `nginx/access.log`、`nginx/error.log`、各插件日志在 `docker logs` 里
     **完全不可见**，用户很容易误以为「日志不刷新」。
  2. **运行中新建的日志文件永不转发**：`LOG_FILES` 是 [6/6] 那一刻 glob 的
     **一次性快照**，之后新装的插件新建的 `.log` 不会被 `tail` 看到
     （`tail -F` 只能重启跟踪**参数里已有的**文件）。
  3. **转发行没有时间戳**：多文件混排时看不出某行是什么时候产生的。

  修复：把日志转发抽成统一的 `start_log_follow()`，[4/6] 与 [6/6] 共用：

  - 始终覆盖 `$DSH_ROOT/log/*/*.log` **全部**文件；
  - 每行加 `[HH:MM:SS]` 时间戳（用 bash 内建 `printf '%()T'`，**零 fork**；
    `awk` 的 `strftime` 在 slim 镜像的 mawk 上静默不输出，故不用）；
  - 看护循环每 10s 比对一次文件集合，**发现新文件就重启转发**把它纳入。

- **`stop_log_follow()` 先 kill 后扫描导致孤儿**：supervisor 是子 shell，
  一旦先 kill 掉它，`tail` / `while` 会被 reparent 到 PID 1，PPID 链断开、
  再也找不到 → 每次泄漏一对孤儿。改为**先列出全部子孙、再统一 kill**。

### 改进

- **`entrypoint.sh`**：`612` → `~700` 行。新增 `start_log_follow()` /
  `collect_log_files()` / `log_files_changed()` / `stop_log_follow()` /
  `collect_tail_children()` / `collect_pids_by_ppid()`，
  删除 `collect_pipe_children()` / `stop_dsh_log_follow()`。
- **`test/test_versions_parser.sh`**：用例 13 适配新架构；用例 14 改为测
  `stop_log_follow` 不挂起；**新增用例 15** 覆盖「全部文件 / 时间戳 / 纳入新建」；
  测试总数 `45` → `53`。
- **README**：日志章节补充「`docker logs` 转发全部日志 + 时间戳 + 自动纳新」
  的说明与新现象对照行。

### 双向验证

| 代码版本 | 用例 13 | 用例 14 | 用例 15 | 结果 |
|---------|--------|--------|--------|------|
| v0.4.1（旧） | 执行即**永久挂起**（2 分钟被强杀） | 未执行 | — | ❌ |
| v0.4.2（新） | PASS | PASS | PASS | ✅ 53/53 |

真机验证（用 v0.4.1 镜像 + 新 `entrypoint.sh` 构建）：

- `[4/6]` 起 `docker logs` 即出现 **8 个文件全部内容**，每行带 `[HH:MM:SS]`；
- 运行中新建 `/dsh/log/brandnew/b.log` → 看护循环检测到变化并**自动纳入转发**；
- 停止转发后**零孤儿进程**。

---

## [v0.4.1] — 2026-09-16 · 文档与脚本梳理

本轮做「可读性」收口：把原理从代码和 README 里抽出、集中到一份设计文档；
同时修掉一个在冒烟测试中暴露的**既存缺陷**（见下）。

### 修复

- **DSH 崩溃无法被识别，容器永久卡在启动态**：`start_dsh()` 里
  `DSH_PID=$!` 写在日志转发管道之后，而**管道后台作业的 `$!` 是管道最后一段
  （`grep`）的 PID** —— 于是 `DSH_PID` 记成了 grep 的 PID。grep 跟的是日志文件，
  只要文件还在就永远活着，`kill -0 "$DSH_PID"` 因此永远成功，
  「进程已退出」判据**永不成立**：
  - 就绪阶段：DSH 崩了也判不出来，只能靠硬上限兜底；默认 `DSH_READY_HARD_TIMEOUT=0`
    （不限）时**容器永远打「启动中」心跳、永不退出**，`--restart` 也救不了；
  - 看护阶段：`[看护] DSH 进程仍在` 提示同样是假的。

  现改为**紧跟 `dsh ... &` 之后立即取 `$!`**，再起 tail 管道。
  实测：修复前崩溃后容器永久 `running`；修复后 **0s 内**打印「DSH 进程已退出」，
  重试 3 轮后 `exit 1`。新增回归测试用例 13（45 项测试）。
  > 该缺陷 v0.4.0 及更早即存在，非本次梳理引入。

- **失败文案自相矛盾**：`wait_dsh_ready` 有两种失败原因（`exited` 真崩溃 /
  `timeout` 命中硬上限），但调用方一律打印「进程已退出」，会出现
  「达到硬上限（进程仍在运行）」紧跟「检测到启动失败（进程已退出）」。
  现按实际原因分别提示。

### 新增

- **`docs/DESIGN.md`**：集中记录实现原理与关键决策（启动流程、就绪判定为何用事件、
  日志落盘为何放弃 FIFO+tee、看护为何看 HTTP 而非 PID、`$!` 的坑、token 生命周期、
  Python 与插件依赖、apt/source 目录对齐、locale、Nginx 软链、插件校验词边界）。
  代码里只留「这段做什么 + 有什么坑」，历史考证移入此文档。

### 改进

- **README 重定位为「用法书」**：`546` → `303` 行，改为「是什么 → 一条命令跑起来 →
  怎么访问 → 常用配置 → 出问题怎么办」的小白视角，并新增「常见现象对照表」。
  原理性长文改为一句结论 + 链接 `docs/DESIGN.md`。
- **脚本注释瘦身**：`entrypoint.sh` `770` → `612` 行（注释 `305` → `143` 行）、
  `install-dsh.sh` `311` → `299` 行（注释 `71` → `59` 行）。
  纯文档阶段两脚本**有效代码零改动**（剥离注释后逐行 byte 级一致）；
  最终 `entrypoint.sh` 有效代码 `399` → `406` 行，差额即上述两处修复新增的语句。
- 修正 README 中两处指向设计文档的锚点、一处设计文档内部目录锚点。

---

## [v0.4.0] — 2026-09-16 · 稳定版

首个稳定维护版本。功能已可用，本轮做一轮收口：修真实问题、补齐汉化、精简冗余、统一文案。

### 修复

- **`dshctl` 重启后访问地址失效**：重启会生成新 token，但看护循环此前只刷新 PID，
  首屏打印的地址静默失效。现在检测到 PID 变化时会重新解析 token 并打印新地址
  （仅在 token 确实变化时触发，不会刷屏）。
- **访问地址丢失 token**：`容器内直连` / `LAN 访问` 两行此前会把 `?token=` 参数
  **删掉**后再打印，而 DSH Web UI 是 token 鉴权的 —— 用户复制这两条地址只会得到 401。
  现改为**保留 token**。
- **插件注册校验词边界**：`install-dsh.sh` 使用无词边界的 `grep -q "$name"`，
  会在 `dsh-ctl-helper` 存在时把 `dsh-ctl` 误判为已注册，导致真正缺失的插件不被补装。
  现统一为词边界匹配，并与 `entrypoint.sh` 的表达式逐字一致。
- **插件 `profile` 默认值不一致**：`install-dsh.sh` 用 `default`、`entrypoint.sh` 用 `web`，
  现统一为 `web`。
- **脚本可执行位未入库**：`script/*.sh` 在 git 中记录为 `644`（依赖 Dockerfile 的
  `chmod +x` 兜底）。现改为在 git 中直接记录 `755`。

### 改进

- **汉化**：`[watchdog]` → `[看护]`；`Nginx PID` → `Nginx 进程 PID`；
  `<Your-IP>` → `<你的IP>`；`Profile`/`profile` → `配置档`；`unknown` → `未知`。
- **精简**：首屏横幅不再预先列出 6 个步骤（各步骤执行时会各自打印 `[N/6]`，属重复播报）；
  压缩两处冗余注释。
- **文案统一**：中文语境统一使用全角 `错误：`/`警告：`；`[N/6]` 步骤行缩进对齐；
  看护期重播地址块的标题改为「DSH 已重启，token 已更新，新访问地址」
  （此前复用「已就绪」，与「只是 token 变了」的语义不符）。
- **配置可调**：`profile.env` 新增 `DSH_READY_TIMEOUT`、`DSH_READY_HARD_TIMEOUT`、
  `DSH_DOWN_GRACE` 三个可调项。
- 新增本 CHANGELOG。

---

## [v0.3.9] — 2026-09-15

- 就绪判定改为「看进程存活」而非固定超时：`DSH_READY_TIMEOUT` 降级为**提示频率的软上限**，
  不再因超时判失败；新增 `DSH_READY_HARD_TIMEOUT`（默认 0 = 不限）。
- 启动期实时转发 DSH 日志到终端，插件加载进度可见。

## [v0.3.8] — 2026-09-15

- 补齐容器 locale（`C.UTF-8`）并内置 `less`/`file`，修复容器内查看含中文文件时
  被当作二进制、中文显示为 `<E5><8A><A0>` 的问题。

## [v0.3.7] — 2026-09-15

- 重写启动就绪判定与状态输出，去掉固定超时与盲目重启。

## [v0.3.6] — 2026-09-15

- 恢复 Python 默认安装（`PYTHON_MODE=apt`），并显式导出插件所需的 Python 环境变量。

## [v0.3.5] — 2026-09-15

- Python 改为默认不安装（`PYTHON_MODE=none`）。**注：该默认值会导致内置数据分析插件
  加载失败、DSH 起不来，已在 v0.3.6 回退。**

## [v0.3.2] / [v0.3.1] / [v0.3.0] — 2026-09

- 早期迭代版本，已停止维护并从镜像仓库移除。

---

[v0.4.1]: https://github.com/higkoo/dsh-docker/releases/tag/v0.4.1
[v0.4.0]: https://github.com/higkoo/dsh-docker/releases/tag/v0.4.0
[v0.3.9]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.9
[v0.3.8]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.8
[v0.3.7]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.7
[v0.3.6]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.6
[v0.3.5]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.5
[v0.3.2]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.2
[v0.3.1]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.1
[v0.3.0]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.0
