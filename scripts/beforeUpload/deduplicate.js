// scripts/beforeUpload/deduplicate.js
// 多图床上传前去重脚本 v7 - 最终生产级

const crypto = require('crypto');
const axios = require('axios');
const { createReadStream } = require('fs');
const https = require('https');

// ============================================
// 1. 配置常量
// ============================================
const CONFIG = {
    CONCURRENCY: Math.min(
        parseInt(process.env.DEDUP_CONCURRENCY, 10) || 5,
        20
    ),
    TIMEOUT: parseInt(process.env.DEDUP_TIMEOUT, 10) || 10000,
    WEBDAV_INSECURE: process.env.WEBDAV_INSECURE?.toLowerCase() === 'true',
};

// ============================================
// 2. 安全日志工具
// ============================================
function safeLog(ctx, level, message) {
    const logMethods = {
        info: ['info', 'log', 'debug'],
        warn: ['warn', 'warning', 'log'],
        error: ['error', 'log'],
    };

    const methods = logMethods[level] || ['log'];
    for (const method of methods) {
        if (ctx?.log && typeof ctx.log[method] === 'function') {
            ctx.log[method](message);
            return;
        }
    }
    console.log(`[${level.toUpperCase()}] ${message}`);
}

function logInfo(ctx, msg) { safeLog(ctx, 'info', msg); }
function logWarn(ctx, msg) { safeLog(ctx, 'warn', msg); }
function logError(ctx, msg) { safeLog(ctx, 'error', msg); }

// ============================================
// 3. 工具函数
// ============================================

/**
 * 将 ArrayBuffer 转换为 Buffer
 */
function toBuffer(data) {
    if (Buffer.isBuffer(data)) return data;
    if (data instanceof ArrayBuffer) {
        return Buffer.from(data);
    }
    if (data && typeof data.buffer === 'object' && data.buffer instanceof ArrayBuffer) {
        return Buffer.from(data.buffer);
    }
    return data;
}

/**
 * 计算文件 MD5（支持 buffer、path、stream）
 */
async function calcMD5(file) {
    // 如果 file 本身是 Buffer 或 ArrayBuffer
    if (Buffer.isBuffer(file) || file instanceof ArrayBuffer) {
        return crypto.createHash('md5').update(toBuffer(file)).digest('hex');
    }

    // 直接使用 buffer
    if (file.buffer) {
        const buf = toBuffer(file.buffer);
        return crypto.createHash('md5').update(buf).digest('hex');
    }

    // 从文件路径读取
    if (file.path) {
        return new Promise((resolve, reject) => {
            const hash = crypto.createHash('md5');
            const stream = createReadStream(file.path);
            let resolved = false;
            let timeoutId = null;

            // 暂停流，确保所有数据都被捕获
            stream.pause();

            const cleanup = () => {
                if (timeoutId) {
                    clearTimeout(timeoutId);
                    timeoutId = null;
                }
                if (!stream.destroyed) {
                    stream.destroy();
                }
                stream.removeAllListeners();
            };

            const onFinish = (err, result) => {
                if (resolved) return;
                resolved = true;
                cleanup();
                if (err) {
                    reject(err);
                } else {
                    resolve(result);
                }
            };

            timeoutId = setTimeout(() => {
                onFinish(new Error('MD5 计算超时'));
            }, CONFIG.TIMEOUT);

            // 使用 on 而不是 once，配合 pause/resume 确保数据完整
            stream.on('data', (chunk) => hash.update(chunk));
            stream.on('end', () => {
                if (timeoutId) {
                    clearTimeout(timeoutId);
                    timeoutId = null;
                }
                onFinish(null, hash.digest('hex'));
            });
            stream.on('error', (err) => {
                onFinish(err);
            });

            // 恢复流开始读取
            stream.resume();
        });
    }

    // 从可读流读取
    if (file.stream && typeof file.stream.pipe === 'function') {
        return new Promise((resolve, reject) => {
            const hash = crypto.createHash('md5');
            const stream = file.stream;
            let resolved = false;
            let timeoutId = null;

            // 确保流处于 paused 模式
            if (stream.readableFlowing !== null && stream.readableFlowing !== false) {
                stream.pause();
            }

            const cleanup = () => {
                if (timeoutId) {
                    clearTimeout(timeoutId);
                    timeoutId = null;
                }
                if (stream.destroy && !stream.destroyed) {
                    stream.destroy();
                }
                stream.removeAllListeners();
            };

            const onFinish = (err, result) => {
                if (resolved) return;
                resolved = true;
                cleanup();
                if (err) {
                    reject(err);
                } else {
                    resolve(result);
                }
            };

            timeoutId = setTimeout(() => {
                onFinish(new Error('MD5 计算超时'));
            }, CONFIG.TIMEOUT);

            stream.on('data', (chunk) => hash.update(chunk));
            stream.on('end', () => {
                if (timeoutId) {
                    clearTimeout(timeoutId);
                    timeoutId = null;
                }
                onFinish(null, hash.digest('hex'));
            });
            stream.on('error', (err) => {
                onFinish(err);
            });

            stream.resume();
        });
    }

    throw new Error(`无法计算 MD5: 缺少 buffer、path 或 stream`);
}

