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

// ---------------------------------------------------------------------------
// 1.8.6：绕开 iOS NodeMobile 缺失的 WebAssembly
//
// 实测证据（1.8.5 诊断 node.log 首行，之前五轮被 12 行日志截掉）：
//   FATAL unhandled: ReferenceError: WebAssembly is not defined
//       at lazyllhttp (node:internal/deps/undici/undici:8705:9)
//       at lib/fetch/index.js (node:internal/deps/undici/undici:10351:35)
// 查 Node 内置 undici 源码：lazyllhttp() 直接
//   `await WebAssembly.compile(require_llhttp_simd_wasm())`
// 没有 JS fallback。iOS 的 V8 是 jitless 构建、没有 WebAssembly 全局，
// 于是 bundle 里**任何一次 global fetch()** 都抛 ReferenceError（异步 →
// unhandledRejection），走 fetch 的站点永远拿不到数据（豆瓣首页 0 ITEMS）。
//
// 修法：用 Node 原生 http/https 覆盖 globalThis.fetch，请求根本不进 undici。
// 只实现猫爪源用得到的部分：GET/POST、headers、body、abort、gzip/br 解压、
// 有限重定向、text()/json()/arrayBuffer()。
// ---------------------------------------------------------------------------
(function installHttpFetchShim() {
    // 1.8.7：把「有没有装 shim」写成独立文件，Swift 诊断直接读，
    // 不用在每 10 秒一条 mem10 的日志里翻（1.8.6 诊断里就是被挤掉了）。
    function writeShim(installed, hasWasm) {
        try {
            const d = (typeof DIR !== 'undefined') ? DIR
                    : (typeof __dirname !== 'undefined' ? __dirname : '.');
            fs.writeFileSync(require('path').join(d, 'shim.txt'), JSON.stringify({
                installed: installed,
                hasWebAssembly: hasWasm,
                node: process.version,
                at: new Date().toISOString()
            }), 'utf8');
        } catch (e) { /* 只读环境也要能跑，写不了不影响主流程 */ }
    }
    const hasWasm = typeof globalThis.WebAssembly !== 'undefined';
    if (hasWasm) {
        log('fetch shim: skipped (WebAssembly available)');
        writeShim(false, true);
        return;
    }
    const http = require('http');
    const https = require('https');
    const zlib = require('zlib');
    const URLCtor = require('url').URL;

    function plainHeaders(h) {
        const out = {};
        if (!h) return out;
        if (!Array.isArray(h) && typeof h === 'object' && typeof h.forEach === 'function') {
            try { h.forEach((v, k) => { out[String(k)] = String(v); }); return out; }
            catch (e) { /* 落到下面按普通对象处理 */ }
        }
        if (Array.isArray(h)) {
            h.forEach((p) => { if (p && p.length >= 2) out[String(p[0])] = String(p[1]); });
            return out;
        }
        try { Object.keys(h).forEach((k) => { out[k] = String(h[k]); }); } catch (e) {}
        return out;
    }

    function unpack(buf, enc) {
        try {
            if (enc === 'gzip') return zlib.gunzipSync(buf);
            if (enc === 'deflate') return zlib.inflateSync(buf);
            if (enc === 'br') return zlib.brotliDecompressSync(buf);
        } catch (e) { /* 解压失败就按原文处理 */ }
        return buf;
    }

    function once(url, opts, redirects) {
        return new Promise((resolve, reject) => {
            let u;
            try { u = new URLCtor(url); } catch (e) { reject(e); return; }
            if (u.protocol !== 'http:' && u.protocol !== 'https:') {
                reject(new TypeError('fetch shim: unsupported protocol ' + u.protocol));
                return;
            }
            const mod = u.protocol === 'https:' ? https : http;
            const reqOpts = {
                method: String(opts.method || 'GET').toUpperCase(),
                hostname: u.hostname,
                port: u.port || (u.protocol === 'https:' ? 443 : 80),
                path: u.pathname + u.search,
                headers: plainHeaders(opts.headers)
            };
            // 不主动声明 accept-encoding；服务端若仍返回压缩，unpack() 负责解
            const req = mod.request(reqOpts, (res) => {
                const chunks = [];
                res.on('data', (d) => chunks.push(d));
                res.on('end', () => {
                    const code = res.statusCode || 0;
                    const loc = res.headers.location;
                    if (code >= 300 && code < 400 && loc && redirects > 0) {
                        let next = null;
                        try { next = new URLCtor(loc, url).toString(); } catch (e) {}
                        if (next) { once(next, opts, redirects - 1).then(resolve, reject); return; }
                    }
                    const raw = Buffer.concat(chunks);
                    const buf = unpack(raw, String(res.headers['content-encoding'] || '').toLowerCase());
                    const hdrs = {
                        get: (k) => {
                            const v = res.headers[String(k).toLowerCase()];
                            return Array.isArray(v) ? v.join(', ') : (v == null ? null : String(v));
                        },
                        forEach: (fn) => Object.keys(res.headers).forEach((k) => fn(String(res.headers[k]), k))
                    };
                    resolve({
                        ok: code >= 200 && code < 300,
                        status: code,
                        statusText: res.statusMessage || '',
                        headers: hdrs,
                        url: url,
                        redirected: false,
                        text: () => Promise.resolve(buf.toString('utf8')),
                        json: () => Promise.resolve(JSON.parse(buf.toString('utf8'))),
                        arrayBuffer: () => Promise.resolve(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength))
                    });
                });
            });
            req.on('error', reject);
            req.setTimeout(20000, () => req.destroy(new Error('fetch shim: timeout')));
            if (opts.signal) {
                const sig = opts.signal;
                if (sig.aborted) { req.destroy(new Error('fetch shim: aborted')); return; }
                if (typeof sig.addEventListener === 'function') {
                    sig.addEventListener('abort', () => req.destroy(new Error('fetch shim: aborted')), { once: true });
                }
            }
            const b = opts.body;
            if (b !== null && b !== undefined) {
                if (typeof b === 'string' || Buffer.isBuffer(b)) req.write(b);
                else req.write(String(b));
            }
            req.end();
        });
    }

    globalThis.fetch = function (input, init) {
        init = init || {};
        let url, opts;
        if (typeof input === 'string' || (URLCtor && input instanceof URLCtor)) {
            url = String(input);
            opts = { method: init.method || 'GET', headers: init.headers, body: init.body, signal: init.signal };
        } else if (input && input.url) {
            url = String(input.url);
            opts = {
                method: init.method || input.method || 'GET',
                headers: init.headers || input.headers,
                body: init.body !== undefined ? init.body : input.body,
                signal: init.signal || input.signal
            };
        } else {
            return Promise.reject(new TypeError('fetch shim: unsupported input'));
        }
        return once(url, opts, 5);
    };
    log('fetch shim: installed (WebAssembly missing → http/https fallback)');
    writeShim(true, false);
})();

