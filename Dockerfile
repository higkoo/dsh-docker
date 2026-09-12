FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# ============================================================
# 1. 切换 apt 源到阿里云镜像（加速国内构建）
# ============================================================
RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null \
    || sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list 2>/dev/null \
    || true

# ============================================================
# 2. 基础依赖层（构建工具 + 运行时依赖 + Nginx）
# ============================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        git \
        openssl \
        nginx \
        build-essential \
        libssl-dev \
        zlib1g-dev \
        libncurses-dev \
        libffi-dev \
        libsqlite3-dev \
        libreadline-dev \
        libbz2-dev \
        liblzma-dev \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# ============================================================
# 3. 创建 /DSH 绿色安装目录结构
# ============================================================
RUN mkdir -p \
        /DSH/apps/nodejs \
        /DSH/apps/python \
        /DSH/apps/python/venv \
        /DSH/config/nginx/conf.d \
        /DSH/config/nginx/ssl \
        /DSH/config/dsh \
        /DSH/config/ansible \
        /DSH/logs/nginx \
        /DSH/logs/dsh \
        /DSH/logs/plugins \
        /DSH/run \
        /DSH/workspace \
        /DSH/scripts

# ============================================================
# 4. Node.js 24 绿色安装（预编译二进制，解压到 /DSH/apps/nodejs/）
# ============================================================
ARG NODE_VERSION=24.21.0
RUN curl -fsSL "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
        | tar -xJ -C /DSH/apps/nodejs --strip-components=1 \
    && echo "Node.js ${NODE_VERSION} installed to /DSH/apps/nodejs/"

# ============================================================
# 5. Python 3.14 绿色安装（源码编译，安装到 /DSH/apps/python/）
# ============================================================
ARG PYTHON_VERSION=3.14.7
RUN curl -fsSL "https://registry.npmmirror.com/-/binary/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" \
        | tar -xz -C /tmp \
    && cd /tmp/Python-${PYTHON_VERSION} \
    && ./configure \
        --prefix=/DSH/apps/python \
        --with-ensurepip=install \
        --enable-shared \
        LDFLAGS="-Wl,-rpath=/DSH/apps/python/lib" \
    && make -j"$(nproc)" \
    && make install \
    && rm -rf /tmp/Python-${PYTHON_VERSION} \
    && echo "Python ${PYTHON_VERSION} installed to /DSH/apps/python/"

# ============================================================
# 6. 创建 Python 虚拟环境
# ============================================================
RUN /DSH/apps/python/bin/python3 -m venv /DSH/apps/python/venv \
    && echo "Python venv created at /DSH/apps/python/venv/"

# ============================================================
# 7. 核心二进制软链接到 /usr/local/bin（全局可用）
#    先创建软链接，确保后续 npm/pnpm 命令能找到 node
# ============================================================
RUN ln -sf /DSH/apps/nodejs/bin/node     /usr/local/bin/node \
    && ln -sf /DSH/apps/nodejs/bin/npm     /usr/local/bin/npm \
    && ln -sf /DSH/apps/nodejs/bin/npx     /usr/local/bin/npx \
    && ln -sf /DSH/apps/python/bin/python3 /usr/local/bin/python3 \
    && ln -sf /DSH/apps/python/bin/pip3     /usr/local/bin/pip3 \
    && ln -sf /DSH/apps/python/venv/bin/python /usr/local/bin/python \
    && ln -sf /DSH/apps/python/venv/bin/pip   /usr/local/bin/pip \
    && ln -sf /usr/sbin/nginx              /usr/local/bin/nginx \
    && echo "Symlinks created in /usr/local/bin/"

# ============================================================
# 8. 手动安装 pnpm（从 npm 仓库下载 tarball，避免在 chroot 构建环境运行 node）
# ============================================================
RUN mkdir -p /DSH/apps/nodejs/lib/node_modules/pnpm \
    && curl -fsSL -o /tmp/pnpm.tgz "https://registry.npmmirror.com/pnpm/-/pnpm-12.4.1.tgz" \
    && tar -xzf /tmp/pnpm.tgz -C /DSH/apps/nodejs/lib/node_modules/pnpm --strip-components=1 \
    && rm -f /tmp/pnpm.tgz \
    && ln -sf /DSH/apps/nodejs/lib/node_modules/pnpm/bin/pnpm.mjs /DSH/apps/nodejs/bin/pnpm \
    && ln -sf /DSH/apps/nodejs/lib/node_modules/pnpm/bin/pnpm.mjs /usr/local/bin/pnpm \
    && echo "pnpm 12.4.1 installed from tarball"

# 配置 npm 镜像源（写入 .npmrc 文件，不需要运行 node）
RUN echo "registry=https://registry.npmmirror.com" > /root/.npmrc \
    && echo "npm config written to /root/.npmrc"

# ============================================================
# 9. 复制配置文件和脚本
# ============================================================
COPY config/nginx/nginx.conf          /DSH/config/nginx/nginx.conf
COPY config/nginx/conf.d/dsh-proxy.conf /DSH/config/nginx/conf.d/dsh-proxy.conf
COPY config/dsh/versions.yml          /DSH/config/dsh/versions.yml
COPY ansible/playbook.yml             /DSH/config/ansible/playbook.yml
COPY scripts/entrypoint.sh            /DSH/scripts/entrypoint.sh
COPY scripts/install-dsh.sh           /DSH/scripts/install-dsh.sh
RUN chmod +x /DSH/scripts/entrypoint.sh /DSH/scripts/install-dsh.sh

# ============================================================
# 10. Nginx 配置：使用 /DSH 目录下的配置
#     用软链接替换系统默认路径，确保兼容性
# ============================================================
RUN rm -rf /etc/nginx/conf.d \
    && ln -s /DSH/config/nginx/conf.d /etc/nginx/conf.d \
    && rm -rf /var/log/nginx \
    && ln -s /DSH/logs/nginx /var/log/nginx \
    && rm -f /etc/nginx/nginx.conf \
    && ln -s /DSH/config/nginx/nginx.conf /etc/nginx/nginx.conf \
    && echo "Nginx configured to use /DSH/ paths"

# ============================================================
# 11. 环境变量
# ============================================================
ENV DSH_HOME=/DSH
ENV PATH="/DSH/apps/nodejs/bin:/DSH/apps/python/bin:/DSH/apps/python/venv/bin:${PATH}"
ENV HOSTNAME=dsh-agent

EXPOSE 80
WORKDIR /DSH/workspace

ENTRYPOINT ["/DSH/scripts/entrypoint.sh"]
