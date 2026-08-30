// deduplicate.js - 通用去重脚本（支持所有存储端）
// ES Module 版本

// ============================================
// 1. 导入核心模块
// ============================================
import crypto from 'crypto';
import axios from 'axios';

// ============================================
// 2. 配置常量
// ============================================
const CONFIG = {
    CONCURRENCY: Math.min(parseInt(process.env.DEDUP_CONCURRENCY, 10) || 3, 10),
    TIMEOUT: parseInt(process.env.DEDUP_TIMEOUT, 10) || 8000,
};

// ============================================
// 3. 工具函数
// ============================================

// 安全日志
function log(ctx, level, msg) {
    const fn = ctx.log?.[level] || ctx.log?.log || console.log;
    fn.call(ctx.log || console, msg);
}

// 计算 MD5
async function calcMD5(file) {
    if (Buffer.isBuffer(file) || file instanceof ArrayBuffer) {
        return crypto.createHash('md5').update(file).digest('hex');
    }
    if (file.buffer) {
        return crypto.createHash('md5').update(file.buffer).digest('hex');
    }
    if (file.path) {
        const fs = await import('fs');
        const buffer = fs.readFileSync(file.path);
        return crypto.createHash('md5').update(buffer).digest('hex');
    }
    throw new Error('无法计算 MD5');
}

// 构建存储路径
function buildKey(path, hash, extname) {
    const base = (path || '').replace(/^\/+/, '').replace(/\/+$/, '');
    const ext = (extname || 'bin').replace(/^\.+/, '');
    return base ? `${base}/${hash}.${ext}` : `${hash}.${ext}`;
}

// ============================================
// 4. 各存储端的检查器
// ============================================

// ---------- 腾讯云 COS ----------
async function checkTencent(ctx, config, file) {
    const hash = await calcMD5(file);
    const key = buildKey(config.path, hash, file.extname);
    
    try {
        // 动态导入 COS SDK
        const COS = (await import('cos-nodejs-sdk-v5')).default;
        const cos = new COS({
            SecretId: config.secretId || config.accessKeyId,
            SecretKey: config.secretKey || config.accessKeySecret,
            Timeout: CONFIG.TIMEOUT,
        });

        return new Promise((resolve) => {
            cos.headObject({
                Bucket: config.bucket,
                Region: config.region,
                Key: key,
            }, (err) => {
                if (err) {
                    resolve(err.statusCode === 404 ? { exists: false, key } : { exists: false, key });
                } else {
                    resolve({ exists: true, key });
                }
            });
        });
    } catch (err) {
        log(ctx, 'warn', `COS SDK 不可用，跳过云端检查: ${err.message}`);
        return { exists: false, key };
    }
}

// ---------- 阿里云 OSS ----------
async function checkAliyun(ctx, config, file) {
    const hash = await calcMD5(file);
    const key = buildKey(config.path, hash, file.extname);
    
    try {
        const OSS = (await import('ali-oss')).default;
        const client = new OSS({
            accessKeyId: config.accessKeyId,
            accessKeySecret: config.accessKeySecret,
            bucket: config.bucket,
            region: config.region,
            timeout: CONFIG.TIMEOUT,
        });

        try {
            await client.head(key);
            return { exists: true, key };
        } catch (err) {
            if (err.code === 'NoSuchKey') {
                return { exists: false, key };
            }
            log(ctx, 'warn', `OSS 检查出错: ${err.message}`);
            return { exists: false, key };
        }
    } catch (err) {
        log(ctx, 'warn', `OSS SDK 不可用，跳过云端检查: ${err.message}`);
        return { exists: false, key };
    }
}

// ---------- S3 兼容存储（R2、MinIO、华为云 OBS 等）----------
async function checkS3(ctx, config, file) {
    const hash = await calcMD5(file);
    const key = buildKey(config.path, hash, file.extname);
    
    try {
        // 尝试使用 AWS SDK
        const AWS = (await import('aws-sdk')).default;
        const s3 = new AWS.S3({
            accessKeyId: config.accessKeyId || config.accessKey,
            secretAccessKey: config.secretAccessKey || config.secretKey,
            endpoint: config.endpoint,
            region: config.region || 'auto',
            s3ForcePathStyle: true,
            signatureVersion: 'v4',
            httpOptions: { timeout: CONFIG.TIMEOUT },
        });

        try {
            await s3.headObject({ Bucket: config.bucket, Key: key }).promise();
            return { exists: true, key };
        } catch (err) {
            if (err.code === 'NotFound') {
                return { exists: false, key };
            }
            log(ctx, 'warn', `S3 检查出错: ${err.message}`);
            return { exists: false, key };
        }
    } catch (err) {
        // SDK 不可用，使用 REST API（S3 兼容）
        log(ctx, 'warn', `AWS SDK 不可用，尝试使用 REST API 检查`);
        try {
            const endpoint = config.endpoint || `https://${config.bucket}.s3.${config.region || 'auto'}.amazonaws.com`;
            const url = `${endpoint.replace(/\/+$/, '')}/${encodeURIComponent(key)}`;
            await axios.head(url, {
                headers: {
                    'Authorization': `AWS ${config.accessKeyId}:${config.secretAccessKey}`,
                },
                timeout: CONFIG.TIMEOUT,
            });
            return { exists: true, key };
        } catch (restErr) {
            if (restErr.response?.status === 404) {
                return { exists: false, key };
            }
            log(ctx, 'warn', `S3 REST API 检查失败: ${restErr.message}`);
            return { exists: false, key };
        }
    }
}

