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
        -addext "subjectAltName=IP:0.0.0.0/0,DNS:*"
    echo "自签证书已生成"
fi

# ============================================================
# 启动 DSH Web UI
# ============================================================
echo "启动 DSH Web UI..."
dsh web --no-open &

echo "等待 DSH 就绪..."
for i in $(seq 1 60); do
    if curl -s http://127.0.0.1:3080 > /dev/null 2>&1; then
        echo "DSH 已就绪 (等待 ${i}s)"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "DSH 启动超时，请检查日志"
        exit 1
    fi
    sleep 1
done

# ============================================================
# 启动 Nginx，终端输出 access 日志
# ============================================================
echo "启动 Nginx 反向代理 (HTTPS)..."
exec nginx -g 'daemon off;'
