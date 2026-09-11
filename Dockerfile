FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# ============================================================
# 切换 apt 源到阿里云镜像（加速国内构建）
# ============================================================
RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null \
    || sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list 2>/dev/null \
    || true

# ============================================================
# 基础依赖层（极少变动，缓存命中率高）
# ============================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        git \
        openssl \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# ============================================================
# Nginx 层（官方仓库，变动频率低）
# ============================================================
RUN curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian trixie nginx" \
        > /etc/apt/sources.list.d/nginx.list && \
    apt-get update && apt-get install -y --no-install-recommends nginx && \
    rm -rf /var/lib/apt/lists/*

# ============================================================
# Node.js 层（NodeSource，随 DSH 升级偶尔变动）
# ============================================================
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# ============================================================
# pnpm 层（DSH 插件管理器，独立一层便于缓存）
# 配置 npm 阿里云镜像加速国内构建
# ============================================================
RUN npm config set registry https://registry.npmmirror.com \
    && npm install -g pnpm

# ============================================================
# DSH 层（升级较频繁，独立一层，前面层走缓存）
# ============================================================
RUN npm install -g @deepseek-ai/dsh

# ============================================================
# 插件层：dsh-lan-bridge + dsh-ctl（依赖 dsh + pnpm，放最后，变更时只重建这层）
# ============================================================
RUN dsh plugin --profile web add dsh-lan-bridge \
    && dsh plugin --profile web add dsh-ctl

# ============================================================
# 运行时配置（配置文件复制层，改配置只重建这层及之后）
# ============================================================
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/dsh.conf

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /workspace /etc/nginx/ssl

ENV HOSTNAME=dsh-agent

EXPOSE 80 443

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
