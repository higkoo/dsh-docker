FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# ============================================================
# 第一阶段：安装基础依赖 + Python 3.12+ + OpenSSL
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
# 第二阶段：安装 Node.js 24（DSH 运行依赖，来自 NodeSource）
# ============================================================
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

# ============================================================
# 第三阶段：安装 Nginx 最新稳定版（来自 Nginx 官方仓库）
# ============================================================
RUN curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian trixie nginx" \
        > /etc/apt/sources.list.d/nginx.list && \
    apt-get update && apt-get install -y --no-install-recommends nginx && \
    rm -rf /var/lib/apt/lists/*

# ============================================================
# 第四阶段：安装 DSH
# ============================================================
RUN npm install -g @deepseek-ai/dsh

# ============================================================
# 第五阶段：配置 Nginx 反向代理 + 启动脚本
# ============================================================
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/dsh.conf

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ============================================================
# 运行时配置
# ============================================================
RUN mkdir -p /workspace /etc/nginx/ssl

VOLUME ["/workspace", "/root/.dsh"]

EXPOSE 80 443

WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
