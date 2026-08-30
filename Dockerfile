FROM kuingsmile/piclist:latest

# 安装系统依赖 + Node.js 依赖 + 创建目录（合并为单层）
RUN apk add --no-cache jq && \
    npm install -g aws-sdk cos-nodejs-sdk-v5 ali-oss axios && \
    mkdir -p /root/.piclist && chmod 755 /root/.piclist

ENV NODE_PATH=/usr/local/lib/node_modules

# 复制文件
COPY entrypoint.sh /entrypoint.sh
COPY scripts/ /root/.piclist/scripts/

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]