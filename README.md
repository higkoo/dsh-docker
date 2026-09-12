# DSH Docker — 绿色部署方案 v0.1.1

基于 Docker 一键部署 [DeepSeek Harness (DSH)](https://github.com/deepseek-ai/deepseek-harness) 的绿色安装镜像方案。

## 核心特性

- **绿色安装**：所有组件（Node.js 24、Python 3.14、Nginx）安装在 `/dsh` 目录下，不污染系统
- **软链接**：核心二进制软链接到 `/usr/local/bin`，全局可用
- **阿里云源**：apt 和 npm 均使用国内镜像加速
- **版本化配置**：通过 `versions.yml` 管理 DSH 及插件版本，支持组件名+版本号和直接 URL 两种安装方式
- **Ansible 编排**：提供 Ansible Playbook 读取版本配置并自动部署
- **健康检查**：Nginx 提供 `/health` 状态页面
- **日志集中**：所有日志统一存放在 `/dsh/log/` 下，分类管理

## /dsh 目录结构

```
/dsh/
├── apps/                        # 应用程序安装目录（绿色安装）
│   ├── nodejs/                  # Node.js 24（预编译二进制）
│   │   ├── bin/                 # node, npm, npx, pnpm
│   │   └── lib/                 # 全局 npm 包
│   ├── python/                  # Python 3.14（源码编译）
│   │   ├── bin/                 # python3, pip3
│   │   ├── lib/                 # Python 标准库 + 共享库
│   │   └── venv/                # Python 虚拟环境
│   └── (nginx 由 apt 安装在系统路径)
│
├── config/                      # 配置文件目录
│   ├── nginx/                   # Nginx 配置
│   │   ├── nginx.conf           # Nginx 主配置
│   │   ├── conf.d/              # 站点配置目录
│   │   │   └── dsh-proxy.conf   # DSH 反向代理 + 健康检查
│   │   └── ssl/                 # SSL 证书目录
│   │       ├── dsh.crt          # 自签证书
│   │       └── dsh.key          # 私钥
│   ├── dsh/                     # DSH 配置
│   │   └── versions.yml         # DSH 及插件版本配置
│   └── ansible/                 # Ansible 部署脚本
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
│       └── dsh-ctl.log
│
├── run/                         # 运行时目录
│   ├── nginx.pid                # Nginx PID
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

## 技术栈

| 组件 | 版本 | 安装方式 |
|------|------|----------|
| Debian | 13 (trixie-slim) | 基础镜像 |
| Node.js | 24.21.0 LTS | 预编译二进制绿色安装 |
| Python | 3.14.7 | 源码编译绿色安装 |
| Nginx | 1.26.3 | apt 安装，配置指向 /dsh/ |
| pnpm | 12.4.1 | npm tarball 手动绿色安装 |
| DSH | 由 versions.yml 配置 | entrypoint.sh 动态安装 |

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DSH_ROOT` | `/dsh` | 绿色安装根目录 |
| `DSH_HOME` | `/dsh/home` | DSH 数据目录（profile、插件等） |

## 版本配置 (versions.yml)

支持两种安装方式，可混用：

```yaml
# 方式一：组件名 + 版本号
dsh:
  version: latest          # latest 或 "0.1.5-rc.1"

plugins:
  - name: dsh-web-lan-access
    version: latest
    profile: web

# 方式二：直接指定下载 URL
dsh:
  url: https://registry.npmjs.com/@deepseek-ai/dsh/-/dsh-0.1.5-rc.1.tgz

plugins:
  - name: dsh-ctl
    url: https://registry.npmjs.com/dsh-ctl/-/dsh-ctl-0.1.1.tgz
    profile: web
```

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

### Docker 构建

```bash
git clone https://github.com/higkoo/dsh-docker.git
cd dsh-docker
docker build -t dsh .
docker run -d -p 80:80 -v $(pwd)/workspace:/dsh/workspace -v dsh-home:/dsh/home dsh
```

### 从 tar 包导入

```bash
docker load -i dsh-image.tar
docker run -d -p 80:80 -v dsh-home:/dsh/home localhost/dsh:latest
```

### Ansible 部署

```bash
cd ansible
ansible-playbook -i inventory.ini playbook.yml
```

### 访问

- DSH Web UI: `http://<服务器IP>/?token=<token>`
- 健康检查: `http://<服务器IP>/health`

## License

MIT
