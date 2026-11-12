/*
 * MyTVBox 1.7.0 端上 Node 运行时入口
 *
 * 作用：在 App 内部（NodeMobile.framework）加载猫爪源 bundle 并起本地 HTTP 服务，
 *      让 App 通过 http://127.0.0.1:<PORT> 访问，彻底摆脱电脑中转。
 *
 * 关键约束（都是实测出来的）：
 *   1. bundle 导出的是 {start, stop}，start() 返回 Promise，必须 await 才真正 listen。
 *   2. bundle 会往 CWD 写 wexfnwconfig.json，所以必须 chdir 到可写目录。
 *   3. 端口由环境变量 PORT 传入，源在端口被占用时会自动 +1，所以 Swift 侧要轮询而不是假定。
 *   4. 任何异常都要落盘到 node.log，否则 iOS 上只能看到黑屏。
 */
const path = require('path');
const fs = require('fs');

const DIR = __dirname;
const LOG = path.join(DIR, 'node.log');

try { process.chdir(DIR); } catch (e) {}

function log(msg) {
    try {
        fs.appendFileSync(LOG, '[' + new Date().toISOString() + '] ' + msg + '\n');
    } catch (e) { /* 日志写不了也不能崩 */ }
}

function flush() {
    // 让 Swift 侧能读到日志（appendFileSync 已同步，这里只是占位）
}

log('=== boot ===');
log('node ' + process.version + ' pid=' + process.pid + ' cwd=' + process.cwd());
log('PORT=' + process.env.PORT + ' HOST=' + process.env.HOST + ' NODE_ENV=' + process.env.NODE_ENV);

process.on('uncaughtException', (e) => {
    log('FATAL uncaught: ' + (e && e.stack ? e.stack : String(e)));
});
process.on('unhandledRejection', (e) => {
    log('FATAL unhandled: ' + (e && e.stack ? e.stack : String(e)));
});

(async () => {
    let mod;
    try {
        log('loading index.js ...');
        mod = require(path.join(DIR, 'index.js'));
        log('bundle loaded, exports=' + Object.keys(mod || {}).join(','));
    } catch (e) {
        log('FATAL require: ' + (e && e.stack ? e.stack : String(e)));
        return;
    }

    if (typeof mod.start !== 'function') {
        log('FATAL: bundle has no start()');
        return;
    }

    try {
        const r = mod.start({});
        if (r && typeof r.then === 'function') {
            await r;
        }
        log('bundle start() resolved');
    } catch (e) {
        log('FATAL start(): ' + (e && e.stack ? e.stack : String(e)));
        return;
    }

    // 探明真实端口（源可能在 PORT 被占用时自动 +1），写入 ready.txt 供 Swift 读取
    try {
        const http = require('http');
        const base = parseInt(process.env.PORT || '18923', 10);
        for (let p = base; p < base + 12; p++) {
            const ok = await new Promise((resolve) => {
                const req = http.get({ host: '127.0.0.1', port: p, path: '/health', timeout: 1500 }, (res) => {
                    let b = '';
                    res.on('data', (d) => { b += d; });
                    res.on('end', () => {
                        try { resolve(res.statusCode === 200 && JSON.parse(b).name === 'CatVodSpiderios'); }
                        catch (e2) { resolve(false); }
                    });
                });
                req.on('error', () => resolve(false));
                req.on('timeout', () => { req.destroy(); resolve(false); });
            });
            if (ok) {
                fs.writeFileSync(path.join(DIR, 'ready.txt'), String(p));
                log('READY on port ' + p);
                return;
            }
        }
        log('FATAL: started but no /health on ' + base + '..' + (base + 11));
    } catch (e) {
        log('FATAL probe: ' + (e && e.stack ? e.stack : String(e)));
    }
})();

// 保活：Node 的 event loop 不能空转退出
setInterval(() => {}, 1 << 30);

// 1.7.1：每分钟记一次内存，方便线上排查「播放返回后闪退」是不是 Node 吃太多。
// unref() 让这个定时器不阻止进程退出。
setInterval(() => {
    try {
        const m = process.memoryUsage();
        log('mem rss=' + Math.round(m.rss / 1048576) + 'MB'
            + ' heapUsed=' + Math.round(m.heapUsed / 1048576) + 'MB'
            + ' heapTotal=' + Math.round(m.heapTotal / 1048576) + 'MB'
            + ' ext=' + Math.round(m.external / 1048576) + 'MB');
    } catch (e) { /* 忽略 */ }
}, 60000).unref();

// 确保 flush 被引用（避免打包器优化掉）
flush();