// ---------- WebDAV ----------
async function checkWebDAV(ctx, config, file) {
    const hash = await calcMD5(file);
    const key = buildKey(config.path, hash, file.extname);
    const baseUrl = config.endpoint.replace(/\/+$/, '');
    const url = `${baseUrl}/${encodeURIComponent(key)}`;

    try {
        await axios.head(url, {
            auth: {
                username: config.username,
                password: config.password,
            },
            timeout: CONFIG.TIMEOUT,
        });
        return { exists: true, key };
    } catch (err) {
        if (err.response?.status === 404) {
            return { exists: false, key };
        }
        log(ctx, 'warn', `WebDAV 检查出错: ${err.message}`);
        return { exists: false, key };
    }
}

// ---------- 又拍云 ----------
async function checkUpyun(ctx, config, file) {
    const hash = await calcMD5(file);
    const key = buildKey(config.path, hash, file.extname);
    const baseUrl = `https://${config.bucket}.${config.customUrl || 'v0.api.upyun.com'}`;
    const url = `${baseUrl}/${encodeURIComponent(key)}`;

    try {
        const auth = Buffer.from(`${config.username}:${config.password}`).toString('base64');
        await axios.head(url, {
            headers: { 'Authorization': `Basic ${auth}` },
            timeout: CONFIG.TIMEOUT,
        });
        return { exists: true, key };
    } catch (err) {
        if (err.response?.status === 404) {
            return { exists: false, key };
        }
        log(ctx, 'warn', `又拍云检查出错: ${err.message}`);
        return { exists: false, key };
    }
}

// ---------- 七牛云 ----------
async function checkQiniu(ctx, config, file) {
    const hash = await calcMD5(file);
    const key = buildKey(config.path, hash, file.extname);
    
    try {
        let baseUrl;
        if (config.customUrl && config.customUrl.includes('://')) {
            baseUrl = config.customUrl.replace(/\/+$/, '');
        } else {
            baseUrl = `https://${config.bucket}.${config.customUrl || 'qiniup.com'}`;
        }
        const url = `${baseUrl}/${encodeURIComponent(key)}`;

        await axios.head(url, { timeout: CONFIG.TIMEOUT });
        return { exists: true, key };
    } catch (err) {
        if (err.response?.status === 404) {
            return { exists: false, key };
        }
        log(ctx, 'warn', `七牛云检查出错: ${err.message}`);
        return { exists: false, key };
    }
}

// ---------- SM.MS（不支持去重）----------
async function checkSmms(ctx, config, file) {
    log(ctx, 'info', 'SM.MS 不支持去重检查，跳过');
    return { exists: false, key: file.fileName };
}

// ============================================
// 5. 检查器注册表
// ============================================
const CHECKERS = {
    tcyun: checkTencent,
    aliyun: checkAliyun,
    s3: checkS3,
    huawei: checkS3,      // 华为云 OBS 兼容 S3
    webdavplist: checkWebDAV,
    webdav: checkWebDAV,
    upyun: checkUpyun,
    qiniu: checkQiniu,
    smms: checkSmms,
};

// ============================================
// 6. 获取当前配置
// ============================================
function getConfig(ctx, currentType) {
    let config = ctx.getConfig(`uploader.${currentType}`);
    if (!config) return null;

    // 处理 configList 多配置模式
    if (config.configList && Array.isArray(config.configList)) {
        const list = config.configList;
        if (list.length === 0) return null;

        const currentName = ctx.getConfig('picBed.current');
        if (currentName) {
            const matched = list.find(c => c._configName === currentName);
            if (matched) return matched;
        }
        if (config.defaultId) {
            const matched = list.find(c => c._configName === config.defaultId);
            if (matched) return matched;
        }
        return list[0];
    }
    return config;
}

// ============================================
// 7. 主函数
// ============================================
async function main(ctx) {
    const files = ctx.input;
    if (!files || files.length === 0) {
        return ctx;
    }

    const currentType = ctx.getConfig('picBed.current');
    if (!currentType) {
        log(ctx, 'warn', '未找到当前图床配置，跳过查重');
        return ctx;
    }

    const checker = CHECKERS[currentType];
    if (!checker) {
        log(ctx, 'info', `图床类型 ${currentType} 暂不支持去重，跳过`);
        return ctx;
    }

    const config = getConfig(ctx, currentType);
    if (!config) {
        log(ctx, 'warn', `未找到图床 ${currentType} 的配置，跳过查重`);
        return ctx;
    }

    log(ctx, 'info', `开始去重检查 (${currentType})，共 ${files.length} 个文件`);

    const filesToUpload = [];
    const processedKeys = new Set();

    for (let i = 0; i < files.length; i++) {
        const file = files[i];
        try {
            const result = await checker(ctx, config, file);
            if (result.exists) {
                log(ctx, 'info', `[${i+1}/${files.length}] [跳过] ${result.key}`);
                continue;
            }
            if (processedKeys.has(result.key)) {
                log(ctx, 'info', `[${i+1}/${files.length}] [跳过] 本次重复: ${result.key}`);
                continue;
            }
            processedKeys.add(result.key);
            filesToUpload.push(file);
        } catch (err) {
            log(ctx, 'warn', `[${i+1}/${files.length}] [允许上传] ${file.fileName}: ${err.message}`);
            filesToUpload.push(file);
        }
    }

    const skipped = files.length - filesToUpload.length;
    log(ctx, 'info', `✅ 去重完成：跳过 ${skipped} 个，准备上传 ${filesToUpload.length} 个`);

    ctx.input = filesToUpload;
    return ctx;
}

export default { main };