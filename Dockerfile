FROM kuingsmile/piclist:latest

# 安装系统依赖
RUN apk add --no-cache jq

# 安装去重脚本所需的所有 Node.js 依赖
RUN npm install -g \
    aws-sdk \
    cos-nodejs-sdk-v5 \
    ali-oss \
    axios

# 复制文件
COPY entrypoint.sh /entrypoint.sh
COPY scripts/beforeUpload/deduplicate.js /deduplicate.js

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]