/**
 * 构建存储路径（自动处理斜杠和扩展名）
 */
function buildKey(path, hash, extname) {
    const base = (path || '').replace(/^\/+/, '').replace(/\/+$/, '');
    const ext = (extname || 'bin').replace(/^\.+/, '');
    const fileName = `${hash}.${ext}`;
    return base ? `${base}/${fileName}` : fileName;
}

/**
 * 从配置中提取图床参数（支持 configList）
 */
function extractConfig(ctx, currentType) {
    let config = ctx.getConfig(`uploader.${currentType}`);
    if (!config) return null;

    // 处理 configList 多配置模式
    if (config.configList && Array.isArray(config.configList)) {
        const list = config.configList;
        if (list.length === 0) {
            logWarn(ctx, `图床 ${currentType} 的 configList 为空`);
            return null;
        }

        const currentName = ctx.getConfig('picBed.current');
        if (!currentName) {
            logWarn(ctx, 'picBed.current 未配置，尝试使用第一个配置');
            return list[0];
        }

        // 1. 精确匹配
        let matched = list.find(c => c._configName === currentName);
        if (matched) return matched;

        // 2. defaultId 回退
        if (config.defaultId) {
            matched = list.find(c => c._configName === config.defaultId);
            if (matched) return matched;
        }

        // 3. 找第一个非备份配置
        matched = list.find(c => {
            if (c.asBackupOf === true) return false;
            if (c._configName && c._configName.includes('-backup')) return false;
            return true;
        });
        if (matched) return matched;

        // 4. 最终回退到第一个
        logWarn(ctx, `未找到匹配的配置，使用第一个配置`);
        return list[0];
    }

    return config;
}

/**
 * 安全的并发控制
 */
async function concurrentMap(arr, concurrency, fn) {
    if (!arr.length) return [];

    const results = new Array(arr.length);
    const executing = new Set();
    let index = 0;
    let completed = 0;
    let resolved = false;

    return new Promise((resolve) => {
        const checkComplete = () => {
            if (resolved) return;
            if (completed === arr.length && executing.size === 0) {
                resolved = true;
                resolve(results);
            }
        };

        const executeNext = async () => {
            const currentIndex = index++;
            if (currentIndex >= arr.length) {
                checkComplete();
                return;
            }

            const item = arr[currentIndex];
            const task = (async () => {
                try {
                    const result = await fn(item, currentIndex);
                    results[currentIndex] = result !== undefined ? result : null;
                } catch (err) {
                    results[currentIndex] = { error: err };
                } finally {
                    executing.delete(task);
                    completed++;
                    checkComplete();
                    if (index < arr.length) {
                        executeNext();
                    } else {
                        checkComplete();
                    }
                }
            })();

            executing.add(task);

            if (index < arr.length && executing.size < concurrency) {
                executeNext();
            }
        };

        const initialCount = Math.min(concurrency, arr.length);
        if (initialCount === 0) {
            resolve(results);
            return;
        }

        for (let i = 0; i < initialCount; i++) {
            executeNext();
        }
    });
}

/**
 * 带超时的 Promise
 */
function withTimeout(promise, ms = CONFIG.TIMEOUT) {
    let timeoutId = null;
    let cleared = false;

    const clear = () => {
        if (!cleared) {
            cleared = true;
            if (timeoutId) {
                clearTimeout(timeoutId);
                timeoutId = null;
            }
        }
    };

    const timeoutPromise = new Promise((_, reject) => {
        timeoutId = setTimeout(() => {
            if (!cleared) {
                cleared = true;
                reject(new Error(`操作超时 (${ms}ms)`));
            }
        }, ms);
    });

    return Promise.race([
        Promise.resolve(promise).finally(clear),
        timeoutPromise,
    ]);
}

