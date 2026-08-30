#!/bin/sh
set -e

# ============================================
# 环境变量说明
# ============================================
# 必需变量：
#   PICLIST_KEY          : API 鉴权密钥（必需）
#
# 配置生成相关：
#   PICBED_MODE          : single（默认）或 multi
#   PICBED_TYPE          : tencent/aliyun/huawei/upyun/qiniu/webdav/s3/smms
#   PICBED_DEFAULT       : 多图床默认配置名
#
# buildin 功能：
#   PICBED_COMPRESS         : true/false，默认 true
#   PICBED_COMPRESS_QUALITY : 0-100，默认 80
#   PICBED_RENAME           : true/false，默认 true
#   PICBED_RENAME_RULE      : 默认 {md5}
#   PICBED_EXIF_REMOVE      : true/false，默认 false
#
# 腾讯云 COS 专用：
#   TC_SECRET_ID    : 腾讯云 SecretId
#   TC_SECRET_KEY   : 腾讯云 SecretKey
#   TC_BUCKET       : 存储桶名称（必须含 APPID，如 my-images-1234567890）
#   TC_REGION       : 地域（如 ap-guangzhou）
#   TC_PATH         : 存储路径前缀（可选）
#   TC_CUSTOM_URL   : 自定义域名（可选）
#
# 多图床模式：
#   PICBED_0_NAME, PICBED_0_TYPE, PICBED_0_* (参数), PICBED_0_BACKUP_OF
# ============================================

# ============================================
# 1. 日志函数
# ============================================
log() {
    echo "[$1] $2"
}

log_error() {
    echo "[ERROR] $1" >&2
}

# ============================================
# 2. 初始化与基础检查
# ============================================

# 检查必需变量
if [ -z "$PICLIST_KEY" ]; then
    log_error "PICLIST_KEY 未设置"
    exit 1
fi

# 检查 jq 是否安装
if ! command -v jq >/dev/null 2>&1; then
    log_error "jq 未安装，请在 Dockerfile 中添加: RUN apk add --no-cache jq"
    exit 1
fi

# 打印调试信息
log INFO "=== 环境变量调试 ==="
log INFO "PICLIST_KEY: ${PICLIST_KEY:0:10}..."
log INFO "PICBED_MODE: ${PICBED_MODE:-single}"
log INFO "PICBED_TYPE: ${PICBED_TYPE:-未设置}"
log INFO "TC_SECRET_ID: ${TC_SECRET_ID:0:10}..."
log INFO "TC_SECRET_KEY: ${TC_SECRET_KEY:0:10}..."
log INFO "TC_BUCKET: ${TC_BUCKET:-未设置}"
log INFO "TC_REGION: ${TC_REGION:-未设置}"
log INFO "jq 版本: $(jq --version 2>/dev/null || echo '未知')"
log INFO "======================"

# 检查 TC_BUCKET 格式（必须包含 APPID）
if [ -n "$TC_BUCKET" ]; then
    if ! echo "$TC_BUCKET" | grep -q -- '-[0-9][0-9]*$'; then
        log_error "TC_BUCKET 格式错误，必须包含 APPID，如 my-images-1234567890"
        exit 1
    fi
    log INFO "TC_BUCKET 格式检查通过"
fi


# ============================================
# 3. 默认值
# ============================================
PICBED_MODE="${PICBED_MODE:-single}"
PICBED_COMPRESS="${PICBED_COMPRESS:-true}"
PICBED_COMPRESS_QUALITY="${PICBED_COMPRESS_QUALITY:-80}"
PICBED_RENAME="${PICBED_RENAME:-true}"
PICBED_RENAME_RULE="${PICBED_RENAME_RULE:-"{md5}"}"
PICBED_EXIF_REMOVE="${PICBED_EXIF_REMOVE:-false}"

# ============================================
# 4. 公共函数
# ============================================

# 构建 buildin JSON
buildin() {
    jq -n \
        --argjson compress "$PICBED_COMPRESS" \
        --argjson quality "$PICBED_COMPRESS_QUALITY" \
        --argjson rename "$PICBED_RENAME" \
        --arg rule "$PICBED_RENAME_RULE" \
        --argjson exif "$PICBED_EXIF_REMOVE" \
        '{compress:$compress,compressQuality:$quality,rename:$rename,renameRule:$rule,exifRemove:$exif}' \
        2>/dev/null || {
        log_error "buildin 生成失败，请检查环境变量"
        exit 1
    }
}

