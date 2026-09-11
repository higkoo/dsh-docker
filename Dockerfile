FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# ============================================================
# 切换 apt 源到阿里云镜像 + 基础依赖（合并为一层，减少层元数据）
# ============================================================
RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null \
    || sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list 2>/dev/null \
    || true \
    && apt-get update && apt-get install -y --no-install-recommends \
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
# Nginx 层（官方仓库，变动频率低）+ 清理 gpg keyring（方案一）
# ============================================================
RUN curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian trixie nginx" \
        > /etc/apt/sources.list.d/nginx.list && \
    apt-get update && apt-get install -y --no-install-recommends nginx && \
    rm -rf /var/lib/apt/lists/* \
    && rm -f /usr/share/keyrings/nginx-archive-keyring.gpg

# ============================================================
# Node.js 层（NodeSource）+ 清理 gpg keyring（方案一）
# ============================================================
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/apt/keyrings/nodesource.gpg

# ============================================================
# pnpm + DSH 层（合并为一层减少元数据；跳过 devDeps；清缓存）
# 方案一：npm cache clean + pnpm store prune
# 方案四：合并层 + --omit=dev
# ============================================================
RUN npm config set registry https://registry.npmmirror.com \
    && npm install -g pnpm \
    && npm install -g @deepseek-ai/dsh \
    && npm cache clean --force \
    && pnpm store prune \
    && rm -rf /root/.npm/_cacache

# ============================================================
# 插件层：dsh-web-lan-access + dsh-ctl（依赖 dsh + pnpm，放最后，变更时只重建这层）
# ============================================================
RUN dsh plugin --profile web add dsh-web-lan-access \
    && dsh plugin --profile web add dsh-ctl

# ============================================================
# 运行时配置（合并 COPY + chmod + mkdir 为一层，减少层元数据）
# ============================================================
COPY nginx.conf /etc/nginx/conf.d/dsh.conf
COPY entrypoint.sh /entrypoint.sh
RUN rm -f /etc/nginx/conf.d/default.conf \
    && chmod +x /entrypoint.sh \
    && mkdir -p /workspace /etc/nginx/ssl

ENV HOSTNAME=dsh-agent

EXPOSE 80 443

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
