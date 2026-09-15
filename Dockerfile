FROM debian:trixie-slim

# ============================================================
# 0. OCI 元数据标注
#    这些注解会显示在 ghcr.io 的 package 页面上
#    - source:      关联源仓库，Package 页面会自动展示该仓库的 README
#    - description: 单行描述，显示在包名下方（限 512 字符）
#    - licenses:    SPDX 许可证标识，显示在详情侧栏
#
#    注意：这里的 LABEL 写入的是 image config，仅在本地 docker build / inspect 时可见。
#    GHCR package 页面读取的是 **OCI image index 层的 annotations**，
#    该层由 CI 中 .github/workflows/docker-build.yml 的 build-push-action
#    `outputs: ...,annotation-index.*` 写入（必须用 annotation-index. 前缀）。
#    两处需保持文案一致，CI 与 Dockerfile 共用同一个描述常量。
# ============================================================
LABEL org.opencontainers.image.source="https://github.com/higkoo/dsh-docker"
LABEL org.opencontainers.image.description="DeepSeek Harness (DSH) 的容器化绿色部署方案 —— 拉起即可使用 DSH Web 服务，内置 Nginx 反向代理、自签 HTTPS、进程看护与健康检查。"
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# ============================================================
# 1. 切换 apt 源到阿里云镜像（加速国内构建）
# ============================================================
RUN sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list.d/debian.sources 2>/dev/null \
    || sed -i 's|deb.debian.org|mirrors.aliyun.com|g; s|security.debian.org|mirrors.aliyun.com|g' /etc/apt/sources.list 2>/dev/null \
    || true

# ============================================================
# 2. 基础依赖层（构建工具 + 运行时依赖 + Nginx）
#
#    必须有 xz-utils：第 4 步解压 Node.js 的 .tar.xz 包时
#    tar -xJ 会调用 xz 命令，缺失会报 "xz: Cannot exec"。
#    注意它与下方 Python 源码编译的 *-dev 依赖不同，是**恒需要**的，
#    不能随 PYTHON_MODE 一起被裁掉。
#
#    其余 *-dev 库（build-essential / libssl-dev / zlib1g-dev /
#    libncurses-dev / libffi-dev / libsqlite3-dev / libreadline-dev /
#    libbz2-dev / liblzma-dev）是 **Python 源码编译**
#    （PYTHON_MODE=source）所需，已下放到第 5 步的条件分支中，
#    避免 apt / none 模式白白带上这些体积。
# ============================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        git \
        openssl \
        nginx \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# ============================================================
# 2.1 构建选项：Python 安装模式（PYTHON_MODE）
# ------------------------------------------------------------
# 三态取值：
#   apt    （默认）用 apt 安装 Debian 发行版自带的 Python（约 3.13.5）
#          —— 秒级安装、体积小（stdlib 约 27MB）、与系统库版本天然匹配
#   source 源码编译安装指定版本（PYTHON_VERSION，默认 3.14.7）
#          —— 版本可控，但编译耗时长（arm64 在 QEMU 下尤甚）、体积大
#   none   完全不安装 Python
#
# 为什么默认选 apt：
#   DSH 本体与内置插件均为 Node.js 实现，运行时不依赖 Python
#   （已核查 script/*.sh、config/nginx/、versions.yml 均无 Python 调用），
#   Python 属于"备用工具链"。用 apt 装系统自带版本是代价最低的方案：
#   无需编译、构建时间可忽略、image 增量小；需要精确版本时再切 source。
#
# 关于「apt 能否装到 /dsh 目录」：
#   不能。dpkg 包的安装路径在打包时就已固化，Debian 的 Python 解释器
#   把 /usr 编译进了 sys.prefix（实测 sys.prefix=/usr），共享库位于
#   /usr/lib/<triplet>/，无法整体重定位到 /dsh 而不破坏解释器。
#   因此 apt 模式下的目录对齐采用折中方案：
#     - 解释器本体留在 /usr（apt 管理，不可挪）
#     - venv 建在 /dsh/app/python/venv（与 source 模式一致）
#     - 在 /dsh/app/python/bin/ 下补齐 python3/pip3 软链
#   这样项目约定的 /dsh/app/python/{bin,venv} 在两种模式下都成立，
#   上层脚本与 PATH 判断逻辑无需区分模式。
#
# 用法：
#   docker build .                                          # apt（默认）
#   docker build --build-arg PYTHON_MODE=source .           # 源码编译
#   docker build --build-arg PYTHON_MODE=none .             # 不装
# ============================================================
ARG PYTHON_MODE=apt

