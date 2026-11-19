/**
 * dsh-whale-eyes — 给模型一只不截屏的眼睛。 0.3.0
 *
 * 做三件事：
 *   1. 确保屏幕守护进程（PowerShell + UI Automation）在跑，不截屏
 *   2. 注册 `screen_sight` 工具：把当前屏幕压成一份几十 token 的短摘要
 *   3. 认得自己那份脚本：端口上的 daemon 若脚本 hash 不符（旧版 / 别人那份），
 *      先让它退场再拉起，避免「装的是新的、跑的是旧的」
 *
 * 真正的采集逻辑在 runtime/daemon.ps1，这里只是壳。
 */

import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { closeSync, existsSync, openSync, readFileSync, statSync } from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RUNTIME = path.join(HERE, 'runtime');
const DAEMON = path.join(RUNTIME, 'daemon.ps1');
const DAEMON_LOG = path.join(RUNTIME, 'daemon.log');

const PORT_SPAN = 10;
const START_DEADLINE_FIRST_MS = 10_000; // 第一次（可能被 Defender 扫脚本拖慢）
const START_DEADLINE_RETRY_MS = 4_000; // 之后
const MAX_BACKOFF_MS = 60_000;

function readVersion() {
  try {
    const pkg = JSON.parse(readFileSync(path.join(HERE, 'package.json'), 'utf8'));
    return typeof pkg.version === 'string' ? pkg.version : '0.0.0';
  } catch {
    return '0.0.0';
  }
}

function hashFile(file) {
  try {
    return createHash('sha256').update(readFileSync(file)).digest('hex').toUpperCase();
  } catch {
    return '';
  }
}

const VERSION = readVersion();

// 脚本指纹按需算：只看 mtime，变了才重算。
// 这样开发期改 daemon.ps1 之后，插件下一次调用就会认出「端口上那个是旧的」，
// 不用重启 DSH 也能换掉它（早期版本把 hash 在模块加载时算死，改完文件它不知道）。
let hashCache = { mtime: -1, hash: '' };
function daemonHash() {
  try {
    const st = statSync(DAEMON);
    if (st.mtimeMs !== hashCache.mtime) {
      hashCache = { mtime: st.mtimeMs, hash: hashFile(DAEMON) };
    }
    return hashCache.hash;
  } catch {
    return '';
  }
}

export const name = 'whale-eyes';

/** 只需要工具注册表；没有 tools 的 profile 里这个插件就安静地不生效。 */
export const inject = ['tools'];

let readyPort = null;
let starting = null;
let everStarted = false;

// 本机调用方凭据：每次拉起 daemon 现生成，通过命令行传入；daemon 会把它写进
// runtime/daemon.token，插件采纳「已经跑着的那份」时从文件读回。
// 说明：同用户进程可读该文件，所以它挡的是「别的软件顺手调用」，不是同用户恶意进程。
const TOKEN_FILE = path.join(RUNTIME, 'daemon.token');
let token = null;

function loadToken() {
  try {
    const v = readFileSync(TOKEN_FILE, 'utf8').trim();
    token = v || null;
  } catch {
    token = null;
  }
  return token;
}

// 失败退避：1 → 2 → 4 → … → 60s。守护进程一时起不来时，别让每次调用都等满超时。
let failures = 0;
let nextTryAt = 0;

function backoffMs() {
  return Math.min(MAX_BACKOFF_MS, 1000 * 2 ** Math.max(0, failures - 1));
}

function noteFailure() {
  failures += 1;
  nextTryAt = Date.now() + backoffMs();
}

