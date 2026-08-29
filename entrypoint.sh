#!/bin/sh
set -e

# ============================================
# 环境变量说明
# ============================================
# 必需变量：
#   PICLIST_KEY          : API 鉴权密钥（必需）
#
# 同步相关（可选）：
#   SYNC_ENABLED         : 设为 true 时启用云端同步拉取
#   SYNC_TYPE            : webdav / github / gitee
#   SYNC_WEBDAV_ENDPOINT : WebDAV 服务器地址（如坚果云）
#   SYNC_WEBDAV_USERNAME : WebDAV 用户名
#   SYNC_WEBDAV_PASSWORD : WebDAV 密码（应用密码）
#   SYNC_GITHUB_REPO     : GitHub 仓库（格式：用户名/仓库名）
#   SYNC_GITHUB_TOKEN    : GitHub Personal Access Token
#   SYNC_GITEE_REPO      : Gitee 仓库（格式：用户名/仓库名）
#   SYNC_GITEE_TOKEN     : Gitee Personal Access Token
#
# 配置生成相关（如果同步未启用或失败）：
#   PICBED_MODE          : single（默认）或 multi
#   PICBED_TYPE          : 单图床类型（tencent, aliyun, huawei, upyun, qiniu, webdav, s3, smms）
#   PICBED_DEFAULT       : 多图床模式下的默认配置名
#
# buildin 功能（独立变量，无水分）：
#   PICBED_COMPRESS         : 是否开启压缩（true/false），默认 true
#   PICBED_COMPRESS_QUALITY : 压缩质量（0-100），默认 80
#   PICBED_RENAME           : 是否开启重命名（true/false），默认 true
#   PICBED_RENAME_RULE      : 重命名规则，默认 {md5}
#   PICBED_EXIF_REMOVE      : 是否移除 EXIF 信息（true/false），默认 false
#
# 多图床模式（前缀环境变量方式，推荐）：
#   PICBED_0_NAME        : 图床配置名称（必需）
#   PICBED_0_TYPE        : 图床类型（tencent, aliyun, s3, webdav 等）
#   PICBED_0_*           : 对应平台参数（见下方映射表）
#   PICBED_0_BACKUP_OF   : 可选，指定该图床是哪个图床的备份（只取第一个）
#   支持多个图床，索引从 0 开始递增
#
# 类型与 PicList uploader 映射表：
#   tencent  -> tcyun
#   aliyun   -> aliyun
#   huawei   -> huawei
#   upyun    -> upyun
#   qiniu    -> qiniu
#   s3       -> s3
#   webdav   -> webdavplist
# ============================================

# ============================================
# 1. 初始化与基础检查
# ============================================

# 检查必需变量
if [ -z "$PICLIST_KEY" ]; then
    echo "ERROR: PICLIST_KEY is not set" >&2
    exit 1
fi

# 设置只读常量
readonly PICLIST_KEY="${PICLIST_KEY}"
readonly PICBED_MODE=${PICBED_MODE:-single}
readonly PICBED_DEFAULT=${PICBED_DEFAULT:-}
readonly SYNC_ENABLED=${SYNC_ENABLED:-false}

# buildin 独立变量（无水分）
readonly PICBED_COMPRESS=${PICBED_COMPRESS:-true}
readonly PICBED_COMPRESS_QUALITY=${PICBED_COMPRESS_QUALITY:-80}
readonly PICBED_RENAME=${PICBED_RENAME:-true}
readonly PICBED_RENAME_RULE=${PICBED_RENAME_RULE:-"{md5}"}
readonly PICBED_EXIF_REMOVE=${PICBED_EXIF_REMOVE:-false}

# 创建配置目录
mkdir -p /root/.piclist

# 部署去重脚本（如果存在）
mkdir -p /root/.piclist/scripts/beforeUpload
if [ -f "/deduplicate.js" ]; then
    cp /deduplicate.js /root/.piclist/scripts/beforeUpload/deduplicate.js
    echo "✅ 去重脚本部署成功"
else
    echo "⚠️ 警告：未找到去重脚本，去重功能不可用"
fi

# ============================================
# 2. 工具函数
# ============================================

log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1" >&2
}

log_error() {
    echo "[ERROR] $1" >&2
}

validate_json() {
    local file="$1"
    if command -v jq >/dev/null 2>&1; then
        if ! jq empty "$file" 2>/dev/null; then
            log_error "生成的 config.json 格式无效"
            cat "$file" >&2
            return 1
        fi
        log_info "✅ config.json 格式验证通过"
        return 0
    fi
    return 0
}

get_env_value() {
    local var_name="$1"
    eval echo "\$$var_name"
}