# ============================================================
# 3. 创建 /dsh 绿色安装目录结构
#    python 相关目录仅在需要时创建（none 模式不留空目录）
# ============================================================
RUN mkdir -p \
        /dsh/app/nodejs \
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
        /dsh/script \
    && if [ "${PYTHON_MODE}" = "none" ]; then \
           echo "跳过 Python 目录（PYTHON_MODE=none）"; \
       else \
           mkdir -p /dsh/app/python /dsh/app/python/bin /dsh/app/python/venv; \
           echo "Python 目录已创建（PYTHON_MODE=${PYTHON_MODE}）"; \
       fi

# ============================================================
# 4. Node.js 24 绿色安装（预编译二进制，解压到 /dsh/app/nodejs/）
#    多架构支持：按 TARGETARCH 选择对应的预编译包
#      amd64 -> x64
#      arm64 -> arm64
#    Node 官方的架构命名与 OCI 的 TARGETARCH 并不一致（x64 vs amd64），
#    因此必须显式映射，不能直接拼 $TARGETARCH。
# ============================================================
ARG NODE_VERSION=24.21.0
ARG TARGETARCH
RUN case "${TARGETARCH:-amd64}" in \
        amd64) NODE_ARCH=x64   ;; \
        arm64) NODE_ARCH=arm64 ;; \
        *) echo "不支持的架构: ${TARGETARCH}（仅支持 amd64 / arm64）" >&2; exit 1 ;; \
    esac \
    && echo "目标架构: ${TARGETARCH} -> Node 架构: ${NODE_ARCH}" \
    && curl -fsSL "https://npmmirror.com/mirrors/node/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
        | tar -xJ -C /dsh/app/nodejs --strip-components=1 \
    && echo "Node.js ${NODE_VERSION} (${NODE_ARCH}) installed to /dsh/app/nodejs/" \
    && /dsh/app/nodejs/bin/node -e "console.log('node ok:', process.version, process.arch)"