function noteSuccess() {
  failures = 0;
  nextTryAt = 0;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** 主机进程的 PATH 未必包含 PowerShell，优先按绝对路径找。 */
function resolvePowerShell() {
  const root = process.env.SystemRoot || process.env.windir || 'C:\\Windows';
  const absolute = path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  return existsSync(absolute) ? absolute : 'powershell.exe';
}

/** 一行 JSON 请求，一行 JSON 应答。 */
function rpc(port, payload, timeoutMs = 4000) {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection({ host: '127.0.0.1', port });
    let buf = '';
    let settled = false;
    const settle = (fn, value) => {
      if (settled) return;
      settled = true;
      sock.destroy();
      fn(value);
    };
    sock.setEncoding('utf8');
    sock.setTimeout(timeoutMs, () => {
      settle(reject, new Error(`screen daemon timeout: ${timeoutMs}ms on port ${port}`));
    });
    sock.on('connect', () => sock.write(`${JSON.stringify(payload)}\n`));
    sock.on('data', (chunk) => {
      buf += chunk;
      const nl = buf.indexOf('\n');
      if (nl === -1) return;
      try {
        settle(resolve, JSON.parse(buf.slice(0, nl)));
      } catch (err) {
        settle(reject, err);
      }
    });
    sock.on('error', (err) => settle(reject, err));
  });
}

/** 只认「脚本 hash 对得上」的 daemon；hash 缺失（0.1.x）也算不认识。 */
async function pingInfo(port, timeoutMs = 700) {
  try {
    const res = await rpc(port, { op: 'ping' }, timeoutMs);
    if (!res || res.ok !== true) return null;
    return res;
  } catch {
    return null;
  }
}

function hashMatches(res) {
  const want = daemonHash();
  if (!res || !want) return false;
  return typeof res.sha256 === 'string' && res.sha256.toUpperCase() === want;
}

/** 守护进程自己的控制台输出（出错时才有人看）。 */
function daemonLogTail(max = 800) {
  try {
    if (!existsSync(DAEMON_LOG)) return '(no daemon log)';
    const text = readFileSync(DAEMON_LOG, 'utf8');
    return text.length > max ? `…${text.slice(-max)}` : text;
  } catch {
    return '(unreadable daemon log)';
  }
}

/** 让一份「不是自己」的 daemon 退场，别占着端口用旧代码应答。 */
async function retire(port) {
  try {
    await rpc(port, { op: 'stop', token }, 1500);
  } catch {
    /* 停不掉也无所谓，后面靠端口后移 */
  }
  await sleep(250);
}

function spawnDaemon(basePort) {
  let fd = 'ignore';
  try {
    fd = openSync(DAEMON_LOG, 'a');
  } catch {
    /* 日志打不开也照常启动 */
  }
  token = randomBytes(16).toString('hex');
  // 注意：这里**不能**用 detached。实测本环境里 detached 子进程会立刻 exit=0 退出。
  const child = spawn(
    resolvePowerShell(),
    [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      DAEMON,
      '-Port',
      String(basePort),
      '-Version',
      VERSION,
      '-Token',
      token,
    ],
    { cwd: RUNTIME, stdio: ['ignore', fd, fd], windowsHide: true },
  );
  child.unref();
  if (typeof fd === 'number') {
    try {
      closeSync(fd);
    } catch {
      /* ignore */
    }
  }

  let spawnError = null;
  child.on('error', (err) => {
    spawnError = err;
  });
  return { child, spawnError: () => spawnError };
}

/**
 * 拉起一个守护进程，并用 ping 握手判断「就绪」，而不是靠固定 sleep。
 * 6s 的意义是「多久没就绪」，不是「多久没起来」。
 */
async function startDaemon(basePort) {
  if (!existsSync(DAEMON)) throw new Error(`screen daemon script missing: ${DAEMON}`);

  const { child, spawnError } = spawnDaemon(basePort);
  const deadline = Date.now() + (everStarted ? START_DEADLINE_RETRY_MS : START_DEADLINE_FIRST_MS);

  while (Date.now() < deadline) {
    await sleep(120);
    for (let port = basePort; port < basePort + PORT_SPAN; port++) {
      const info = await pingInfo(port, 500);
      if (info && hashMatches(info)) {
        everStarted = true;
        return port;
      }
    }
    const err = spawnError();
    if (err) throw new Error(`cannot start PowerShell (${err.message})`);
    if (child.exitCode !== null) {
      throw new Error(`screen daemon exited with code ${child.exitCode}; log: ${daemonLogTail()}`);
    }
  }
  try {
    child.kill();
  } catch {
    /* ignore */
  }
  throw new Error(
    `screen daemon not ready within ${everStarted ? START_DEADLINE_RETRY_MS : START_DEADLINE_FIRST_MS}ms (port ${basePort}); log: ${daemonLogTail()}`,
  );
}

