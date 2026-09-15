# DSH Docker — 绿色部署方案

基于 Docker 一键部署 [DeepSeek Harness (DSH)](https://github.com/deepseek-ai/deepseek-harness) 的绿色安装镜像方案。

## 核心特性

- **绿色安装**：所有组件（Node.js 24、Python 3.14、Nginx）安装在 `/dsh` 目录下，不污染系统
- **软链接**：核心二进制软链接到 `/usr/local/bin`，全局可用
- **可选组件**：Python 由构建参数 `PYTHON_MODE` 控制，默认用 apt 装发行版自带版本，需要锁定版本时可切源码编译（[详见](#python-安装模式python_mode)）
- **多平台**：同一标签同时提供 `linux/amd64` 与 `linux/arm64`
- **阿里云源**：apt 和 npm 均使用国内镜像加速
- **版本化配置**：通过 `versions.yml` 管理 DSH 及插件版本，支持组件名+版本号和直接 URL 两种安装方式
- **Ansible 编排**：提供 Ansible Playbook 读取版本配置并自动部署
- **健康检查**：Nginx 提供 `/health` 状态页面，启动阶段会校验 Nginx 与 DSH 均就绪才放行
- **进程看护**：内置服务级 watchdog，以 HTTP 可用性判定存活；DSH/Nginx 意外退出时容器一并退出，便于 `restart_policy` 拉起
- **重启友好**：`dshctl restart` 等计划内重启不会被误判为崩溃，重启后新 token 会追加写入日志
- **时区可配**：默认北京时间（`Asia/Shanghai`），`date` 与 Nginx 日志时间戳均为东八区
- **日志集中**：所有日志统一存放在 `/dsh/log/<分类>/*.log` 下；容器前台跟踪全部日志，`docker logs` 一览无余

## /dsh 目录结构

```
/dsh/
├── app/                         # 应用程序安装目录（绿色安装）
│   ├── nodejs/                  # Node.js 24（预编译二进制）
│   │   ├── bin/                 # node, npm, npx, pnpm
│   │   └── lib/                 # 全局 npm 包
│   └── python/                  # Python（可选，PYTHON_MODE 控制）
│       ├── bin/                 # python3, pip3      ← none 模式时不存在
│       ├── lib/                 # 仅 source 模式：Python 标准库 + 共享库
│       └── venv/                # Python 虚拟环境
│
├── profile.env                  # 环境变量配置（可手动 source 生效）
│
├── config/                      # 配置文件目录
│   ├── nginx/                   # Nginx 配置
│   │   ├── nginx.conf           # Nginx 主配置
│   │   ├── conf.d/              # 站点配置目录
│   │   │   └── dsh-proxy.conf   # DSH 反向代理 + 健康检查
│   │   └── ssl/                 # SSL 证书目录
│   │       ├── dsh.crt          # 自签证书（容器首次启动时生成）
│   │       └── dsh.key          # 私钥
│   ├── dsh/                     # DSH 配置
│   │   └── versions.yml         # DSH 及插件版本配置
│   └── ansible/                 # Ansible 部署脚本（构建时复制进镜像）
│       ├── playbook.yml         # 部署 Playbook
│       └── inventory.ini        # 主机清单
│
├── log/                         # 日志目录（分类管理）
│   ├── nginx/                   # Nginx 日志
│   │   ├── access.log           # 访问日志
│   │   └── error.log            # 错误日志
│   ├── dsh/                     # DSH 运行日志
│   │   ├── dsh-web.log          # Web UI 运行日志
│   │   └── install.log          # 安装日志
│   └── plugins/                 # 插件日志
│       ├── dsh-web-lan-access.log
│       ├── dsh-ctl.log
│       ├── dsh-ctl-relaunch.log # ctl 重启 DSH 的接力日志（含重启后的新 token）
│       └── __chengxianglibra__dsh-data-analysis.log  # 数据分析插件（包名 '/' 已安全化）
│
├── run/                         # 运行时目录
│   ├── nginx.pid                # Nginx PID（由 nginx 自身写入）
│   └── dsh.pid                  # DSH PID
│
├── workspace/                   # DSH 工作区
│
├── home/                        # DSH 数据目录（DSH_HOME）
│   └── profiles/                # 插件 profile 目录
│
└── script/                      # 脚本目录
    ├── entrypoint.sh            # 容器启动入口
    └── install-dsh.sh           # DSH 及插件安装脚本
```

> **Nginx 路径说明**：Nginx 二进制由 apt 安装（`/usr/sbin/nginx`），但所有配置与日志路径
> 已通过软链接指向 `/dsh/`：
> `/etc/nginx/nginx.conf` → `/dsh/config/nginx/nginx.conf`，
> `/etc/nginx/conf.d` → `/dsh/config/nginx/conf.d`，
> `/var/log/nginx` → `/dsh/log/nginx`。

## 技术栈

| 组件 | 版本 | 安装方式 |
|------|------|----------|
| Debian | 13 (trixie-slim) | 基础镜像 |
| Node.js | 24.21.0 LTS | 预编译二进制绿色安装（按目标架构选择 x64 / arm64 包） |
| Python | 3.13.5（apt）或 3.14.7（source） | **可选**，由 `PYTHON_MODE` 控制，见下节 |
| Nginx | 1.26.3 | apt 安装，配置路径软链到 /dsh/ |
| pnpm | 12.4.1 | npm tarball 手动绿色安装 |
| DSH | 由 versions.yml 配置 | entrypoint.sh 动态安装 |

### Python 安装模式（`PYTHON_MODE`）

Python 是**可选组件**，由构建参数 `PYTHON_MODE` 控制，**默认 `apt`**。

| 模式 | 版本 | 安装方式 | 镜像体积 | 构建耗时 |
|------|------|---------|---------|---------|
| `apt`（默认） | 3.13.5 | apt 装发行版自带 | 约 550 MB | 秒级 |
| `source` | 3.14.7 | 源码编译到 `/dsh/app/python/` | 约 1.08 GB | amd64 约 4.5 分钟，arm64 在 QEMU 下显著更久 |
| `none` | — | 不装 | 约 417 MB | — |

> 体积为 `linux/amd64` 实测值（同条件下对比）。`source` 模式比 `apt` 多出约 530 MB，
> 主要来自源码编译产物（头文件、静态库、`libpython3.14.so` 等）。

**为什么默认用 apt**：Python 属备用工具链 —— DSH 本体与内置插件均为 Node.js 实现，
运行时不依赖 Python（已核查 `script/*.sh`、`config/nginx/`、`versions.yml` 均无 Python 调用）。
apt 安装系统自带版本无需编译、构建时间可忽略、镜像增量小；只有在**必须锁定特定 Python 版本**
时才需要切到 `source` 模式编译。

```bash
# 默认：apt 装发行版自带 Python
docker build -t dsh .

# 源码编译指定版本（PYTHON_VERSION 可覆盖，默认 3.14.7）
docker build --build-arg PYTHON_MODE=source -t dsh .

# 完全不装
docker build --build-arg PYTHON_MODE=none -t dsh .

# 多平台构建同理
docker buildx build --build-arg PYTHON_MODE=source --platform linux/amd64,linux/arm64 -t dsh .
```

CI 中默认值写在 `.github/workflows/docker-build.yml` 的 `env.PYTHON_MODE`（默认 `apt`）；
也可在 Actions 页面手动触发 **Build DSH Docker Image** 工作流，用 `python_mode` 下拉项
选择 `apt` / `source` / `none`，无需改代码。

#### 目录结构对齐

apt **无法**把 Python 装到 `/dsh` —— dpkg 包的安装路径在打包时就已固化，Debian 的
Python 把 `/usr` 编译进了 `sys.prefix`（实测 `sys.prefix=/usr`），共享库位于
`/usr/lib/<triplet>/`，整体重定位会直接破坏解释器。

因此 apt 模式采用折中方案，让 `/dsh` 下的目录约定在两种模式下保持一致：

| 路径 | apt 模式 | source 模式 |
|------|---------|------------|
| `/dsh/app/python/bin/python3` | 软链 → `/usr/bin/python3` | 真实文件（编译产物） |
| `/dsh/app/python/bin/pip3` | 软链 → venv 内 pip | 软链 → venv 内 pip |
| `/dsh/app/python/venv/` | venv（基于系统解释器） | venv（基于 3.14.7） |

> 三种模式下 `PATH` 都保持干净：`profile.env` 与 `entrypoint.sh` 会先判断
> `/dsh/app/python/bin/python3` 是否存在，存在才把 Python 路径追加进 `PATH`。
> 构建结束时会自检模式与实际产物是否一致，不一致会直接构建失败。

### 支持的平台

镜像为**多平台构建**，同一标签下同时提供两种架构，Docker 会自动选择匹配当前主机的版本：

| 平台 | 说明 |
|------|------|
| `linux/amd64` | x86-64 服务器 / 常规云主机 |
| `linux/arm64` | ARM64 服务器、Apple Silicon（M 系列）Mac |

> 构建时 Dockerfile 通过 `TARGETARCH` 自动映射 Node.js 的架构命名
> （`amd64` → `x64`、`arm64` → `arm64`），Python 为源码编译、Nginx 走 apt，
> 二者天然支持上述架构。其它架构（如 `386`、`riscv64`）不受支持，构建会显式报错。

指定平台拉取（一般无需手动指定）：

```bash
docker pull --platform linux/arm64 ghcr.io/higkoo/dsh:latest
```

## 环境变量

所有环境变量集中配置在 `/dsh/profile.env`，显式可见。可在容器内手动执行生效：

```bash
source /dsh/profile.env
```

修改后重启容器即自动加载，也可用 `docker run -e` 覆盖同名变量。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DSH_ROOT` | `/dsh` | 绿色安装根目录 |
| `DSH_HOME` | `/dsh/home` | DSH 数据目录（profile、插件等） |
| `DSH_WEB_HOST` | `127.0.0.1` | DSH Web UI 监听地址（Nginx 反代目标） |
| `DSH_WEB_PORT` | `3080` | DSH Web UI 监听端口 |
| `DSH_HTTP_PORT` | `9080` | 对外 HTTP 端口（仅用于启动提示，实际以 `docker run -p` 为准） |
| `DSH_HTTPS_PORT` | `9443` | 对外 HTTPS 端口（仅用于启动提示，实际以 `docker run -p` 为准） |
| `TZ` | `Asia/Shanghai` | 容器时区（北京时间） |

> `DSH_WEB_HOST` / `DSH_WEB_PORT` 会被 `entrypoint.sh` 的就绪探测直接使用。
> 若修改，请同步调整 `config/nginx/conf.d/dsh-proxy.conf` 中的 `proxy_pass` 目标。

### 时区说明

容器默认使用**北京时间（`Asia/Shanghai`）**，`date` 命令与 Nginx 日志时间戳
（形如 `[14/Sep/2026:14:34:33 +0800]`）均为东八区时间。

如需改用其他时区，两种方式：

```bash
# 方式一：临时覆盖（推荐）
docker run -d ... -e TZ=Asia/Tokyo ghcr.io/higkoo/dsh:v0.3.4

# 方式二：修改 /dsh/profile.env 中的 TZ 后重启容器
```

`entrypoint.sh` 会自动同步 `/etc/localtime` 与 `/etc/timezone`，无需手动处理；
若指定的时区在 `zoneinfo` 中不存在，会告警并沿用镜像默认时区。

## 版本配置 (versions.yml)

支持两种安装方式，可混用。解析器会**自动剥离行尾注释**，因此可以放心写中文注释：

```yaml
# 方式一：组件名 + 版本号
dsh:
  version: latest          # latest 或 "0.1.5-rc.1"，行尾注释会被忽略

plugins:
  - name: dsh-web-lan-access
    version: latest
    profile: web

# 方式二：直接指定下载 URL（优先级高于 version）
dsh:
  url: https://registry.npmjs.com/@deepseek-ai/dsh/-/dsh-0.1.5-rc.1.tgz

plugins:
  - name: dsh-ctl
    url: https://registry.npmjs.com/dsh-ctl/-/dsh-ctl-0.1.1.tgz
    profile: web
```

> 插件安装在 `install-dsh.sh` / `entrypoint.sh` 中均**以 `dsh plugin list` 的实际结果为准**，
> 而非命令退出码；未注册会自动重试最多 3 次。安装日志见 `/dsh/log/plugins/<插件名>.log`。
>
> **npm scope 包名**：插件名需写完整包名（如 `@chengxianglibra/dsh-data-analysis`），
> 不可省略 `@scope/` 前缀。日志文件名会把包名中的 `/` 等字符安全化为 `__`，
> 因此该插件的日志为 `/dsh/log/plugins/__chengxianglibra__dsh-data-analysis.log`。

### 内置插件列表

| 插件 | 包名 | 说明 |
|------|------|------|
| `dsh-web-lan-access` | `dsh-web-lan-access` | 局域网访问支持 |
| `dsh-ctl` | `dsh-ctl` | 进程控制与计划内重启，重启日志写入 `/dsh/log/plugins/dsh-ctl-relaunch.log` |
| 数据分析 | `@chengxianglibra/dsh-data-analysis` | 基于 Marivo 的数据分析插件：自然语言分析指标趋势、连接数据源、生成图表／报告／看板，支持导出 HTML 离线阅读 |

> 数据分析插件为社区插件（非 DeepSeek 官方发行），首次使用会自动准备分析环境并联网下载依赖。
> 要求 DSH `>=0.1.5-rc.1`；镜像内置 Node.js 24 满足其 `^22.19.0 || >=24.0.0` 要求。

## Nginx 配置

| 路径 | 功能 |
|------|------|
| `/health` | Nginx stub_status 状态页面 |
| `/` | 反向代理到 `127.0.0.1:3080`（DSH Web UI） |

代理关键配置：
- `Host: 127.0.0.1:3080` — 让 DSH 认为请求来自本地
- `Origin: ""` — 清空 Origin 头，绕过跨站检查
- WebSocket 支持 — 自动 Upgrade/Connection 头处理

## 使用方法

### 使用预构建镜像（推荐）

无需本地构建，直接从 GitHub Container Registry 拉取：

```bash
docker run -d --name dsh-web --hostname dsh-web --restart unless-stopped \
  -p 9080:80 -p 9443:443 \
  ghcr.io/higkoo/dsh:latest
```

**镜像标签说明**：

| 标签 | 含义 | 适用场景 |
|------|------|----------|
| `latest` | 最新稳定版 | 日常使用 |
| `v0.3.4` | 语义化版本，固定不变 | **生产环境推荐**，避免意外升级 |
| `v0.3` | 次版本浮动标签，随补丁自动更新 | 跟随次版本线 |
| `sha-<短提交>` | 对应具体提交 | 精确回溯 / 问题排查 |

> 版本由 git tag 驱动：推送 `vX.Y.Z` 标签后 CI 自动构建，生成对应的
> 版本号标签、`X.Y` 浮动标签与 `latest`。非 tag 推送（如分支合并）仅更新 `latest` 与 `sha-*`。

**版本线说明**：`v0.1.*` 系列已停止维护并从镜像仓库移除，请使用 `v0.3.4` 及以上版本。

> 容器默认使用**北京时间（`Asia/Shanghai`）**，日志与 `date` 均为东八区时间。
> 详细说明与修改方式见上文「[时区说明](#时区说明)」。

### Docker 构建

```bash
git clone https://github.com/higkoo/dsh-docker.git
cd dsh-docker
docker build -t dsh .
docker run -d --name dsh-web -p 9080:80 -p 9443:443 dsh
```

### Ansible 部署

```bash
cd ansible
ansible-playbook -i inventory.ini playbook.yml
```

Playbook 默认映射 `9080:80` 与 `9443:443`，与上面的 `docker run` 保持一致，
可在 `playbook.yml` 的 `host_http_port` / `host_https_port` 中调整。

### 访问

- DSH Web UI: `http://<服务器IP>:9080/?token=<token>`（token 在容器启动日志中输出）
- HTTPS: `https://<服务器IP>:9443/?token=<token>`（自签证书，浏览器需手动信任）
- 健康检查: `http://<服务器IP>:9080/health`

查看 token（容器启动后，或**用 `dshctl` 重启之后**都可用）：

```bash
docker logs dsh-web 2>&1 | grep -oE 'token=[A-Za-z0-9_-]+' | tail -1
```

也可以直接读日志文件，二者内容一致：

```bash
# 容器内，任选其一（tail -1 取最后一个 = 当前有效的 token）
cat /dsh/log/dsh/dsh-web.log               | grep -oE 'token=[A-Za-z0-9_-]+' | tail -1
cat /dsh/log/plugins/dsh-ctl-relaunch.log  | grep -oE 'token=[A-Za-z0-9_-]+' | tail -1
```

> **关于 `dshctl` 重启后的 token**：`dshctl` 会在进程外重新拉起 DSH，
> 新进程的输出由插件写入自己的接力日志 `dsh-ctl-relaunch.log`。
> 该文件（含重启后的新 token）已统一归位到 `/dsh/log/plugins/` 下，
> 便于集中查看；日志会**追加**而非覆盖，旧 token 记录保留，
> 用 `tail -1` 取最后一个即为当前有效 token。

### 日志查看

容器前台会跟踪 `/dsh/log/*/*.log` 下的**全部日志**，即 `docker logs` 里
能看到 `dsh`、`nginx`、`plugins` 各子目录的所有日志，新日志文件出现后
无需改配置即可被跟踪：

```bash
docker logs -f dsh-web
```

进入容器查看完整日志树：

```bash
docker exec dsh-web sh -c 'ls -R /dsh/log'
```

### 容器自愈

容器内置**服务级**看护：

- DSH 或 Nginx **意外退出**时，容器会一并退出；
  配合 `--restart unless-stopped`（上面的示例已包含）即可实现故障自动恢复。
- 通过 `dshctl` 执行的**计划内重启**（`/dshctl/restart`）不会被误判为崩溃：
  看护以 **HTTP 服务可用性** 为准，并给出 90 秒交接宽限窗口，
  重启完成后自动识别新进程 PID，容器持续运行。

## 开发

### 运行测试

```bash
bash test/test_versions_parser.sh
```

覆盖 `versions.yml` 解析器的边界场景（行尾注释、引号、含 `#` 的 URL、多插件、
`set -e` 中断回归等），CI 中同步执行。

### 发布新版本

```bash
git tag -a v0.3.4 -m "v0.3.4: 变更说明"
git push origin v0.3.4
```

推送后 CI 自动 lint → 构建 → 推送镜像，产出 `v0.3.4`、`v0.3`、`latest` 与 `sha-*` 标签。

## License

MIT
