# 变更记录

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
`v0.4.0` 起进入稳定维护阶段，只做向后兼容的修复与打磨。

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