# 图床类型配置模板
# 格式: uploader_name|字段映射|必需变量
get_template() {
    case "$1" in
        tencent)
            # 修改 region 为 area，以符合 PicList 配置规范
            echo "tcyun|secretId:TC_SECRET_ID,secretKey:TC_SECRET_KEY,bucket:TC_BUCKET,area:TC_REGION,path:TC_PATH,customUrl:TC_CUSTOM_URL|TC_SECRET_ID TC_SECRET_KEY TC_BUCKET TC_REGION"
            ;;
        aliyun)
            echo "aliyun|accessKeyId:ALI_ACCESS_KEY_ID,accessKeySecret:ALI_ACCESS_KEY_SECRET,bucket:ALI_BUCKET,region:ALI_REGION,path:ALI_PATH|ALI_ACCESS_KEY_ID ALI_ACCESS_KEY_SECRET ALI_BUCKET ALI_REGION"
            ;;
        s3)
            echo "s3|accessKeyId:S3_ACCESS_KEY_ID,secretAccessKey:S3_SECRET_ACCESS_KEY,bucket:S3_BUCKET,region:S3_REGION,endpoint:S3_ENDPOINT,path:S3_PATH|S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY S3_BUCKET S3_ENDPOINT"
            ;;
        webdav)
            echo "webdavplist|endpoint:WEBDAV_ENDPOINT,username:WEBDAV_USERNAME,password:WEBDAV_PASSWORD,path:WEBDAV_PATH|WEBDAV_ENDPOINT WEBDAV_USERNAME WEBDAV_PASSWORD"
            ;;
        smms)
            echo "smms||"
            ;;
        *)
            return 1
            ;;
    esac
}

# 从环境变量构建参数对象
build_params() {
    local fields="$1"
    local prefix="$2"
    local params="{}"
    
    IFS=,
    for item in $fields; do
        [ -z "$item" ] && continue
        key="${item%%:*}"
        env_name="${item#*:}"
        val=$(eval echo "\${${prefix}${env_name}:-}")
        if [ -n "$val" ]; then
            params=$(echo "$params" | jq --arg key "$key" --arg val "$val" '. + {($key): $val}') 2>/dev/null || {
                log_error "build_params 失败: key=$key, val=$val"
                exit 1
            }
        fi
    done
    
    echo "$params"
}

# 腾讯云特殊处理：appId 和 version
apply_tencent_special() {
    local params="$1"
    local prefix="$2"
    
    bucket_val=$(eval echo "\${${prefix}BUCKET:-}")
    if [ -n "$bucket_val" ]; then
        appid="${bucket_val##*-}"
        params=$(echo "$params" | jq --arg val "$appid" '. + {appId: $val}') 2>/dev/null || {
            log_error "apply_tencent_special 失败: appId 添加失败"
            exit 1
        }
    fi
    params=$(echo "$params" | jq --arg val "v5" '. + {version: $val}') 2>/dev/null || {
        log_error "apply_tencent_special 失败: version 添加失败"
        exit 1
    }
    
    echo "$params"
}