/**
 * 兜底：没有守护进程时直接跑一次性采集（约 1~2.5 秒），
 * 慢，但不会因为守护进程起不来就完全失明。
 */
function runOnce(budget, values) {
  return new Promise((resolve, reject) => {
    const extra = values ? ['-Values'] : [];
    const child = spawn(
      resolvePowerShell(),
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        DAEMON,
        '-Once',
        '-Budget',
        String(budget),
        '-Version',
        VERSION,
        ...extra,
      ],
      { cwd: RUNTIME, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] },
    );
    let out = '';
    let err = '';
    const timer = setTimeout(() => {
      try {
        child.kill();
      } catch {
        /* ignore */
      }
      reject(new Error('one-shot screen read timed out'));
    }, 15_000);
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      out += chunk;
    });
    child.stderr.on('data', (chunk) => {
      err += chunk;
    });
    child.on('error', (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (code !== 0) {
        reject(new Error(`one-shot read failed (code ${code}): ${err.trim().slice(0, 300)}`));
        return;
      }
      const line = out.trim().split(/\r?\n/).pop() || '';
      try {
        const parsed = JSON.parse(line);
        if (parsed && parsed.ok === false) {
          reject(new Error(`one-shot read failed: ${parsed.error || 'unknown'}`));
          return;
        }
        resolve(parsed);
      } catch {
        reject(new Error(`one-shot read returned unparsable output: ${line.slice(0, 200)}`));
      }
    });
  });
}

async function ensureDaemon(basePort) {
  // 已认过的那份：给足 1.5s 再判。单线程 daemon 在 digest/region/pages 期间答不了 ping，
  // 600ms 就判死会「杀掉正确、只是正忙」的那份（0.2.2 复核 ③1）。
  if (readyPort !== null) {
    const info = await pingInfo(readyPort, 1500);
    if (info && hashMatches(info)) {
      if (token === null) loadToken();
      return readyPort;
    }
    readyPort = null;
  }

  // 扫描端口：认得自己的才采纳；有应答但指纹不符的，才请它退场（超时不算不符）
  for (let port = basePort; port < basePort + PORT_SPAN; port++) {
    const info = await pingInfo(port, 800);
    if (!info) continue;
    if (hashMatches(info)) {
      readyPort = port;
      loadToken();
      noteSuccess();
      return port;
    }
    loadToken();
    await retire(port);
  }

  if (Date.now() < nextTryAt) {
    const left = Math.ceil((nextTryAt - Date.now()) / 1000);
    throw new Error(`screen daemon in backoff (${left}s left after ${failures} failures)`);
  }

  if (!starting) {
    starting = startDaemon(basePort)
      .then((port) => {
        readyPort = port;
        noteSuccess();
        return port;
      })
      .catch((err) => {
        noteFailure();
        throw err;
      })
      .finally(() => {
        starting = null;
      });
  }
  return starting;
}

function oneLine(value, max) {
  const text = String(value ?? '').replace(/\s+/g, ' ').trim();
  if (!max || text.length <= max) return text;
  return `${text.slice(0, max - 1)}…`;
}

/**
 * 把守护进程的结构化摘要压成几行字。
 * @param {{app?: string, title?: string, focus?: {role?: string, name?: string, value?: string}, wins?: string[]}} digest
 * @returns {string} 模型看到的那段文字
 */