# ============================================
# 3. 配置生成函数
# ============================================

# --------------------------------------------
# 3.1 生成默认配置（SM.MS 图床）
# --------------------------------------------
generate_default_config() {
    cat <<EOF
{
  "picBed": {
    "current": "smms"
  },
  "uploader": {
    "smms": {}
  }
}
EOF
}

# --------------------------------------------
# 3.2 根据类型获取 PicList uploader 名称
# --------------------------------------------
get_uploader_type() {
    local type="$1"
    case "$type" in
        tencent) echo "tcyun" ;;
        webdav)  echo "webdavplist" ;;
        *)       echo "$type" ;;
    esac
}

# --------------------------------------------
# 3.3 根据类型构建参数对象
# --------------------------------------------
build_params_for_type() {
    local type="$1"
    local prefix="$2"
    local params="{}"
    
    case "$type" in
        tencent)
            for key in SECRET_ID SECRET_KEY BUCKET REGION PATH; do
                val=$(get_env_value "${prefix}_$key")
                [ -n "$val" ] && params=$(echo "$params" | jq --arg key "$(echo "$key" | tr '[:upper:]' '[:lower:]')" --arg val "$val" '. + {($key): $val}')
            done
            ;;
        s3)
            for key in ACCESS_KEY_ID SECRET_ACCESS_KEY BUCKET REGION ENDPOINT PATH; do
                val=$(get_env_value "${prefix}_$key")
                [ -n "$val" ] && params=$(echo "$params" | jq --arg key "$(echo "$key" | tr '[:upper:]' '[:lower:]')" --arg val "$val" '. + {($key): $val}')
            done
            ;;
        aliyun)
            for key in ACCESS_KEY_ID ACCESS_KEY_SECRET BUCKET REGION PATH; do
                val=$(get_env_value "${prefix}_$key")
                [ -n "$val" ] && params=$(echo "$params" | jq --arg key "$(echo "$key" | tr '[:upper:]' '[:lower:]')" --arg val "$val" '. + {($key): $val}')
            done
            ;;
        huawei)
            for key in ACCESS_KEY SECRET_KEY BUCKET ENDPOINT PATH; do
                val=$(get_env_value "${prefix}_$key")
                [ -n "$val" ] && params=$(echo "$params" | jq --arg key "$(echo "$key" | tr '[:upper:]' '[:lower:]')" --arg val "$val" '. + {($key): $val}')
            done
            ;;
        upyun)
            for key in USERNAME PASSWORD BUCKET CUSTOM_URL PATH; do
                val=$(get_env_value "${prefix}_$key")
                [ -n "$val" ] && params=$(echo "$params" | jq --arg key "$(echo "$key" | tr '[:upper:]' '[:lower:]')" --arg val "$val" '. + {($key): $val}')
            done
            ;;
        qiniu)
            for key in ACCESS_KEY SECRET_KEY BUCKET CUSTOM_URL PATH; do
                val=$(get_env_value "${prefix}_$key")
                [ -n "$val" ] && params=$(echo "$params" | jq --arg key "$(echo "$key" | tr '[:upper:]' '[:lower:]')" --arg val "$val" '. + {($key): $val}')
            done
            ;;
        webdav)
            for key in ENDPOINT USERNAME PASSWORD PATH; do
                val=$(get_env_value "${prefix}_$key")
                [ -n "$val" ] && params=$(echo "$params" | jq --arg key "$(echo "$key" | tr '[:upper:]' '[:lower:]')" --arg val "$val" '. + {($key): $val}')
            done
            ;;
        *)
            log_error "不支持的图床类型: $type"
            return 1
            ;;
    esac
    
    echo "$params"
}