# ============================================================
# 5. Python 安装（三态，见第 2.1 节）
#    apt    -> 装 Debian 自带 Python（约 3.13.5），秒级完成
#    source -> 源码编译 PYTHON_VERSION（默认 3.14.7），耗时且体积大
#    none   -> 跳过
#
#    apt 模式安装的包：
#     python3        解释器（Debian trixie 为 3.13.5）
#     python3-venv   提供 venv 模块（Debian 将其拆分为独立包）
#     python3-pip    提供 pip（用于 venv 内装包）
#     python3-dev    提供头文件，便于后续 pip 编译 C 扩展
# ============================================================
ARG PYTHON_VERSION=3.14.7
RUN set -eux; \
    case "${PYTHON_MODE}" in \
      none) \
        echo "PYTHON_MODE=none，跳过 Python 安装"; \
        ;; \
      apt) \
        echo "PYTHON_MODE=apt，通过 apt 安装发行版自带 Python"; \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            python3 \
            python3-venv \
            python3-pip \
            python3-dev; \
        rm -rf /var/lib/apt/lists/*; \
        python3 -V; \
        ;; \
      source) \
        echo "PYTHON_MODE=source，源码编译 Python ${PYTHON_VERSION}"; \
        apt-get update; \
        apt-get install -y --no-install-recommends \
            build-essential \
            libssl-dev \
            zlib1g-dev \
            libncurses-dev \
            libffi-dev \
            libsqlite3-dev \
            libreadline-dev \
            libbz2-dev \
            liblzma-dev; \
        rm -rf /var/lib/apt/lists/*; \
        curl -fsSL "https://registry.npmmirror.com/-/binary/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" \
            | tar -xz -C /tmp; \
        cd "/tmp/Python-${PYTHON_VERSION}"; \
        ./configure \
            --prefix=/dsh/app/python \
            --with-ensurepip=install \
            --enable-shared \
            LDFLAGS="-Wl,-rpath=/dsh/app/python/lib"; \
        make -j"$(nproc)"; \
        make install; \
        rm -rf "/tmp/Python-${PYTHON_VERSION}"; \
        echo "Python ${PYTHON_VERSION} installed to /dsh/app/python/"; \
        ;; \
      *) \
        echo "错误: 不支持的 PYTHON_MODE='${PYTHON_MODE}'（可选 apt / source / none）" >&2; \
        exit 1; \
        ;; \
    esac

# ============================================================
# 6. 目录结构对齐：建立 venv 并补齐 /dsh/app/python/bin 软链
# ------------------------------------------------------------
# apt 模式下解释器固定在 /usr（不可重定位），为与 source 模式保持
# 一致的目录约定，这里统一在 /dsh/app/python/ 下补齐：
#   venv/        虚拟环境（两种模式都建在这里）
#   bin/python3  指向实际解释器
#   bin/pip3     指向 venv 内的 pip
# 这样上层只需判断 /dsh/app/python/bin/python3 是否存在。
#
# 注意两种模式下「基础解释器」位置不同：
#   apt    -> /usr/bin/python3（apt 装好的）
#   source -> /dsh/app/python/bin/python3（源码编译产物，本就在位）
#
# source 模式下的关键点：configure 时用了 --enable-shared，
#   生成的 libpython3.14.so 位于 /dsh/app/python/lib。
#   虽然编译时传了 LDFLAGS=-Wl,-rpath=...，但该 rpath 只写进
#   libpython 自身，**python3 可执行文件本身**在运行 venv 模块前
#   仍需能找到该共享库（实测直接执行会报 venv/__init__.py 加载失败）。
#   因此这里显式导出 LD_LIBRARY_PATH，保证 venv 创建成功。
#   运行期的库查找则由 /dsh/app/python/bin/python3 的 rpath + 下方
#   profile.env 统一处理。
# ============================================================
RUN set -eux; \
    if [ "${PYTHON_MODE}" = "none" ]; then \
        echo "PYTHON_MODE=none，跳过 venv 与目录对齐"; \
        exit 0; \
    fi; \
    if [ "${PYTHON_MODE}" = "apt" ]; then \
        BASE_PY="$(command -v python3)"; \
    else \
        BASE_PY="/dsh/app/python/bin/python3"; \
        export LD_LIBRARY_PATH="/dsh/app/python/lib"; \
    fi; \
    mkdir -p /dsh/app/python/venv; \
    "${BASE_PY}" -m venv /dsh/app/python/venv; \
    if [ "${PYTHON_MODE}" = "apt" ]; then \
        mkdir -p /dsh/app/python/bin; \
        ln -sf "${BASE_PY}" /dsh/app/python/bin/python3; \
    fi; \
    ln -sf /dsh/app/python/venv/bin/pip /dsh/app/python/bin/pip3; \
    echo "基础解释器: ${BASE_PY}"; \
    echo "venv 版本  : $(LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-} /dsh/app/python/venv/bin/python -V 2>&1)"; \
    echo "python3 -> $(readlink -f /dsh/app/python/bin/python3)"

# ============================================================
# 7. 核心二进制软链接到 /usr/local/bin（全局可用）
#    先创建软链接，确保后续 npm/pnpm 命令能找到 node
#    python/pip 软链接仅在非 none 模式创建
# ============================================================
RUN ln -sf /dsh/app/nodejs/bin/node     /usr/local/bin/node \
    && ln -sf /dsh/app/nodejs/bin/npm     /usr/local/bin/npm \
    && ln -sf /dsh/app/nodejs/bin/npx     /usr/local/bin/npx \
    && ln -sf /usr/sbin/nginx              /usr/local/bin/nginx \
    && if [ "${PYTHON_MODE}" != "none" ]; then \
           ln -sf /dsh/app/python/venv/bin/python /usr/local/bin/python \
        && ln -sf /dsh/app/python/venv/bin/pip    /usr/local/bin/pip \
        && ln -sf /dsh/app/python/venv/bin/python /usr/local/bin/python3 \
        && ln -sf /dsh/app/python/venv/bin/pip    /usr/local/bin/pip3 \
        && echo "python/pip 软链接已创建"; \
       else \
           rm -f /usr/local/bin/python3 /usr/local/bin/pip3 /usr/local/bin/python /usr/local/bin/pip; \
           echo "已跳过 python/pip 软链接（PYTHON_MODE=none）"; \
       fi \
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
COPY profile.env                       /dsh/profile.env
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
#
#     PATH 说明：这里只固化恒存在的 nodejs 路径。python 路径**不在此处**
#     写死 —— 因为 Docker 的 ENV 指令无法条件化，写死会在 PYTHON_MODE=none
#     时残留指向空目录的条目。运行时的 PATH 由 /dsh/profile.env 与
#     entrypoint.sh 组装，二者都会先判断 /dsh/app/python/bin/python3
#     是否存在，存在才追加，因此三种模式下 PATH 都干净准确。
# ============================================================
ENV DSH_HOME=/dsh/home
ENV HOSTNAME=dsh-web
ENV PATH="/dsh/app/nodejs/bin:${PATH}"

# 构建期自检：确认模式与实际产物一致，避免"以为装了其实没装"
RUN echo "==========================================" \
    && echo " PYTHON_MODE = ${PYTHON_MODE}" \
    && if [ "${PYTHON_MODE}" = "none" ]; then \
           test ! -e /dsh/app/python/bin/python3 \
               || { echo "错误: PYTHON_MODE=none 但 python3 仍存在" >&2; exit 1; }; \
           echo " Python   : 未安装（已按配置跳过）"; \
       else \
           test -x /dsh/app/python/bin/python3 \
               || { echo "错误: PYTHON_MODE=${PYTHON_MODE} 但未找到 python3" >&2; exit 1; }; \
           test -x /dsh/app/python/venv/bin/python \
               || { echo "错误: venv 未正确创建" >&2; exit 1; }; \
           echo " Python   : $(/dsh/app/python/venv/bin/python -V 2>&1)"; \
           echo " venv     : $(/dsh/app/python/venv/bin/python -c 'import sys; print(sys.prefix)')"; \
       fi \
    && echo " Node     : $(/dsh/app/nodejs/bin/node -v)" \
    && echo "=========================================="

# ============================================================
# 12. 时区设置（默认北京时间 Asia/Shanghai）
#     - ENV TZ 让 node/python 等运行时直接读取正确时区
#     - /etc/localtime + /etc/timezone 让 date、nginx 等系统命令
#       与日志时间戳一并使用北京时间
#     如需改时区：docker run -e TZ=Asia/Tokyo <image>
# ============================================================
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/${TZ} /etc/localtime \
    && echo "${TZ}" > /etc/timezone \
    && date

# 端口说明：外部 9080->80(HTTP)，外部 9443->443(HTTPS/SSL)
EXPOSE 80 443
WORKDIR /dsh

ENTRYPOINT ["/dsh/script/entrypoint.sh"]