process.on('uncaughtException', (e) => {
    log('FATAL uncaught: ' + (e && e.stack ? e.stack : String(e)));
});
process.on('unhandledRejection', (e) => {
    const msg = e && e.stack ? e.stack : String(e);
    // 1.8.8：装了 shim 后仍会出现一次 WebAssembly ReferenceError —— 那是 Node
    // 内置 undici 模块加载期 lazyllhttp() 的 rejected Promise，与业务 fetch 无关，
    // 服务照样 READY / config 秒回。只留首 3 行，别让 10 行栈帧又把关键行
    // 窗口占满（BF2：高频噪声会吃掉低频关键事件的视野）。
    if (msg.indexOf('WebAssembly') >= 0) {
        log('WARN fetch-shim: ' + msg.split('\n').slice(0, 3).join(' | '));
    } else {
        log('FATAL unhandled: ' + msg);
    }
});
// 1.8.5：Node 与 App 同进程。若 Node 事件循环退出 / V8 abort，会带走整个 App，
// 所以要把「正常退出」也记下来，用于和「崩溃」区分。
process.on('exit', (code) => { log('EXIT code=' + code); });

(async () => {
    let mod;
    // 1.7.2：优先用从「md5 索引地址」下载来的远程 bundle（remote.js），
    // 没有才回落到 App 内置的 index.js。
    const REMOTE = path.join(DIR, 'remote.js');
    const LOCAL = path.join(DIR, 'index.js');
    let entry = LOCAL;
    try {
        if (fs.existsSync(REMOTE) && fs.statSync(REMOTE).size > 1000000) {
            entry = REMOTE;
        }
    } catch (e) { /* 读不到就用内置 */ }

    try {
        log('loading ' + entry + ' ...');
        mod = require(entry);
        log('bundle loaded from ' + path.basename(entry) + ', exports=' + Object.keys(mod || {}).join(','));
    } catch (e) {
        log('FATAL require(' + path.basename(entry) + '): ' + (e && e.stack ? e.stack : String(e)));
        // 远程 bundle 加载失败时回落到内置，避免整个源不可用
        if (entry !== LOCAL) {
            try {
                log('fallback to builtin index.js');
                mod = require(LOCAL);
                // 1.7.6：回落成功就把 entry 改回内置，否则下面 kernel.txt 会
                // 把「实际跑的内置」误记成「远程」—— 那正是用户在问的那件事。
                entry = LOCAL;
                log('builtin bundle loaded, exports=' + Object.keys(mod || {}).join(','));
            } catch (e2) {
                log('FATAL require(builtin): ' + (e2 && e2.stack ? e2.stack : String(e2)));
                return;
            }
        } else {
            return;
        }
    }

    // 1.7.6：把「这次到底加载了哪一份内核」写成文件，供 App 的「源内核」区直接显示。
    // 用户最想知道的一件事就是：我填的那个链接到底生效了没有。
    // 注意它记录的是**当前进程真正加载的**那份，不是刚下载的那份。
    try {
        const crypto = require('crypto');
        const buf = fs.readFileSync(entry);
        const md5 = crypto.createHash('md5').update(buf).digest('hex');
        fs.writeFileSync(path.join(DIR, 'kernel.txt'), JSON.stringify({
            source: path.basename(entry),
            bytes: buf.length,
            md5: md5,
            at: new Date().toISOString()
        }), 'utf8');
        log('kernel.txt: ' + path.basename(entry) + ' ' + buf.length + 'B md5=' + md5);
    } catch (e) {
        log('kernel.txt write failed: ' + (e && e.message ? e.message : String(e)));
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

// 1.7.7：V8 撞到堆上限是进程级 abort，JS 里连 catch 都拿不到 ——
// 所以要在逼近上限之前留下密集证据。
// 1.8.5：改成**每 10 秒无条件写一行**（mem10），不再只在偏高时写。
// 播放中稳定闪退两次，需要一条完整的 V8/RSS 曲线才能判断是不是 Node 拖垮了进程；
// 同时在偏高时主动 full GC（NodeRuntime 已加 --expose-gc），降低与视频缓冲的叠加。
setInterval(() => {
    try {
        const m = process.memoryUsage();
        const heapMB = Math.round(m.heapUsed / 1048576);
        const rssMB = Math.round(m.rss / 1048576);
        log('mem10 heap=' + heapMB + 'MB rss=' + rssMB + 'MB'
            + ' total=' + Math.round(m.heapTotal / 1048576) + 'MB'
            + ' ext=' + Math.round(m.external / 1048576) + 'MB');
        if (heapMB > 96 || rssMB > 260) {
            let after = heapMB;
            if (typeof global.gc === 'function') {
                try { global.gc(); } catch (e) { /* 没开 expose-gc 就算了 */ }
                after = Math.round(process.memoryUsage().heapUsed / 1048576);
            }
            log('mem HIGH heap ' + heapMB + '->' + after + 'MB rss=' + rssMB + 'MB'
                + ' gc=' + (typeof global.gc === 'function' ? 'yes' : 'no'));
        }
    } catch (e) { /* 忽略 */ }
}, 10000).unref();

// 确保 flush 被引用（避免打包器优化掉）
flush();