/**
 * 安全加载依赖包
 */
function safeRequire(moduleName, ctx) {
    try {
        return require(moduleName);
    } catch (error) {
        if (error.code === 'MODULE_NOT_FOUND') {
            logError(ctx, `缺少依赖包 "${moduleName}"，去重功能不可用`);
            logError(ctx, `请安装: npm install -g ${moduleName}`);
        }
        throw error;
    }
}

/**
 * 创建 S3 客户端
 */
function createS3Client(config, ctx) {
    const AWS = require('aws-sdk');
    
    // 检查必需的凭证
    const accessKeyId = config.accessKeyId || config.accessKey;
    const secretAccessKey = config.secretAccessKey || config.secretKey;
    
    if (!accessKeyId || !secretAccessKey) {
        logWarn(ctx, 'S3 凭证缺失，请检查 accessKeyId 和 secretAccessKey 配置');
    }

    const options = {
        accessKeyId: accessKeyId,
        secretAccessKey: secretAccessKey,
        s3ForcePathStyle: config.pathStyle !== undefined ? config.pathStyle : true,
        signatureVersion: 'v4',
        httpOptions: { timeout: CONFIG.TIMEOUT },
    };

    if (config.endpoint) {
        options.endpoint = config.endpoint;
        if (config.endpoint.startsWith('http://')) {
            options.sslEnabled = false;
        }
    }

    if (config.region) {
        options.region = config.region;
    }

    return new AWS.S3(options);
}

// ============================================
// 4. 各存储类型的检查器
// ============================================

/**
 * S3 兼容存储
 */
const checkS3 = async (ctx, config, file) => {
    const hash = await calcMD5(file);
    const key = buildKey(config.path, hash, file.extname);

    try {
        const s3 = createS3Client(config, ctx);
        await withTimeout(
            s3.headObject({ Bucket: config.bucket, Key: key }).promise()
        );
        return { exists: true, key };
    } catch (error) {
        if (error.code === 'NotFound') return { exists: false, key };
        if (error.message?.includes('endpoint') || error.message?.includes('Credentials')) {
            logWarn(ctx, `S3 配置错误 [${file.fileName}]: ${error.message}`);
        } else {
            logWarn(ctx, `S3 检查出错 [${file.fileName}]: ${error.message}`);
        }
        return { exists: false, key };
    }
};

/**
 * 腾讯云 COS
 */
const checkTencent = async (ctx, config, file) => {
    const hash = await calcMD5(file);
    const key = buildKey(config.path, hash, file.extname);

    try {
        const COS = safeRequire('cos-nodejs-sdk-v5', ctx);
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
                    if (err.statusCode === 404) {
                        resolve({ exists: false, key });
                    } else {
                        logWarn(ctx, `COS 检查出错 [${file.fileName}]: ${err.message}`);
                        resolve({ exists: false, key });
                    }
                } else {
                    resolve({ exists: true, key });
                }
            });
        });
    } catch (error) {
        logWarn(ctx, `COS 检查失败 [${file.fileName}]: ${error.message}`);
        return { exists: false, key };
    }
};

/**
 * 阿里云 OSS
 */
const checkAliyun = async (ctx, config, file) => {
    const hash = await calcMD5(file);
    const key = buildKey(config.path, hash, file.extname);

    try {
        const OSS = safeRequire('ali-oss', ctx);
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
            logWarn(ctx, `OSS 检查出错 [${file.fileName}]: ${err.message}`);
            return { exists: false, key };
        }
    } catch (error) {
        logWarn(ctx, `OSS 检查失败 [${file.fileName}]: ${error.message}`);
        return { exists: false, key };
    }
};

/**
 * 又拍云
 */
const checkUpyun = async (ctx, config, file) => {
    const hash = await calcMD5(file);
    const key = buildKey(config.path, hash, file.extname);

    try {
        const baseUrl = `https://${config.bucket}.${config.customUrl || 'v0.api.upyun.com'}`;
        const url = `${baseUrl}/${encodeURIComponent(key)}`;
        const auth = Buffer.from(`${config.username}:${config.password}`).toString('base64');

        await withTimeout(
            axios.head(url, {
                headers: { Authorization: `Basic ${auth}` },
                timeout: CONFIG.TIMEOUT,
            })
        );
        return { exists: true, key };
    } catch (error) {
        if (error.response?.status === 404) {
            return { exists: false, key };
        }
        logWarn(ctx, `又拍云检查出错 [${file.fileName}]: ${error.message}`);
        return { exists: false, key };
    }
};

