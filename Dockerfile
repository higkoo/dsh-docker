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
# 3. 创建 /dsh 绿色安装目录结构
# ============================================================
RUN mkdir -p \
        /dsh/app/nodejs \
        /dsh/app/python \
        /dsh/app/python/venv \
        /dsh/config/nginx/conf.d \
        /dsh/config/nginx/ssl \
        /dsh/config/dsh \
        /dsh/config/ansible \
        /dsh/log/nginx \
        /dsh/log/dsh \
        /dsh/log/plugins \
        /dsh/run \
        /dsh/workspace \
        /dsh/home \
        /dsh/script

# ============================================================
# 4. Node.js 24 绿色安装（预编译二进制，解压到 /dsh/app/nodejs/）
# ============================================================
ARG NODE_VERSION=24.21.0
RUN curl -fsSL "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
        | tar -xJ -C /dsh/app/nodejs --strip-components=1 \
    && echo "Node.js ${NODE_VERSION} installed to /dsh/app/nodejs/"

# ============================================================
# 5. Python 3.14 绿色安装（源码编译，安装到 /dsh/app/python/）
# ============================================================
ARG PYTHON_VERSION=3.14.7
RUN curl -fsSL "https://registry.npmmirror.com/-/binary/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" \
        | tar -xz -C /tmp \
    && cd /tmp/Python-${PYTHON_VERSION} \
    && ./configure \
        --prefix=/dsh/app/python \
        --with-ensurepip=install \
        --enable-shared \
        LDFLAGS="-Wl,-rpath=/dsh/app/python/lib" \
    && make -j"$(nproc)" \
    && make install \
    && rm -rf /tmp/Python-${PYTHON_VERSION} \
    && echo "Python ${PYTHON_VERSION} installed to /dsh/app/python/"

# ============================================================
# 6. 创建 Python 虚拟环境
# ============================================================
RUN /dsh/app/python/bin/python3 -m venv /dsh/app/python/venv \
    && echo "Python venv created at /dsh/app/python/venv/"

# ============================================================
# 7. 核心二进制软链接到 /usr/local/bin（全局可用）
#    先创建软链接，确保后续 npm/pnpm 命令能找到 node
# ============================================================
RUN ln -sf /dsh/app/nodejs/bin/node     /usr/local/bin/node \
    && ln -sf /dsh/app/nodejs/bin/npm     /usr/local/bin/npm \
    && ln -sf /dsh/app/nodejs/bin/npx     /usr/local/bin/npx \
    && ln -sf /dsh/app/python/bin/python3 /usr/local/bin/python3 \
    && ln -sf /dsh/app/python/bin/pip3     /usr/local/bin/pip3 \
    && ln -sf /dsh/app/python/venv/bin/python /usr/local/bin/python \
    && ln -sf /dsh/app/python/venv/bin/pip   /usr/local/bin/pip \
    && ln -sf /usr/sbin/nginx              /usr/local/bin/nginx \
    && echo "Symlinks created in /usr/local/bin/"

# ============================================================
# 8. 手动安装 pnpm（从 npm 仓库下载 tarball，避免在 chroot 构建环境运行 node）
# ============================================================
RUN mkdir -p /dsh/app/nodejs/lib/node_modules/pnpm \
    && curl -fsSL -o /tmp/pnpm.tgz "https://registry.npmmirror.com/pnpm/-/pnpm-12.4.1.tgz" \
    && tar -xzf /tmp/pnpm.tgz -C /dsh/app/nodejs/lib/node_modules/pnpm --strip-components=1 \
    && rm -f /tmp/pnpm.tgz \
    # npm tarball 解压不保留 bin 的可执行位，这里显式补上（否则 dsh plugin add 会 spawn pnpm EACCES）
    && chmod +x /dsh/app/nodejs/lib/node_modules/pnpm/bin/pnpm.mjs \
    && ln -sf /dsh/app/nodejs/lib/node_modules/pnpm/bin/pnpm.mjs /dsh/app/nodejs/bin/pnpm \
    && ln -sf /dsh/app/nodejs/lib/node_modules/pnpm/bin/pnpm.mjs /usr/local/bin/pnpm \
    && echo "pnpm 12.4.1 installed from tarball"

# 配置 npm 镜像源（写入 .npmrc 文件，不需要运行 node）
RUN echo "registry=https://registry.npmmirror.com" > /root/.npmrc \
    && echo "npm config written to /root/.npmrc"

# ============================================================
# 9. 复制配置文件和脚本
# ============================================================
COPY config/nginx/nginx.conf          /dsh/config/nginx/nginx.conf
COPY config/nginx/conf.d/dsh-proxy.conf /dsh/config/nginx/conf.d/dsh-proxy.conf
COPY config/dsh/versions.yml          /dsh/config/dsh/versions.yml
COPY ansible/playbook.yml             /dsh/config/ansible/playbook.yml
COPY script/entrypoint.sh             /dsh/script/entrypoint.sh
COPY script/install-dsh.sh            /dsh/script/install-dsh.sh
RUN chmod +x /dsh/script/entrypoint.sh /dsh/script/install-dsh.sh

# ============================================================
# 10. Nginx 配置：使用 /dsh 目录下的配置
#     用软链接替换系统默认路径，确保兼容性
# ============================================================
RUN rm -rf /etc/nginx/conf.d \
    && ln -s /dsh/config/nginx/conf.d /etc/nginx/conf.d \
    && rm -rf /var/log/nginx \
    && ln -s /dsh/log/nginx /var/log/nginx \
    && rm -f /etc/nginx/nginx.conf \
    && ln -s /dsh/config/nginx/nginx.conf /etc/nginx/nginx.conf \
    && echo "Nginx configured to use /dsh/ paths"

# ============================================================
# 11. 环境变量
#     DSH_HOME 指向 DSH 的数据目录 /dsh/home
# ============================================================
ENV DSH_HOME=/dsh/home
ENV PATH="/dsh/app/nodejs/bin:/dsh/app/python/bin:/dsh/app/python/venv/bin:${PATH}"
ENV HOSTNAME=dsh-agent

# 端口说明：外部 8233->80(HTTP)，外部 8443->443(HTTPS/SSL)
EXPOSE 80 443
WORKDIR /dsh

ENTRYPOINT ["/dsh/script/entrypoint.sh"]
