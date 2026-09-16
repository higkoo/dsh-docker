# 变更记录

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。
`v0.4.0` 起进入稳定维护阶段，只做向后兼容的修复与打磨。

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

[Unreleased]: https://github.com/higkoo/dsh-docker/compare/v0.4.0...HEAD
[v0.4.0]: https://github.com/higkoo/dsh-docker/releases/tag/v0.4.0
[v0.3.9]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.9
[v0.3.8]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.8
[v0.3.7]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.7
[v0.3.6]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.6
[v0.3.5]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.5
[v0.3.2]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.2
[v0.3.1]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.1
[v0.3.0]: https://github.com/higkoo/dsh-docker/releases/tag/v0.3.0