# ============================================
# 5. 单图床配置
# ============================================
single_config() {
    local type="$1"
    local template=$(get_template "$type")
    if [ -z "$template" ]; then
        log_error "不支持的图床类型: $type"
        exit 1
    fi
    
    local uploader="${template%%|*}"
    local rest="${template#*|}"
    local fields="${rest%%|*}"
    local required="${rest#*|}"
    
    # 检查必需变量
    for var in $required; do
        eval "value=\$$var"
        if [ -z "$value" ]; then
            log_error "缺少必需变量: $var"
            exit 1
        fi
    done
    
    # SM.MS 空配置
    if [ -z "$fields" ]; then
        echo "{\"picBed\":{\"current\":\"${uploader}\",\"uploader\":\"${uploader}\",\"${uploader}\":{}}}"
        return
    fi
    
    # 构建参数
    local params=$(build_params "$fields" "")
    
    # 腾讯云特殊处理
    if [ "$type" = "tencent" ]; then
        params=$(apply_tencent_special "$params" "")
    fi
    
    echo "{\"picBed\":{\"current\":\"${uploader}\",\"uploader\":\"${uploader}\",\"${uploader}\":${params}}}"
}
# ============================================
# 6. 多图床配置
# ============================================
multi_config() {
    log INFO "生成多图床配置"
    
    local indexes=$(env | grep '^PICBED_[0-9]\+_NAME=' | sed 's/^PICBED_\([0-9]\+\)_NAME=.*$/\1/' | sort -n)
    if [ -z "$indexes" ]; then
        log_error "未找到 PICBED_*_NAME 环境变量"
        exit 1
    fi
    
    local tmp=$(mktemp -d)
    trap "rm -rf $tmp" EXIT INT TERM
    
    local types=""
    local first=""
    local backup_enable=false
    local backup_type=""
    local backup_name=""
    local backup_target=""
    
    for idx in $indexes; do
        local prefix="PICBED_${idx}_"
        local name=$(eval echo "\${${prefix}NAME}")
        local type=$(eval echo "\${${prefix}TYPE}")
        
        if [ -z "$name" ] || [ -z "$type" ]; then
            log WARN "跳过索引 $idx: NAME 或 TYPE 缺失"
            continue
        fi
        
        log INFO "发现图床配置: $name (类型: $type)"
        
        local template=$(get_template "$type")
        if [ -z "$template" ]; then
            log WARN "跳过 $name: 不支持的类型 $type"
            continue
        fi
        
        local uploader="${template%%|*}"
        local rest="${template#*|}"
        local fields="${rest%%|*}"
        local required="${rest#*|}"
        
        # 检查必需变量
        local missing=false
        for var in $required; do
            eval "value=\${${prefix}${var}}"
            if [ -z "$value" ]; then
                log WARN "跳过 $name: 缺少 ${prefix}${var}"
                missing=true
                break
            fi
        done
        if [ "$missing" = "true" ]; then
            continue
        fi
        
        # 构建参数
        local params=$(build_params "$fields" "$prefix")
        
        # 腾讯云特殊处理
        if [ "$type" = "tencent" ]; then
            params=$(apply_tencent_special "$params" "$prefix")
        fi
        
        # 添加配置名
        params=$(echo "$params" | jq --arg name "$name" '. + {_configName: $name}') 2>/dev/null || {
            log_error "添加 _configName 失败: $name"
            exit 1
        }
        
        # 添加到列表
        local f="${tmp}/${uploader}.list"
        if [ -f "$f" ]; then
            echo ", $params" >> "$f"
        else
            echo "$params" > "$f"
            types="${types}${uploader} "
        fi
        
        # 记录第一个配置
        if [ -z "$first" ]; then
            first="$name"
        fi
        
        # 备份配置（只取第一个）
        local backup_of=$(eval echo "\${${prefix}BACKUP_OF}")
        if [ -n "$backup_of" ] && [ "$backup_enable" = "false" ]; then
            backup_enable=true
            backup_type="$uploader"
            backup_name="$name"
            backup_target="$backup_of"
            log INFO "备份配置: $name -> $backup_of"
        fi
    done
    
    if [ -z "$types" ]; then
        log_error "无有效图床配置"
        exit 1
    fi
    
    # 生成 uploader 部分
    local uploader_json=""
    local first_type=true
    for ut in $types; do
        local f="${tmp}/${ut}.list"
        if [ ! -f "$f" ]; then
            continue
        fi
        local content=$(cat "$f" | tr -d '\n')
        if [ "$first_type" = "true" ]; then
            first_type=false
            uploader_json="\"${ut}\": {\"configList\": [${content}]}"
        else
            uploader_json="${uploader_json}, \"${ut}\": {\"configList\": [${content}]}"
        fi
    done
    
    echo "{\"picBed\":{\"current\":\"${PICBED_DEFAULT:-$first}\"},\"uploader\":{${uploader_json}}}"
    
    if [ "$backup_enable" = "true" ]; then
        echo ",\"secondConfig\":{\"enable\":true,\"mode\":\"backup\",\"uploader\":\"${backup_type}\",\"configName\":\"${backup_name}\",\"target\":\"${backup_target}\"}"
    fi
    echo ""
}

# ============================================
# 7. 主流程
# ============================================

log INFO "开始生成配置..."

# 生成配置 JSON
if [ "$PICBED_MODE" = "multi" ]; then
    config=$(multi_config)
elif [ -n "$PICBED_TYPE" ]; then
    config=$(single_config "$PICBED_TYPE")
else
    log INFO "未指定 PICBED_TYPE，使用默认配置 (SM.MS)"
    config='{"picBed":{"current":"smms","uploader":"smms","smms":{}}}'
fi

# 验证配置是否为空
if [ -z "$config" ]; then
    log_error "配置生成失败，config 为空"
    exit 1
fi

# 验证 config 是否为有效 JSON
if ! echo "$config" | jq empty 2>/dev/null; then
    log_error "config 格式无效: $config"
    exit 1
fi

log INFO "配置生成完成，合并 buildin..."

# 合并 buildin
final=$(echo "$config" | jq --argjson b "$(buildin)" '. + {buildin: $b}') 2>/dev/null || {
    log_error "jq 合并失败，请检查 config 和 buildin 格式"
    exit 1
}

# 验证 final 是否为有效 JSON
if ! echo "$final" | jq empty 2>/dev/null; then
    log_error "最终 config.json 格式无效"
    exit 1
fi

# 写入配置文件
echo "$final" > /root/.piclist/config.json
log INFO "config.json 已写入"

# 验证文件是否成功写入
if [ ! -s /root/.piclist/config.json ]; then
    log_error "config.json 写入失败或为空"
    exit 1
fi

# 再次验证文件内容
if ! jq empty /root/.piclist/config.json 2>/dev/null; then
    log_error "config.json 文件格式无效"
    cat /root/.piclist/config.json >&2
    exit 1
fi
log INFO "config.json 格式验证通过"

# 调试模式打印配置
if [ "${DEBUG:-false}" = "true" ]; then
    log INFO "=== config.json 内容 ==="
    cat /root/.piclist/config.json
    log INFO "========================"
fi

log INFO "启动 PicList-Core 服务..."
exec node /usr/local/bin/picgo-server -k "$PICLIST_KEY"