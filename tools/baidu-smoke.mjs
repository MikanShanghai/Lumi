#!/usr/bin/env node
/**
 * 百度网盘直连播放 · 冒烟测试（M0 验证脚本）
 *
 * 用途：用你自己的百度账号，跑通「授权 → 列文件 → 拿播放地址 → 播放」全链路，
 *       验证开放平台权限与限速情况。对应 App 里未来的 BaiduProvider + StreamProxy。
 *
 * 准备：
 *   1. 在百度网盘开放平台控制台拿到 AppKey / SecretKey
 *   2. 在本目录建 .env 文件（已被 .gitignore 忽略，不会提交）：
 *        BAIDU_APP_KEY=你的AppKey
 *        BAIDU_APP_SECRET=你的SecretKey
 *
 * 用法：
 *   node tools/baidu-smoke.mjs login              # 设备码授权（浏览器/扫码，自动轮询）
 *   node tools/baidu-smoke.mjs ls /               # 列出目录全部内容（含文件夹）
 *   node tools/baidu-smoke.mjs list /             # 列出目录（标出视频文件）
 *   node tools/baidu-smoke.mjs search 星际         # 搜索
 *   node tools/baidu-smoke.mjs play "/电影/x.mkv"  # 拿 dlink 并做 Range 测试
 *   node tools/baidu-smoke.mjs play "/电影/x.mkv" --proxy --open
 *                                                  # 起本地代理（注入 UA）→ 用播放器打开
 *
 * 参考文档（来自百度官方 Go SDK 源码注释）：
 *   设备码授权 https://pan.baidu.com/union/doc/al0rwqzzl
 *   文件列表   https://pan.baidu.com/union/doc/nksg0sat9
 *   下载元信息 https://pan.baidu.com/union/doc/pkuo3snyp
 */
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ENV_FILE = path.join(HERE, '.env');
const TOKEN_FILE = path.join(HERE, '.baidu-token.json');

const OAUTH = 'https://openapi.baidu.com';
const PAN = 'https://pan.baidu.com';
// 播放/下载 dlink 时百度有两条硬性要求（否则 403）：
//   1) URL 上必须带 access_token=xxx（filemetas 返回的 dlink 里不含，要手动拼）
//   2) 请求头必须带 User-Agent: pan.baidu.com
// 这两条就是 App 里 StreamProxy 存在的原因：播放器自己不会做这些。
const DOWNLOAD_UA = 'pan.baidu.com';
const PROXY_PORT = 8787;

// ---------- 基础工具 ----------

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const die = (msg) => { console.error('\n❌ ' + msg); process.exit(1); };
const fmtSize = (n) => n >= 1 << 30 ? (n / (1 << 30)).toFixed(2) + ' GB' : n >= 1 << 20 ? (n / (1 << 20)).toFixed(1) + ' MB' : (n / 1024).toFixed(0) + ' KB';

function loadEnv() {
  const out = {};
  if (fs.existsSync(ENV_FILE)) {
    for (const line of fs.readFileSync(ENV_FILE, 'utf8').split('\n')) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.+?)\s*$/);
      if (m) out[m[1]] = m[2];
    }
  }
  return out;
}

const env = { ...loadEnv(), ...process.env };
const APP_KEY = env.BAIDU_APP_KEY;
const APP_SECRET = env.BAIDU_APP_SECRET;

function requireKeys() {
  if (!APP_KEY || !APP_SECRET) {
    die('缺少 BAIDU_APP_KEY / BAIDU_APP_SECRET。\n  请在 ' + ENV_FILE + ' 中配置（该文件不会提交到 git）。');
  }
}

async function getJSON(url) {
  const r = await fetch(url, { headers: { 'User-Agent': 'pan.baidu.com' } });
  const t = await r.text();
  try { return JSON.parse(t); } catch { return { errno: -999, raw: t.slice(0, 400), httpStatus: r.status }; }
}

// ---------- 授权 ----------

function saveToken(tok) {
  fs.writeFileSync(TOKEN_FILE, JSON.stringify(tok, null, 2), { mode: 0o600 });
}