# --------------------------------------------
# 3.4 生成单图床配置
# --------------------------------------------
generate_single_config() {
    local type="$1"
    local config_json=""

    case "$type" in
        tencent)
            : "${TC_SECRET_ID:?需设置 TC_SECRET_ID}"
            : "${TC_SECRET_KEY:?需设置 TC_SECRET_KEY}"
            : "${TC_BUCKET:?需设置 TC_BUCKET}"
            : "${TC_REGION:?需设置 TC_REGION}"
            config_json=$(cat <<EOF
{
  "picBed": { "current": "tcyun" },
  "uploader": {
    "tcyun": {
      "secretId": "${TC_SECRET_ID}",
      "secretKey": "${TC_SECRET_KEY}",
      "bucket": "${TC_BUCKET}",
      "region": "${TC_REGION}",
      "path": "${TC_PATH:-}"
    }
  }
}
EOF
            )
            ;;
        aliyun)
            : "${ALI_ACCESS_KEY_ID:?需设置 ALI_ACCESS_KEY_ID}"
            : "${ALI_ACCESS_KEY_SECRET:?需设置 ALI_ACCESS_KEY_SECRET}"
            : "${ALI_BUCKET:?需设置 ALI_BUCKET}"
            : "${ALI_REGION:?需设置 ALI_REGION}"
            config_json=$(cat <<EOF
{
  "picBed": { "current": "aliyun" },
  "uploader": {
    "aliyun": {
      "accessKeyId": "${ALI_ACCESS_KEY_ID}",
      "accessKeySecret": "${ALI_ACCESS_KEY_SECRET}",
      "bucket": "${ALI_BUCKET}",
      "region": "${ALI_REGION}",
      "path": "${ALI_PATH:-}"
    }
  }
}
EOF
            )
            ;;
        huawei)
            : "${HW_ACCESS_KEY:?需设置 HW_ACCESS_KEY}"
            : "${HW_SECRET_KEY:?需设置 HW_SECRET_KEY}"
            : "${HW_BUCKET:?需设置 HW_BUCKET}"
            : "${HW_ENDPOINT:?需设置 HW_ENDPOINT}"
            config_json=$(cat <<EOF
{
  "picBed": { "current": "huawei" },
  "uploader": {
    "huawei": {
      "accessKey": "${HW_ACCESS_KEY}",
      "secretKey": "${HW_SECRET_KEY}",
      "bucket": "${HW_BUCKET}",
      "endpoint": "${HW_ENDPOINT}",
      "path": "${HW_PATH:-}"
    }
  }
}
EOF
            )
            ;;
        upyun)
            : "${UP_USERNAME:?需设置 UP_USERNAME}"
            : "${UP_PASSWORD:?需设置 UP_PASSWORD}"
            : "${UP_BUCKET:?需设置 UP_BUCKET}"
            : "${UP_CUSTOM_URL:?需设置 UP_CUSTOM_URL}"
            config_json=$(cat <<EOF
{
  "picBed": { "current": "upyun" },
  "uploader": {
    "upyun": {
      "username": "${UP_USERNAME}",
      "password": "${UP_PASSWORD}",
      "bucket": "${UP_BUCKET}",
      "customUrl": "${UP_CUSTOM_URL}",
      "path": "${UP_PATH:-}"
    }
  }
}
EOF
            )
            ;;
        qiniu)
            : "${QN_ACCESS_KEY:?需设置 QN_ACCESS_KEY}"
            : "${QN_SECRET_KEY:?需设置 QN_SECRET_KEY}"
            : "${QN_BUCKET:?需设置 QN_BUCKET}"
            : "${QN_CUSTOM_URL:?需设置 QN_CUSTOM_URL}"
            config_json=$(cat <<EOF
{
  "picBed": { "current": "qiniu" },
  "uploader": {
    "qiniu": {
      "accessKey": "${QN_ACCESS_KEY}",
      "secretKey": "${QN_SECRET_KEY}",
      "bucket": "${QN_BUCKET}",
      "customUrl": "${QN_CUSTOM_URL}",
      "path": "${QN_PATH:-}"
    }
  }
}
EOF
            )
            ;;
        webdav)
            : "${WEBDAV_ENDPOINT:?需设置 WEBDAV_ENDPOINT}"
            : "${WEBDAV_USERNAME:?需设置 WEBDAV_USERNAME}"
            : "${WEBDAV_PASSWORD:?需设置 WEBDAV_PASSWORD}"
            config_json=$(cat <<EOF
{
  "picBed": { "current": "webdavplist" },
  "uploader": {
    "webdavplist": {
      "endpoint": "${WEBDAV_ENDPOINT}",
      "username": "${WEBDAV_USERNAME}",
      "password": "${WEBDAV_PASSWORD}",
      "path": "${WEBDAV_PATH:-}"
    }
  }
}
EOF
            )
            ;;
        s3)
            : "${S3_ACCESS_KEY_ID:?需设置 S3_ACCESS_KEY_ID}"
            : "${S3_SECRET_ACCESS_KEY:?需设置 S3_SECRET_ACCESS_KEY}"
            : "${S3_BUCKET:?需设置 S3_BUCKET}"
            : "${S3_ENDPOINT:?需设置 S3_ENDPOINT}"
            config_json=$(cat <<EOF
{
  "picBed": { "current": "s3" },
  "uploader": {
    "s3": {
      "accessKeyId": "${S3_ACCESS_KEY_ID}",
      "secretAccessKey": "${S3_SECRET_ACCESS_KEY}",
      "bucket": "${S3_BUCKET}",
      "region": "${S3_REGION:-auto}",
      "endpoint": "${S3_ENDPOINT}",
      "path": "${S3_PATH:-}"
    }
  }
}
EOF
            )
            ;;
        smms)
            config_json=$(generate_default_config)
            ;;
        *)
            log_error "不支持的图床类型: $type"
            exit 1
            ;;
    esac

    echo "$config_json"
}

