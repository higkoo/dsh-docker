# DSH Docker — 绿色部署方案

基于 Docker 一键部署 [DeepSeek Harness (DSH)](https://github.com/deepseek-ai/deepseek-harness) 的绿色安装镜像方案。

所有组件（Node.js 24、Python、Nginx）都装在 `/dsh` 目录下，**不污染系统**；容器一条命令拉起，
启动完会直接把带 token 的访问地址打到你脸上。

---

## 一条命令跑起来

```bash
docker run -d --name dsh-web --hostname dsh-web --restart unless-stopped \
  -p 9080:80 -p 9443:443 \
  ghcr.io/higkoo/dsh:latest
```

等十几秒，看日志：

```bash
docker logs -f dsh-web
```

看到下面这段就说明好了，**HTTP 那一行就是你要访问的地址**（token 必须带，否则 401）：

```
============================================================
  [5/6] DSH 已就绪，请访问:
    HTTP : http://<你的IP>:9080/?token=xxxxxxxx
    HTTPS: https://<你的IP>:9443/?token=xxxxxxxx
  容器内直连: http://127.0.0.1:3080/?token=xxxxxxxx
  LAN 访问: http://172.24.0.24:3080/?token=xxxxxxxx
  健康检查页面: http://<你的IP>:9080/health
============================================================
```

把 `<你的IP>` 换成服务器 IP 即可。HTTPS 是自签证书，浏览器需要手动信任一次。

> **首次启动慢是正常的。** 内置的数据分析插件要现场建 Python 环境并装依赖，实测可能
> 1~3 分钟。日志里每 10 秒会打一次心跳，只要还在打心跳就是在正常初始化，别急着 kill。

<details>
<summary><b>没有 Docker 或者想从源码构建？</b></summary>

```bash
git clone https://github.com/higkoo/dsh-docker.git
cd dsh-docker
docker build -t dsh .          # 默认 apt 模式，约 550 MB
docker run -d --name dsh-web -p 9080:80 -p 9443:443 dsh
```

用 Ansible 批量部署：

```bash
cd ansible
ansible-playbook -i inventory.ini playbook.yml   # 默认映射 9080:80 / 9443:443
```

</details>

---

## 怎么访问

| 入口 | 地址 | 说明 |
|------|------|------|
| Web UI | `http://<IP>:9080/?token=<token>` | 日常使用 |
| Web UI (HTTPS) | `https://<IP>:9443/?token=<token>` | 自签证书，需信任一次 |
| 健康检查 | `http://<IP>:9080/health` | Nginx 状态页，无需 token |

### token 丢了怎么办

token 每次启动都是新生成的，**取最后一条就是当前有效的**：

```bash
# 从容器日志拿
docker logs dsh-web 2>&1 | grep -oE 'token=[A-Za-z0-9_-]+' | tail -1
```

### 用 dshctl 重启之后为什么地址变了

`dshctl`（界面里的计划内重启）会拉起一个**新进程**，token 自然是新的。
不用你翻日志 —— 容器会**自动播报新地址**：

```
  [看护] DSH 已由外部重启，实际 PID: 1234 -> 5678
    [看护] DSH 已重启，token 已更新，新访问地址:
      HTTP : http://<你的IP>:9080/?token=<新 token>
      ...
```

该播报只在 token **确实变化**时触发，不会刷屏。想手动确认就还是那句 `tail -1`。

---

## 常用配置

### 环境变量

集中放在 `/dsh/profile.env`，改完重启容器生效；也可以用 `docker run -e` 临时覆盖。

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `TZ` | `Asia/Shanghai` | 容器时区 |
| `DSH_HOME` | `/dsh/home` | DSH 数据目录（profile、插件数据） |
| `DSH_WEB_PORT` | `3080` | DSH Web UI 监听端口（改完要同步改 Nginx 配置） |
| `DSH_HTTP_PORT` / `DSH_HTTPS_PORT` | `9080` / `9443` | **仅影响启动提示的显示**，真实端口以 `-p` 为准 |
| `DSH_READY_TIMEOUT` / `DSH_READY_HARD_TIMEOUT` / `DSH_DOWN_GRACE` | `120` / `0` / `90` | 就绪等待与故障容忍窗口，一般不用动 |

完整清单见 [`profile.env`](profile.env)。

### 换时区

```bash
docker run -d ... -e TZ=Asia/Tokyo ghcr.io/higkoo/dsh:latest
```

### 版本与插件

DSH 本体和插件装哪个版本，由 `config/dsh/versions.yml` 决定，支持「包名 + 版本号」
和「直接给下载 URL」两种写法，可混用：

```yaml
dsh:
  version: latest                    # 也可以写死 "0.1.5-rc.1"

plugins:
  - name: dsh-web-lan-access
    version: latest
    profile: web
```

镜像内置三个插件：

| 插件 | 作用 |
|------|------|
| `dsh-web-lan-access` | 局域网访问支持 |
| `dsh-ctl` | 进程控制、界面里的计划内重启 |
| `@chengxianglibra/dsh-data-analysis` | 数据分析（社区插件）：自然语言查指标、连数据源、出图表/报告，可导出 HTML |

> 插件是否装好，以 `dsh plugin list` 的实际结果为准（不是命令退出码），失败会自动重试 3 次。
> 单个插件的安装日志在 `/dsh/log/plugins/<插件名>.log`。

### 换 Python 安装方式（构建参数 `PYTHON_MODE`）

| 模式 | 版本 | 镜像体积 | 说明 |
|------|------|---------|------|
| `apt`（默认） | 3.13.5 | 约 550 MB | 装发行版自带，秒级完成 |
| `source` | 3.14.7 | 约 1.08 GB | 源码编译，amd64 约 4.5 分钟 |
| `none` | — | 约 417 MB | **不装 Python，数据分析插件会加载失败** |

```bash
docker build --build-arg PYTHON_MODE=source -t dsh .
```

> **为什么默认要装 Python**：DSH 本体不依赖 Python，但内置的数据分析插件强依赖它
> （要 Python ≥ 3.10 且带 venv/ensurepip）。没有 Python 时插件会加载失败，
> 进而拖垮整棵插件树、DSH 进程直接退出 —— 现象是「起不来、拿不到 token」。
> 原理详见 [docs/DESIGN.md](docs/DESIGN.md#6-python-与内置插件的依赖关系)。

### 支持的平台

同一标签同时提供 `linux/amd64` 与 `linux/arm64`，Docker 会自动挑选匹配的版本，无需手动指定。
其它架构（`386`、`riscv64` 等）不支持。

---

## 出问题怎么办

### 先看这三个地方

```bash
docker logs -f dsh-web                  # 前台实时跟踪【全部】日志，先看这个
docker exec dsh-web ls -R /dsh/log     # 完整日志树
docker exec dsh-web tail -50 /dsh/log/dsh/dsh-web.log
```

`docker logs` 会把 `/dsh/log/*/*.log` 下**所有**日志实时转发到终端，
每行带 `[HH:MM:SS]` 时间戳。运行中新出现的日志文件（比如刚装的插件）
也会自动被纳入，无需重启容器：

```
[18:12:17] ==> /dsh/log/nginx/access.log <==
[18:12:17] 127.0.0.1 - - [16/Sep/2026:18:12:17 +0800] "GET / HTTP/1.1" 401 79
```

日志按来源分目录存放，找问题直接去对应目录：

| 目录 | 内容 |
|------|------|
| `/dsh/log/dsh/` | DSH 本体运行日志、安装日志 |
| `/dsh/log/nginx/` | 访问日志、错误日志 |
| `/dsh/log/plugins/` | 各插件自己的日志（含 `dshctl` 重启的接力日志） |

### 常见现象对照

| 现象 | 大概率原因 | 怎么办 |
|------|-----------|--------|
| 一直「DSH 启动中...」 | 数据分析插件在建 venv、装依赖，正常 | 等 1~3 分钟，心跳还在就别动它 |
| 日志停在「dsh web 启动 #1」不动 | DSH 正在装插件的重依赖，中间不写日志属正常 | 看 `[18:12:17] ==> install.log <==` 段是否在刷 |
| 容器 `exit 1` 退出 | 就绪超时，通常是**容器连不上 npm registry** | 检查网络/代理；日志末尾会打印原因 |
| 日志里一堆 Node 崩溃栈，提到 `plugin tree failed to load` | 某个插件加载失败（如 `none` 模式下缺 Python） | 用默认 `apt` 模式重构建 |
| 访问 401 / 页面空白 | token 不对或没带 | 用 `tail -1` 重新取；`dshctl` 重启后 token 会变 |
| `less` 看中文日志显示 `<E5><8A><A0>` | 是旧镜像（≤ v0.3.7）缺 locale，不是文件坏了 | 升级到 v0.4.0+；临时 `export LC_ALL=C.UTF-8` |
| 服务起来了但界面打不开 | 端口没映射对 | 确认 `docker run -p` 与 `config/nginx/conf.d/dsh-proxy.conf` |

### 容器会自动重启吗

会。容器内置**服务级看护**：DSH 或 Nginx **真挂了**时容器会一并退出，
配合上面 `docker run` 里的 `--restart unless-stopped` 就会自动拉起。

而 `dshctl` 那种**计划内重启不会被误判** —— 看护以 HTTP 可用性为准，并留了 90 秒交接窗口。

> 看不出来「真挂」和「计划内重启」的区别？想搞懂判定逻辑，见
> [docs/DESIGN.md](docs/DESIGN.md#4-进程看护为什么用-http-可用性而不是-pid)。

---

## 镜像标签怎么选

| 标签 | 含义 | 场景 |
|------|------|------|
| `latest` | 最新稳定版 | 日常使用 |
| `v0.4.2` | 固定版本，永不改变 | **生产推荐**，避免意外升级 |
| `v0.4` | 次版本浮动，随补丁更新 | 跟随次版本线 |
| `sha-<短提交>` | 对应具体提交 | 精确回溯 |

推送 `vX.Y.Z` 标签后 CI 自动构建并产出上述标签；普通分支推送只更新 `latest` 与 `sha-*`。
完整变更记录见 [CHANGELOG.md](CHANGELOG.md)。

---

## 目录结构一瞥

```
/dsh/
├── app/          # 绿色安装的 Node.js / Python
├── config/       # nginx、dsh(versions.yml)、ansible 配置
├── log/          # 日志（dsh / nginx / plugins 分类）
├── home/         # DSH 数据目录
├── workspace/    # DSH 工作区
├── script/       # entrypoint.sh、install-dsh.sh
└── profile.env   # 环境变量
```

<details>
<summary><b>展开完整目录树（含每个文件的作用）</b></summary>

```
/dsh/
├── app/                         # 应用程序安装目录（绿色安装）
│   ├── nodejs/                  # Node.js 24（预编译二进制）
│   │   ├── bin/                 # node, npm, npx, pnpm
│   │   └── lib/                 # 全局 npm 包
│   └── python/                  # Python（PYTHON_MODE 控制，默认 apt）
│       ├── bin/                 # python3, pip3      ← none 模式时不存在
│       ├── lib/                 # 仅 source 模式：标准库 + 共享库
│       └── venv/                # Python 虚拟环境
│
├── profile.env                  # 环境变量配置
│
├── config/
│   ├── nginx/
│   │   ├── nginx.conf           # 主配置
│   │   ├── conf.d/dsh-proxy.conf# DSH 反代 + 健康检查
│   │   └── ssl/                 # 自签证书（首次启动生成）
│   ├── dsh/versions.yml         # DSH 及插件版本配置
│   └── ansible/                 # playbook.yml、inventory.ini
│
├── log/
│   ├── nginx/                   # access.log、error.log
│   ├── dsh/                     # dsh-web.log、install.log
│   └── plugins/                 # 各插件日志（包名 '/' 安全化为 '__'）
│
├── run/                         # nginx.pid、dsh.pid
├── workspace/                   # DSH 工作区
├── home/profiles/               # 插件 profile 目录
└── script/
    ├── entrypoint.sh            # 容器启动入口
    └── install-dsh.sh           # DSH 及插件安装脚本
```

> Nginx 二进制由 apt 安装（`/usr/sbin/nginx`），但配置与日志已通过软链接指向 `/dsh/`：
> `/etc/nginx/nginx.conf` → `/dsh/config/nginx/nginx.conf`，
> `/etc/nginx/conf.d` → `/dsh/config/nginx/conf.d`，
> `/var/log/nginx` → `/dsh/log/nginx`。

</details>

---

## 想了解更多

README 只讲「怎么用」。**为什么这么设计、踩过哪些坑**，都在
[docs/DESIGN.md](docs/DESIGN.md)：就绪判定为何用事件而非时长、看护为何看 HTTP 而非 PID、
token 的生命周期、Python 与插件的依赖关系、apt/source 两种模式的目录对齐等。

## 开发

```bash
bash test/test_versions_parser.sh    # versions.yml 解析器边界测试（CI 同步执行）
```

发布新版本：

```bash
git tag -a v0.4.2 -m "v0.4.2: 变更说明"
git push origin v0.4.2               # CI 自动 lint → 构建 → 推送镜像
```

## License

MIT