function formatDigest(digest) {
  if (!digest || typeof digest !== 'object') return 'no screen state available';
  const app = oneLine(digest.app, 40);
  if (!app) return 'no screen state available';
  if (app === '[blocked]') return '[blocked]';

  const lines = [`app: ${app}`];
  const title = oneLine(digest.title, 70);
  if (title) lines.push(`win: ${title}`);

  const focus = digest.focus;
  if (focus && typeof focus === 'object') {
    const bits = [];
    if (focus.role) bits.push(oneLine(focus.role, 24));
    if (focus.name) bits.push(`"${oneLine(focus.name, 40)}"`);
    if (focus.value) bits.push(`= ${oneLine(focus.value, 60)}`);
    if (bits.length > 0) lines.push(`focus: ${bits.join(' ')}`);
  }

  const wins = Array.isArray(digest.wins)
    ? digest.wins.map((w) => oneLine(w, 30)).filter((w) => w.length > 0)
    : [];
  if (wins.length > 0) lines.push(`wins: ${wins.slice(0, 5).join(' | ')}`);

  return lines.join('\n');
}

const DESCRIPTION = [
  'Look at what the user is looking at right now on their Windows desktop, without screenshots:',
  'foreground app, window title, focused control, and the other open windows, as a short summary.',
  "Use it when the user refers to something on their screen ('this', 'my screen', 'what do you see') or when their current app would change your answer;",
  'skip it otherwise. The text inside a text box is only read when you pass include_text:true;',
  'password fields are never read, and windows belonging to known password managers are left out of the list.',
].join(' ');

/**
 * @param {import('cordis').Context} ctx
 * @param {{port?: number, budget?: number}} [config]
 */
export function apply(ctx, config = {}) {
  const basePort = Number(config?.port) || 8791;
  const defaultBudget = Number(config?.budget) || 220;

  ctx.effect(() => {
    const dispose = ctx.tools.register({
      name: 'screen_sight',
      description: DESCRIPTION,
      parameters: {
        type: 'object',
        additionalProperties: false,
        properties: {
          budget: {
            type: 'integer',
            minimum: 25,
            maximum: 400,
            description:
              'Summary size in tokens: 25 = app and title only, 60 = adds the focused control, 220 = adds the other open windows. Default 220.',
          },
          include_text: {
            type: 'boolean',
            description:
              'Also read the text currently inside the focused text box. Off by default; only ask for it when that text actually matters.',
          },
        },
      },
      output: {
        schema: {
          type: 'object',
          additionalProperties: false,
          properties: { summary: { type: 'string' } },
          required: ['summary'],
        },
        render: (_args, value) => [{ type: 'text', text: value?.summary ?? '(no screen state)' }],
      },
      isConcurrencySafe: () => true,
      async execute(args) {
        const raw = Number(args?.budget);
        const budget = Number.isFinite(raw) ? Math.min(400, Math.max(25, Math.round(raw))) : defaultBudget;
        const values = args?.include_text === true;

        let res = null;
        try {
          const port = await ensureDaemon(basePort);
          res = await rpc(port, { op: 'digest', budget, values, token }, 4000);
        } catch {
          // 守护进程那条路过不去（起不来 / 半路死了 / 在退避期），退回一次性采集
          res = await runOnce(budget, values);
        }
        if (!res || res.ok !== true) {
          throw new Error(`screen read failed: ${(res && res.error) || 'no response'}`);
        }
        return { summary: formatDigest(res.digest) };
      },
      presentCall: () => ({ card: 'generic', title: 'Look at the screen', kind: 'other' }),
    });

    // 挂载后台把守护进程暖起来，别等第一次调用时才等它
    void ensureDaemon(basePort).catch((err) => {
      console.warn('[whale-eyes] screen daemon unavailable:', err && err.message ? err.message : err);
    });

    // 卸载/禁用插件时把我们拉起的那份也收走：否则 DSH 退了它还常驻（107MB / 0.5%）
    return () => {
      const port = readyPort;
      readyPort = null;
      if (port !== null) {
        void rpc(port, { op: 'stop', token }, 1200).catch(() => {});
      }
      dispose();
    };
  }, 'whale-eyes tool');
}