# --------------------------------------------
# 3.5 生成多图床配置（支持混合类型）
# --------------------------------------------
generate_multi_config_from_env() {
    indexes=$(env | grep '^PICBED_[0-9]\+_NAME=' | sed 's/^PICBED_\([0-9]\+\)_NAME=.*$/\1/' | sort -n)
    
    if [ -z "$indexes" ]; then
        log_error "多图床模式下未找到 PICBED_*_NAME 环境变量"
        exit 1
    fi
    
    TEMP_DIR=$(mktemp -d)
    trap "rm -rf $TEMP_DIR" EXIT INT TERM
    
    type_list=""
    first_config_name=""
    first_config_type=""
    
    second_config_enable="false"
    second_config_uploader=""
    second_config_name=""
    second_config_target=""
    
    for idx in $indexes; do
        prefix="PICBED_${idx}"
        
        name=$(get_env_value "${prefix}_NAME")
        type=$(get_env_value "${prefix}_TYPE")
        
        if [ -z "$name" ] || [ -z "$type" ]; then
            log_warn "跳过索引 $idx: NAME 或 TYPE 缺失"
            continue
        fi
        
        log_info "发现图床配置: $name (类型: $type)"
        
        params=$(build_params_for_type "$type" "$prefix")
        if [ $? -ne 0 ]; then
            log_warn "跳过索引 $idx: 参数构建失败"
            continue
        fi
        
        uploader_type=$(get_uploader_type "$type")
        config_obj=$(echo "$params" | jq --arg name "$name" '. + {_configName: $name}')
        
        config_file="${TEMP_DIR}/${uploader_type}.list"
        if [ -f "$config_file" ]; then
            echo ", $config_obj" >> "$config_file"
        else
            echo "$config_obj" > "$config_file"
            type_list="${type_list}${uploader_type} "
        fi
        
        if [ -z "$first_config_name" ]; then
            first_config_name="$name"
            first_config_type="$uploader_type"
        fi
        
        backup_of=$(get_env_value "${prefix}_BACKUP_OF")
        if [ -n "$backup_of" ] && [ "$second_config_enable" = "false" ]; then
            second_config_enable="true"
            second_config_uploader="$uploader_type"
            second_config_name="$name"
            second_config_target="$backup_of"
            log_info "备份配置: $name -> $backup_of"
        fi
    done
    
    if [ -z "$type_list" ]; then
        log_error "未找到任何有效的图床配置"
        exit 1
    fi
    
    cat <<EOF
{
  "picBed": {
    "current": "${PICBED_DEFAULT:-$first_config_name}"
  },
  "uploader": {
EOF
    
    first_type=true
    for uploader_type in $type_list; do
        config_file="${TEMP_DIR}/${uploader_type}.list"
        if [ ! -f "$config_file" ]; then
            continue
        fi
        
        config_content=$(cat "$config_file")
        
        if [ "$first_type" = "true" ]; then
            first_type=false
        else
            echo ","
        fi
        
        cat <<EOF
    "${uploader_type}": {
      "configList": [${config_content}]
    }
EOF
    done
    
    cat <<EOF
  }
EOF
    
    if [ "$second_config_enable" = "true" ]; then
        cat <<EOF
  "secondConfig": {
    "enable": true,
    "mode": "backup",
    "uploader": "${second_config_uploader}",
    "configName": "${second_config_name}",
    "target": "${second_config_target}"
  }
EOF
    fi
    
    echo "}"
}

# --------------------------------------------
# 3.6 兼容旧版 JSON 方式的多图床配置
# --------------------------------------------
generate_multi_config_from_json() {
    local config_list="$1"
    if [ -z "$config_list" ]; then
        log_error "PICBED_CONFIG_LIST 未设置"
        exit 1
    fi

    cat <<EOF
{
  "picBed": {
    "current": "${PICBED_DEFAULT:-s3}"
  },
  "uploader": {
    "s3": {
      "configList": ${config_list},
      "defaultId": "${PICBED_DEFAULT}"
    }
  }
}
EOF
}

# --------------------------------------------
# 3.7 生成 buildin 对象（从独立变量构建）
# --------------------------------------------
generate_buildin_json() {
    if [ -n "$PICBED_BUILDIN" ]; then
        log_warn "检测到旧版 PICBED_BUILDIN，将使用其值（建议迁移到独立变量）"
        if echo "$PICBED_BUILDIN" | jq -e . >/dev/null 2>&1; then
            echo "$PICBED_BUILDIN"
            return
        else
            log_error "PICBED_BUILDIN 格式无效，将使用独立变量构建"
        fi
    fi
    
    local buildin_json="{}"
    
    buildin_json=$(echo "$buildin_json" | jq --argjson val "$PICBED_COMPRESS" '. + {compress: $val}')
    buildin_json=$(echo "$buildin_json" | jq --argjson val "$PICBED_COMPRESS_QUALITY" '. + {compressQuality: $val}')
    buildin_json=$(echo "$buildin_json" | jq --argjson val "$PICBED_RENAME" '. + {rename: $val}')
    buildin_json=$(echo "$buildin_json" | jq --arg val "$PICBED_RENAME_RULE" '. + {renameRule: $val}')
    buildin_json=$(echo "$buildin_json" | jq --argjson val "$PICBED_EXIF_REMOVE" '. + {exifRemove: $val}')
    
    echo "$buildin_json"
}

# --------------------------------------------
# 3.8 合并 buildin 功能
# --------------------------------------------
merge_buildin() {
    local config_json="$1"
    local buildin_json=$(generate_buildin_json)
    
    if command -v jq >/dev/null 2>&1; then
        echo "$config_json" | jq --argjson buildin "$buildin_json" '. + {buildin: $buildin}'
    else
        log_warn "jq 未安装，使用 sed 拼接 buildin（可能不完整）"
        buildin_part=$(echo "$buildin_json" | sed 's/^{//;s/}$//')
        final_config=$(echo "$config_json" | sed 's/}$//')
        echo "${final_config}, \"buildin\": {${buildin_part}} }"
    fi
}

# ============================================
# 4. 主逻辑
# ============================================

# 第一步：尝试从云端同步配置
if [ "$SYNC_ENABLED" = "true" ]; then
    log_info "尝试从云端拉取配置..."
    
    cat > /root/.piclist/config.json << EOF
{
  "sync": {
    "type": "${SYNC_TYPE:-webdav}",
    "webdavEndpoint": "${SYNC_WEBDAV_ENDPOINT}",
    "username": "${SYNC_WEBDAV_USERNAME}",
    "password": "${SYNC_WEBDAV_PASSWORD}",
    "githubRepo": "${SYNC_GITHUB_REPO}",
    "githubToken": "${SYNC_GITHUB_TOKEN}",
    "giteeRepo": "${SYNC_GITEE_REPO}",
    "giteeToken": "${SYNC_GITEE_TOKEN}"
  }
}
EOF

    if picgo sync pull --config /root/.piclist/config.json 2>/dev/null; then
        log_info "✅ 云端配置拉取成功，将使用云端配置启动。"
        exec node /usr/local/bin/picgo-server -k "${PICLIST_KEY}"
        exit 0
    else
        log_warn "云端配置拉取失败，将尝试通过环境变量生成配置。"
        rm -f /root/.piclist/config.json
    fi
fi

# 第二步：通过环境变量生成配置
log_info "通过环境变量生成配置..."

if [ "$PICBED_MODE" = "multi" ]; then
    if [ -n "$PICBED_CONFIG_LIST" ]; then
        log_info "检测到 PICBED_CONFIG_LIST，使用 JSON 方式生成多图床配置..."
        config_json=$(generate_multi_config_from_json "$PICBED_CONFIG_LIST")
    else
        log_info "使用前缀环境变量方式生成多图床配置（支持混合类型）..."
        config_json=$(generate_multi_config_from_env)
    fi
elif [ -n "$PICBED_TYPE" ]; then
    log_info "使用单图床模式生成配置（类型: $PICBED_TYPE）..."
    config_json=$(generate_single_config "$PICBED_TYPE")
else
    log_info "未指定 PICBED_TYPE，生成默认配置（SM.MS 图床）"
    config_json=$(generate_default_config)
fi

log_info "合并内置功能 (buildin)..."
final_config=$(merge_buildin "$config_json")

echo "$final_config" > /root/.piclist/config.json
log_info "配置文件已写入: /root/.piclist/config.json"

if ! validate_json /root/.piclist/config.json; then
    log_error "配置文件验证失败，请检查环境变量配置"
    exit 1
fi

if [ "${DEBUG:-false}" = "true" ]; then
    log_info "配置文件内容:"
    cat /root/.piclist/config.json
fi

log_info "启动 PicList-Core 服务..."
exec node /usr/local/bin/picgo-server -k "${PICLIST_KEY}"
