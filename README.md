# DSH Docker

基于 Docker 一键部署 [DeepSeek Harness (DSH)](https://github.com/deepseek-ai/deepseek-harness) 的镜像方案。

## 背景

[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`) 是 DeepSeek AI 开发的开源 Agent 框架，采用"一切皆插件"架构。通过 `dsh web` 启动 Web UI 后，默认绑定 `127.0.0.1:3080`，**只能本地访问**。

在服务器/远程部署场景下，这一限制导致无法直接对外提供服务。此外，DSH 的安全机制要求 HTTPS 访问，否则部分功能异常。

## 思路

| 问题 | 解决方案 |
|---|---|
| DSH 只绑定 localhost | Nginx 反向代理 `0.0.0.0:443` → `127.0.0.1:3080` |
| 需要 HTTPS | 容器启动时自动生成自签证书，浏览器手动信任即可 |
| HTTP 自动跳转 | 80 端口 `301` 跳转到 HTTPS |
| 一键部署 | Dockerfile + entrypoint.sh 自动完成全部初始化 |

**技术栈：**

- **Debian 13 (trixie-slim)** — 最小化基础系统
- **Node.js 24** (NodeSource) — DSH 运行依赖
- **Python 3.12+** — 后续 Python 插件运行环境
- **Nginx 最新稳定版** (官方仓库) — 反向代理 + HTTPS 终端

**启动流程：**

```
entrypoint.sh
  ├─ 1. 生成自签证书 (首次启动)
  ├─ 2. 后台启动 dsh web --no-open
  ├─ 3. 等待 DSH 就绪 (健康检查 127.0.0.1:3080)
  └─ 4. 前台启动 Nginx (daemon off, 输出 access 日志)
```

## 使用方法

### 直接拉取（推荐）

```bash
docker pull ghcr.io/higkoo/dsh:latest

docker run -d \
  --name dsh \
  -p 80:80 -p 443:443 \
  -v $(pwd):/workspace \
  -v dsh-data:/root/.dsh \
  ghcr.io/higkoo/dsh:latest
```

浏览器访问 `https://<服务器IP>`，提示证书不受信任时手动信任即可。

### 本地构建

```bash
git clone https://github.com/higkoo/dsh-docker.git
cd dsh-docker
docker build -t dsh .
docker run -d -p 80:80 -p 443:443 -v $(pwd):/workspace -v dsh-data:/root/.dsh dsh
```

### 参数说明

| 参数 | 说明 |
|---|---|
| `-p 80:80` | HTTP 端口（自动跳转 HTTPS） |
| `-p 443:443` | HTTPS 端口 |
| `-v $(pwd):/workspace` | 挂载工作目录（DSH 的默认工作区） |
| `-v dsh-data:/root/.dsh` | 持久化 DSH 配置数据 |

### 配置模型

容器启动后，打开 `https://<服务器IP>` → **Settings → Models**，填入 [DeepSeek API Key](https://platform.deepseek.com/) 即可。

## 项目结构

```
├── Dockerfile                 # 镜像构建文件
├── entrypoint.sh              # 容器启动脚本（证书生成 + DSH + Nginx）
├── nginx.conf                 # Nginx 反向代理配置（HTTP跳转 + HTTPS）
└── .github/workflows/
    └── docker-build.yml       # GitHub Actions 自动构建并推送到 ghcr.io
```

## License

MIT