function loadToken() {
  if (!fs.existsSync(TOKEN_FILE)) return null;
  try { return JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf8')); } catch { return null; }
}

async function login() {
  requireKeys();
  const dc = await getJSON(
    `${OAUTH}/oauth/2.0/device/code?response_type=device_code&client_id=${encodeURIComponent(APP_KEY)}&scope=basic,netdisk`
  );
  if (!dc.device_code) die('获取设备码失败：' + JSON.stringify(dc));

  console.log('\n请完成授权（两种任选其一）：');
  console.log('  ① 浏览器打开：' + dc.verification_url);
  console.log('     输入验证码：' + dc.user_code);
  console.log('  ② 或扫码：' + dc.qrcode_url + '\n');
  console.log('正在等待授权', dc.expires_in ? `（${Math.round(dc.expires_in / 60)} 分钟内有效）` : '');

  const interval = Math.max(2, dc.interval || 5) * 1000;
  const deadline = Date.now() + (dc.expires_in || 300) * 1000;
  while (Date.now() < deadline) {
    await sleep(interval);
    const tj = await getJSON(
      `${OAUTH}/oauth/2.0/token?grant_type=device_token&code=${encodeURIComponent(dc.device_code)}` +
      `&client_id=${encodeURIComponent(APP_KEY)}&client_secret=${encodeURIComponent(APP_SECRET)}`
    );
    if (tj.access_token) {
      saveToken({ access_token: tj.access_token, refresh_token: tj.refresh_token, expiry: Date.now() + (tj.expires_in || 2592000) * 1000 });
      console.log('\n✅ 授权成功，token 已保存到 ' + TOKEN_FILE + '（已 gitignore）');
      return;
    }
    if (tj.error === 'authorization_pending') { process.stdout.write('.'); continue; }
    die('授权失败：' + (tj.error_description || tj.error || JSON.stringify(tj)));
  }
  die('授权超时，请重新运行 login');
}

async function ensureToken() {
  requireKeys();
  let tok = loadToken();
  if (!tok) die('还没有授权。先运行：node tools/baidu-smoke.mjs login');
  if (tok.expiry && Date.now() < tok.expiry - 60_000) return tok;

  console.log('（token 已过期，自动刷新…）');
  const tj = await getJSON(
    `${OAUTH}/oauth/2.0/token?grant_type=refresh_token&refresh_token=${encodeURIComponent(tok.refresh_token)}` +
    `&client_id=${encodeURIComponent(APP_KEY)}&client_secret=${encodeURIComponent(APP_SECRET)}`
  );
  if (!tj.access_token) die('刷新失败，请重新 login：' + JSON.stringify(tj));
  tok = { access_token: tj.access_token, refresh_token: tj.refresh_token || tok.refresh_token, expiry: Date.now() + (tj.expires_in || 2592000) * 1000 };
  saveToken(tok);
  return tok;
}

// ---------- 文件浏览 ----------

const CATEGORY = { 1: '视频', 2: '音频', 3: '图片', 4: '文档', 5: '应用', 6: '其他', 7: '种子' };

async function listDir(dir) {
  const tok = await ensureToken();
  const j = await getJSON(
    `${PAN}/rest/2.0/xpan/file?method=list&access_token=${encodeURIComponent(tok.access_token)}` +
    `&dir=${encodeURIComponent(dir)}&order=name&limit=1000`
  );
  if (j.errno !== 0) die(`列出目录失败 errno=${j.errno}：` + JSON.stringify(j).slice(0, 300));
  const items = j.list || [];
  const videos = items.filter((f) => f.category === 1 && !f.isdir);
  console.log(`\n${dir}  共 ${items.length} 项，其中视频 ${videos.length} 个：\n`);
  for (const f of videos) {
    console.log(`  ${f.isdir ? '📁' : '🎬'} ${f.server_filename}`);
    console.log(`      ${fmtSize(f.size)}  fs_id=${f.fs_id}  ${f.path}`);
  }
  const others = items.length - videos.length;
  if (others > 0) console.log(`  （另有 ${others} 个非视频项未列出，可改脚本查看）`);
  return videos;
}

async function search(key) {
  const tok = await ensureToken();
  const j = await getJSON(
    `${PAN}/rest/2.0/xpan/file?method=search&access_token=${encodeURIComponent(tok.access_token)}` +
    `&key=${encodeURIComponent(key)}&recursion=1&limit=1000`
  );
  if (j.errno !== 0) die(`搜索失败 errno=${j.errno}：` + JSON.stringify(j).slice(0, 300));
  for (const f of j.list || []) {
    console.log(`  ${f.isdir ? '📁' : '🎬'} ${f.server_filename}  ${f.isdir ? '' : fmtSize(f.size)}  ${f.path}`);
  }
}

async function lsDir(dir) {
  const tok = await ensureToken();
  const j = await getJSON(
    `${PAN}/rest/2.0/xpan/file?method=list&access_token=${encodeURIComponent(tok.access_token)}` +
    `&dir=${encodeURIComponent(dir)}&order=name&limit=1000`
  );
  if (j.errno !== 0) die(`列出目录失败 errno=${j.errno}：` + JSON.stringify(j).slice(0, 300));
  const items = j.list || [];
  console.log(`\n${dir} 共 ${items.length} 项：`);
  for (const f of items) {
    if (f.isdir) console.log(`  📁 ${f.server_filename}`);
    else console.log(`  📄 ${f.server_filename}  ${fmtSize(f.size)}  [${CATEGORY[f.category] || '文件'}]`);
  }
  return items;
}

// ---------- 播放地址 ----------

async function resolveFile(target) {
  // 支持传入完整路径（/目录/文件名）
  const dir = path.posix.dirname(target);
  const name = path.posix.basename(target);
  const videos = await listDir(dir);
  const hit = videos.find((f) => f.server_filename === name);
  if (!hit) die(`在 ${dir} 下没找到「${name}」`);
  return hit;
}

async function getDlink(fsId) {
  const tok = await ensureToken();
  const j = await getJSON(
    `${PAN}/rest/2.0/xpan/multimedia?method=filemetas&dlink=1&access_token=${encodeURIComponent(tok.access_token)}` +
    `&fsids=[${fsId}]`
  );
  if (j.errno !== 0 || !j.list || !j.list[0]) die(`获取 dlink 失败 errno=${j.errno}：` + JSON.stringify(j).slice(0, 300));
  const info = j.list[0];
  const url = info.dlink.includes('access_token=')
    ? info.dlink
    : info.dlink + (info.dlink.includes('?') ? '&' : '?') + 'access_token=' + encodeURIComponent(tok.access_token);
  return { info, url };
}

async function rangeTest(url) {
  const r = await fetch(url, {
    headers: { 'User-Agent': DOWNLOAD_UA, Range: 'bytes=0-262143' },
    redirect: 'follow',
  });
  const ok = r.status === 206 || r.status === 200;
  const buf = ok ? Buffer.from(await r.arrayBuffer()) : Buffer.alloc(0);
  console.log(`\nRange 测试：HTTP ${r.status}${ok ? ' ✅' : ' ❌'}  收到 ${fmtSize(buf.length)}`);
  console.log(`Content-Type: ${r.headers.get('content-type')}`);
  console.log(`Content-Range: ${r.headers.get('content-range') || '(无)'}`);
  return { ok, finalUrl: r.url };
}

function startProxy(url) {
  const server = http.createServer(async (req, res) => {
    try {
      const headers = { 'User-Agent': DOWNLOAD_UA };
      if (req.headers.range) headers.Range = req.headers.range;
      const up = await fetch(url, { headers, redirect: 'follow' });
      res.writeHead(up.status, {
        'Content-Type': up.headers.get('content-type') || 'application/octet-stream',
        'Content-Length': up.headers.get('content-length') || undefined,
        'Content-Range': up.headers.get('content-range') || undefined,
        'Accept-Ranges': 'bytes',
      });
      if (req.method === 'HEAD') return res.end();
      Readable.fromWeb(up.body).pipe(res);
    } catch (e) {
      res.writeHead(502); res.end('proxy error: ' + e.message);
    }
  });
  return new Promise((resolve) => server.listen(PROXY_PORT, '127.0.0.1', () => resolve(server)));
}

async function play(target, opts) {
  const file = await resolveFile(target);
  console.log(`\n文件：${file.server_filename}（${fmtSize(file.size)}）`);
  const { url } = await getDlink(file.fs_id);
  console.log('dlink 已获取（有效期 8 小时，播放前实时获取即可）');
  await rangeTest(url);

  if (opts.proxy) {
    await startProxy(url);
    const proxyUrl = `http://127.0.0.1:${PROXY_PORT}/stream`;
    console.log(`\n🚀 本地代理已启动：${proxyUrl}`);
    console.log('   任何播放器都可以直接打开它（代理会注入百度要求的 UA）');
    if (opts.open) {
      try {
        execFileSync('open', ['-a', 'Infuse', proxyUrl]);
        console.log('   已尝试用 Infuse 打开');
      } catch {
        try { execFileSync('open', ['-a', 'QuickTime Player', proxyUrl]); console.log('   已尝试用 QuickTime 打开'); }
        catch (e) { console.log('   自动打开失败，请手动把上面的地址粘进播放器'); }
      }
    }
    console.log('   按 Ctrl+C 结束代理\n');
  } else {
    console.log('\n提示：直接用浏览器/播放器打开 dlink 可能 403（百度校验 UA），');
    console.log('      加 --proxy 会起一个本地代理帮你注入 UA，再用播放器打开。');
  }
}

// ---------- 入口 ----------

const [cmd, arg1, ...rest] = process.argv.slice(2);
const flags = new Set(rest);

if (!cmd || cmd === 'help' || cmd === '--help') {
  console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('*/')[0].split('/**')[1]);
  process.exit(0);
}

if (cmd === 'login') await login();
else if (cmd === 'ls') { await lsDir(arg1 || '/'); }
else if (cmd === 'list') { await listDir(arg1 || '/'); }
else if (cmd === 'search') { if (!arg1) die('用法：search <关键词>'); await search(arg1); }
else if (cmd === 'play') {
  if (!arg1) die('用法：play "/目录/文件名.mkv" [--proxy] [--open]');
  await play(arg1, { proxy: flags.has('--proxy'), open: flags.has('--open') });
} else {
  die(`未知命令：${cmd}（可用：login / ls / list / search / play）`);
}
