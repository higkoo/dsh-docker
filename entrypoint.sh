#!/bin/bash
set -e

# ============================================================
# 生成自签证书（仅在证书不存在时生成）
# ============================================================
mkdir -p /etc/nginx/ssl
if [ ! -f /etc/nginx/ssl/dsh.crt ]; then
    echo "生成自签证书..."
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout /etc/nginx/ssl/dsh.key \
        -out /etc/nginx/ssl/dsh.crt \
        -days 3650 \
        -subj "/C=CN/ST=Shanghai/L=Shanghai/O=Marivo/OU=DevOps/CN=higkoo" \
        -addext "subjectAltName=IP:0.0.0.0,DNS:*"
    echo "自签证书已生成"
fi

# ============================================================
# 确保 dsh-lan-bridge、dsh-ctl 插件就位
# （镜像构建时已预装；去 VOLUME 后构建层直接保留，这里仅作兜底）
# ============================================================
if [ ! -d /root/.dsh/profiles/web ]; then
    echo "补装插件（profile 缺失）..."
    dsh plugin --profile web add dsh-lan-bridge \
        || echo "dsh-lan-bridge 安装失败，继续启动..."
    dsh plugin --profile web add dsh-ctl \
        || echo "dsh-ctl 安装失败，继续启动..."
else
    echo "dsh 插件已就位（dsh-lan-bridge、dsh-ctl）"
fi

# ============================================================
# 启动 DSH Web UI（后台，日志重定向到文件以便抓取 token）
# ============================================================
echo "启动 DSH Web UI..."
: > /tmp/dsh.log
dsh web --no-open > /tmp/dsh.log 2>&1 &

echo "等待 DSH 就绪..."
for i in $(seq 1 60); do
    if curl -s http://127.0.0.1:3080 > /dev/null 2>&1; then
        echo "DSH 已就绪 (等待 ${i}s)"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "DSH 启动超时，请检查日志"
        cat /tmp/dsh.log
        exit 1
    fi
    sleep 1
done

# ============================================================
# 后台启动 Nginx 反向代理
# ============================================================
echo "启动 Nginx 反向代理 (HTTPS, 后台)..."
nginx
sleep 1
echo "Nginx 已启动"

# ============================================================
# 执行 /dshctl restart now（确保插件生效后重启一次）
# ============================================================
echo "执行 /dshctl restart now ..."
/dshctl restart now || echo "/dshctl 执行失败或不存在，继续..."

# restart 后等待 DSH 重新就绪并重新抓取 token
echo "等待 DSH 重新就绪..."
: > /tmp/dsh.log
for i in $(seq 1 60); do
    if curl -s http://127.0.0.1:3080 > /dev/null 2>&1; then
        echo "DSH 已重新就绪 (等待 ${i}s)"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "DSH 重新就绪超时，请检查日志"
        cat /tmp/dsh.log
        exit 1
    fi
    sleep 1
done

# ============================================================
# 轮询提取 DSH 访问 token（restart 后 token 可能变化）
# ============================================================
TOKEN=""
for i in $(seq 1 15); do
    TOKEN=$(grep -oE 'token=[A-Za-z0-9_-]+' /tmp/dsh.log | head -1 | cut -d= -f2)
    [ -n "$TOKEN" ] && break
    sleep 1
done
if [ -n "$TOKEN" ]; then
    echo "------------------------------------------------------------"
    echo "请访问: https://<Your-IP-Address>/?token=${TOKEN}"
    echo "------------------------------------------------------------"
else
    echo "未抓到 token，请查看 /tmp/dsh.log"
fi

# ============================================================
# 前台跟踪 Nginx access.log + error.log
# ============================================================
echo "开始跟踪日志..."
tail -f /var/log/nginx/access.log /var/log/nginx/error.log