/**
 * 七牛云 Kodo
 */
const checkQiniu = async (ctx, config, file) => {
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

        await withTimeout(axios.head(url, { timeout: CONFIG.TIMEOUT }));
        return { exists: true, key };
    } catch (error) {
        if (error.response?.status === 404) {
            return { exists: false, key };
        }
        logWarn(ctx, `七牛云检查出错 [${file.fileName}]: ${error.message}`);
        return { exists: false, key };
    }
};

/**
 * WebDAV
 */
const checkWebDAV = async (ctx, config, file) => {
    const hash = await calcMD5(file);
    const key = buildKey(config.path, hash, file.extname);
    const baseUrl = config.endpoint.replace(/\/+$/, '');
    const url = `${baseUrl}/${encodeURIComponent(key)}`;

    try {
        await withTimeout(
            axios.head(url, {
                auth: { username: config.username, password: config.password },
                timeout: CONFIG.TIMEOUT,
                httpsAgent: new https.Agent({
                    rejectUnauthorized: !CONFIG.WEBDAV_INSECURE,
                }),
            })
        );
        return { exists: true, key };
    } catch (error) {
        if (error.response?.status === 404) {
            return { exists: false, key };
        }
        logWarn(ctx, `WebDAV 检查出错 [${file.fileName}]: ${error.message}`);
        return { exists: false, key };
    }
};

// ============================================
// 5. 检查器注册表
// ============================================
const CHECKERS = {
    tcyun: { fn: checkTencent, label: '腾讯云 COS' },
    aliyun: { fn: checkAliyun, label: '阿里云 OSS' },
    huawei: { fn: checkS3, label: '华为云 OBS' },
    upyun: { fn: checkUpyun, label: '又拍云' },
    qiniu: { fn: checkQiniu, label: '七牛云' },
    s3: { fn: checkS3, label: 'S3 (R2)' },
    webdavplist: { fn: checkWebDAV, label: 'WebDAV' },
    webdav: { fn: checkWebDAV, label: 'WebDAV' },
};

// ============================================
// 6. 主函数
// ============================================
async function main(ctx, extra) {
    const files = ctx.input;
    if (!files?.length) return ctx;

    const currentType = ctx.getConfig('picBed.current');
    if (!currentType) {
        logWarn(ctx, '未找到当前图床配置，跳过查重');
        return ctx;
    }

    const config = extractConfig(ctx, currentType);
    if (!config) {
        logWarn(ctx, `未找到图床 ${currentType} 的配置，跳过查重`);
        return ctx;
    }

    const checker = CHECKERS[currentType];
    if (!checker) {
        logInfo(ctx, `图床类型 ${currentType} 暂不支持去重，跳过`);
        return ctx;
    }

    logInfo(ctx, `使用 ${checker.label} 进行上传前去重检测 (共 ${files.length} 个文件)`);

    try {
        const results = await concurrentMap(
            files,
            CONFIG.CONCURRENCY,
            async (file, index) => {
                try {
                    const result = await checker.fn(ctx, config, file);
                    return { file, result, index };
                } catch (error) {
                    logWarn(ctx, `[${index + 1}/${files.length}] 检查异常 [${file.fileName}]: ${error.message}，允许上传`);
                    return { file, result: { exists: false, key: file.fileName }, index };
                }
            }
        );

        const validResults = results.filter(r => r && r.result);
        const skipped = validResults.filter(r => r.result.exists).length;
        const filesToUpload = validResults
            .filter(r => !r.result.exists)
            .map(r => r.file);

        if (skipped > 0) {
            logInfo(ctx, `✅ 去重完成：跳过 ${skipped} 个已存在文件，准备上传 ${filesToUpload.length} 个文件`);
        } else {
            logInfo(ctx, `✅ 去重完成：所有 ${filesToUpload.length} 个文件均为新文件`);
        }

        ctx.input = filesToUpload;
    } catch (error) {
        logError(ctx, `❌ 去重执行失败: ${error.message}，保留所有文件继续上传`);
    }

    return ctx;
}

module.exports = { main };