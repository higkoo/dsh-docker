# DSH Docker — 绿色部署方案

基于 Docker 一键部署 [DeepSeek Harness (DSH)](https://github.com/deepseek-ai/deepseek-harness) 的绿色安装镜像方案。

所有组件（Node.js 24、Python、Nginx）都装在 `/dsh` 目录下，**不污染系统**；容器一条命令拉起，
启动完会直接把带 token 的访问地址打到你脸上。

---

## 一条命令跑起来

最省事的写法 —— 拉镜像、起容器、跟日志，一行搞定：

```bash
docker pull ghcr.io/higkoo/dsh:latest && docker run -d -p 9080:80 -p 9443:443 --name dsh-web ghcr.io/higkoo/dsh:latest && docker logs -f dsh-web
```

想看完整参数（主机名、自动重启策略等），用这个：

```bash
docker run -d --name dsh-web --hostname dsh-web --restart unless-stopped \
  -p 9080:80 -p 9443:443 \
  ghcr.io/higkoo/dsh:latest
```

> 上面用的都是**本项目 CI 构建并发布到 GHCR 的官方镜像**，直接可用，无需自己构建。

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

> **首次启动慢是正常的。** 内置的数据分析插件要现场建 Python 环境并装依赖，
> 实测可能要 **5~10 分钟**（网络慢时更久）。日志里每 10 秒会打一次心跳，
> 只要还在打心跳就是在正常初始化，别急着 kill。

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
| `DSH_ENABLE_DATA_ANALYSIS` | 未设置 | 数据分析插件开关，`true` 则安装；不设置时以 `versions.yml` 的 `enabled` 为准（默认关） |
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

| 插件 | 作用 | 默认 |
|------|------|------|
| `dsh-web-lan-access` | 局域网访问支持 | 安装 |
| `dsh-ctl` | 进程控制、界面里的计划内重启 | 安装 |
| `@chengxianglibra/dsh-data-analysis` | 数据分析（社区插件）：自然语言查指标、连数据源、出图表/报告，可导出 HTML | **不安装** |

> 插件是否装好，以 `dsh plugin list` 的实际结果为准（不是命令退出码），失败会自动重试 3 次。
> 单个插件的安装日志在 `/dsh/log/plugins/<插件名>.log`。

#### 插件开关 `enabled`

每个插件都支持 `enabled` 字段，控制装不装。**不写即为启用**，所以老配置不用改：

```yaml
plugins:
  - name: some-plugin
    version: latest
    profile: web
    enabled: false        # false 则不安装；配置本身完整保留
```

`enabled: false` 时插件配置原样留在文件里，日志会明确提示「已跳过」，
想启用改回 `true` 重启容器即可，不用重新补配置。

**数据分析插件默认 `enabled: false`** —— 它依赖本地 Python 且要 pip 拉 `marivo`，
体量大、首次装包慢。不需要自然语言分析 / 图表 / 看板时保持关闭，
容器首次启动能快不少（实测约 25s vs 60s+）。

需要时两种开法（优先级：环境变量 > `versions.yml`）：

```bash
# 方法一：不改配置，运行时开启
docker run -d --name dsh-web \
  -e DSH_ENABLE_DATA_ANALYSIS=true \
  -p 9080:80 -p 9443:443 \
  ghcr.io/higkoo/dsh:latest

# 方法二：改 config/dsh/versions.yml 里该插件的 enabled 为 true，重启容器
```

> `DSH_ENABLE_DATA_ANALYSIS` 是数据分析插件专用的覆盖开关，
> 环境变量优先于 `versions.yml`，且只影响这一个插件。
> 关闭状态下启动日志会打印提示，不用担心「功能怎么没了」。

### 换 Python 安装方式（构建参数 `PYTHON_MODE`）

| 模式 | 版本 | 镜像体积 | 说明 |
|------|------|---------|------|
| `apt`（默认） | 3.13.5 | 约 550 MB | 装发行版自带，秒级完成 |
| `source` | 3.14.7 | 约 1.08 GB | 源码编译，amd64 约 4.5 分钟 |
| `none` | — | 约 417 MB | **不装 Python，数据分析插件会加载失败** |

```bash
docker build --build-arg PYTHON_MODE=source -t dsh .
```

> **为什么默认要装 Python**：DSH 本体不依赖 Python，但数据分析插件强依赖它
> （要 Python ≥ 3.10 且带 venv/ensurepip）。该插件**默认不安装**（见上节），
> 但一旦你启用它，没有 Python 就会加载失败，进而拖垮整棵插件树、DSH 进程直接退出
> —— 现象是「起不来、拿不到 token」。所以镜像默认仍把 Python 装上，
> 保证「随时启用数据分析插件」这条路是通的。
> 原理详见 [docs/DESIGN.md](docs/DESIGN.md#6-python-与内置插件的依赖关系)。

> 若确定永远不用数据分析插件、又想把镜像压到最小，可用 `PYTHON_MODE=none` 构建，
> 此时请保持 `versions.yml` 中该插件 `enabled: false`。

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
[18:12:17] 10.88.7.123 - - [16/Sep/2026:18:12:17 +0800] "GET / HTTP/1.1" 401 79 "-" "Mozilla/5.0 ..." hop=172.17.0.1 xff="10.88.7.123, 10.0.2.100"
```

| 字段 | 含义 |
|------|------|
| 第 1 列 | 客户端 IP（有 XFF 时是**真实客户端**，否则是最后一跳） |
| `hop=` | 直连 Nginx 的那一跳（网关 / 容器自身 / 某台代理） |
| `xff=` | 完整 `X-Forwarded-For` 链，多层代理时能看出经过哪些跳 |

### 访问日志里的客户端 IP

日志第 1 列是 `$remote_addr`。容器内 Nginx 已启用 `realip` 模块，
**当上游在 `X-Forwarded-For` 里写了真实 IP 时**，这一列会被改写为真实客户端 IP。

但要注意：**realip 只能「解析」已存在的 XFF，自己不会推断来源**。
能不能看到真实 IP，取决于你的部署形态：

| 部署形态 | 第 1 列 | 说明 |
|---------|---------|------|
| **前面有 HTTP 代理 / 网关 / LB** | ✅ 真实 IP | 上游写了 XFF，realip 正常解析。这是本功能的目标场景 |
| **Docker `-p` 端口映射** | ⚠️ 网关 IP | 端口映射是 L4 转发，**不加任何 HTTP 头**，XFF 为空 |
| **Podman rootless（`slirp4netns`）** | ⚠️ `10.0.2.100` | 用户态网络栈，**真实来源在进入容器前就丢了**，无解 |
| **`--network host`** | ✅ 真实 IP | 容器直接用宿主机网络栈，`$remote_addr` 就是真实地址 |
| **Podman `--network pasta`** | ✅ 真实 IP | slirp4netns 的继任者，保留源 IP（Podman ≥ 4.4） |

**怎么判断自己属于哪种**：看日志的 `xff=` 字段。

```
10.0.2.100 - - [...] "GET / HTTP/1.1" 200 22467 "..." "..." hop=10.0.2.100 xff="-"
                                                    ↑                ↑
                                            与第1列相同        xff 为空
```

`xff="-"` 表示**没有任何东西写 X-Forwarded-For**，此时 realip 无事可做，
第 1 列与 `hop=` 必然相同 —— 这不是配置错误，是链路上没人提供这个信息。

**想拿到真实 IP，按场景选择**：

```bash
# ① 有公司统一网关/LB 转发过来的：在那一层加一行即可
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

# ② Podman rootless：改用 pasta（Podman ≥ 4.4，最干净）
podman run -d --name dsh-web --network pasta -p 9080:80 -p 9443:443 ghcr.io/higkoo/dsh:v0.4.4

# ③ 或者用 host 网络（注意 host 模式下 -p 无效，用环境变量改监听端口）
docker run -d --name dsh-web --network host \
  -e DSH_HTTP_PORT=9080 -e DSH_HTTPS_PORT=9443 \
  ghcr.io/higkoo/dsh:v0.4.4
```

> host / pasta 模式下 `$remote_addr` **直接就是真实 IP**，不依赖 XFF，
> 所以日志里 `xff="-"` 是正常的。
>
> 用 host 或 pasta 时，若仍想保留网关 IP 用于排查，可把
> `set_real_ip_from` 收敛为实际代理网段（公网部署建议这么做，防 XFF 伪造）。

日志按来源分目录存放，找问题直接去对应目录：

| 目录 | 内容 |
|------|------|
| `/dsh/log/dsh/` | DSH 本体运行日志、安装日志 |
| `/dsh/log/nginx/` | 访问日志、错误日志 |
| `/dsh/log/plugins/` | 各插件自己的日志（含 `dshctl` 重启的接力日志） |

### 常见现象对照

| 现象 | 大概率原因 | 怎么办 |
|------|-----------|--------|
| 一直「DSH 启动中...」 | 数据分析插件在建 venv、装依赖，正常 | 等 5~10 分钟，心跳还在就别动它 |
| 日志停在「dsh web 启动 #1」不动 | DSH 正在装插件的重依赖，中间不写日志属正常 | 看 `[18:12:17] ==> install.log <==` 段是否在刷 |
| 容器 `exit 1`，日志提到 **pnpm failed / `registry.npmjs.org`** | pnpm 自举下二进制时**不读 npmrc**，硬走 `registry.npmjs.org` | 加 `-e COREPACK_NPM_REGISTRY=https://registry.npmmirror.com/`（见下） |
| 容器 `exit 1`，日志提到 **`pypi.org` / marivo 装不上** | 数据分析插件用 pip 装 Python 包，直连 PyPI | 加 `-e PIP_INDEX_URL=...`（见下） |
| 日志里一堆 Node 崩溃栈，提到 `plugin tree failed to load` | 某个插件加载失败（如 `none` 模式下缺 Python） | 用默认 `apt` 模式重构建 |
| 访问 401 / 页面空白 | token 不对或没带 | 用 `tail -1` 重新取；`dshctl` 重启后 token 会变 |
| `less` 看中文日志显示 `<E5><8A><A0>` | 是旧镜像（≤ v0.3.7）缺 locale，不是文件坏了 | 升级到 v0.4.0+；临时 `export LC_ALL=C.UTF-8` |
| 服务起来了但界面打不开 | 端口没映射对 | 确认 `docker run -p` 与 `config/nginx/conf.d/dsh-proxy.conf` |
| 访问日志第 1 列是网关/容器 IP，`xff="-"` | 链路上没人写 `X-Forwarded-For`（裸端口映射、Podman slirp4netns） | 见 [访问日志里的客户端 IP](#访问日志里的客户端-ip) |

#### 连不上公网时的两个 registry

镜像里已把 **npm** 指向 `registry.npmmirror.com`，但有两处**不吃这个配置**，
在无法直连公网的机器上会导致容器 `exit 1`：

```bash
docker run -d --name dsh-web \
  -e COREPACK_NPM_REGISTRY=https://registry.npmmirror.com/ \
  -e PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple \
  -e PIP_TRUSTED_HOST=pypi.tuna.tsinghua.edu.cn \
  -p 9080:80 -p 9443:443 \
  ghcr.io/higkoo/dsh:latest
```

- `COREPACK_NPM_REGISTRY` —— pnpm 是 Corepack 包装器，自举下载自身二进制时
  **只认这个变量**，`npmrc` / `npm_config_registry` 都不起作用；
- `PIP_INDEX_URL` —— 数据分析插件用 pip 装 `marivo`，容器内没有 pip 配置。

> 能直连公网的话不需要加，原样跑即可。

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
| `v0.4.4` | 固定版本，永不改变 | **生产推荐**，避免意外升级 |
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
git tag -a v0.4.4 -m "v0.4.4: 变更说明"
git push origin v0.4.4               # CI 自动 lint → 构建 → 推送镜像
```

## License

MIT
