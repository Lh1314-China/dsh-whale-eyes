/**
 * dsh-whale-eyes — 给模型一只不截屏的眼睛。
 *
 * 做三件事：
 *   1. 确保屏幕守护进程（PowerShell + UI Automation）在跑，不截屏
 *   2. 注册 `screen_sight` 工具：把当前屏幕压成一份 50~130 token 的短摘要
 *   3. 卸载时只摘掉自己的注册，不碰守护进程（它可能是别人起的）
 *
 * 真正的采集逻辑在 runtime/daemon.ps1，这里只是壳。
 */

import { spawn } from 'node:child_process';
import { closeSync, existsSync, openSync, readFileSync } from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const RUNTIME = path.join(HERE, 'runtime');
const DAEMON = path.join(RUNTIME, 'daemon.ps1');
const PORT_FILE = path.join(RUNTIME, 'port.txt');

const PORT_SPAN = 10;
const START_TIMEOUT_MS = 12_000;

export const name = 'whale-eyes';

/** 只需要工具注册表；没有 tools 的 profile 里这个插件就安静地不生效。 */
export const inject = ['tools'];

let readyPort = null;
let starting = null;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** 主机进程的 PATH 未必包含 PowerShell，优先按绝对路径找。 */
function resolvePowerShell() {
  const root = process.env.SystemRoot || process.env.windir || 'C:\\Windows';
  const absolute = path.join(root, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  return existsSync(absolute) ? absolute : 'powershell.exe';
}

/** 守护进程会把实际端口写在自己目录的 port.txt 里。 */
function readPort(fallback) {
  try {
    if (existsSync(PORT_FILE)) {
      const v = readFileSync(PORT_FILE, 'utf8').trim();
      if (/^\d+$/.test(v)) return Number(v);
    }
  } catch {
    /* 读不到就用默认端口 */
  }
  return fallback;
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

async function ping(port) {
  try {
    const res = await rpc(port, { op: 'ping' }, 700);
    return res !== null && typeof res === 'object' && res.ok === true;
  } catch {
    return false;
  }
}

const DAEMON_LOG = path.join(RUNTIME, 'daemon.log');

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

/** 只在确实没有守护进程时才拉起一个，避免同机跑两个 UIA 轮询器。 */
async function startDaemon(basePort) {
  if (!existsSync(DAEMON)) throw new Error(`screen daemon script missing: ${DAEMON}`);

  let fd = 'ignore';
  try {
    fd = openSync(DAEMON_LOG, 'a');
  } catch {
    /* 日志打不开也照常启动 */
  }
  const child = spawn(
    resolvePowerShell(),
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', DAEMON, '-Port', String(basePort)],
    { cwd: RUNTIME, detached: true, stdio: ['ignore', fd, fd], windowsHide: true },
  );
  child.unref();
  if (typeof fd === 'number') {
    try {
      closeSync(fd);
    } catch {
      /* ignore */
    }
  }

  // spawn 失败（解释器找不到、被安全软件拦下）不会抛，只会发一个 error 事件
  let spawnError = null;
  child.on('error', (err) => {
    spawnError = err;
  });

  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await sleep(250);
    const port = readPort(basePort);
    if (await ping(port)) return port;
    if (spawnError) throw new Error(`cannot start PowerShell (${spawnError.message})`);
    if (child.exitCode !== null) {
      throw new Error(`screen daemon exited with code ${child.exitCode}; log: ${daemonLogTail()}`);
    }
  }
  try {
    child.kill();
  } catch {
    /* ignore */
  }
  throw new Error(`screen daemon silent for ${START_TIMEOUT_MS}ms (port ${basePort}); log: ${daemonLogTail()}`);
}

/**
 * 兜底：没有守护进程时直接跑一次性采集（约 1.5～2.5 秒），
 * 慢，但不会因为守护进程起不来就完全失明。
 */
function runOnce(budget) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      resolvePowerShell(),
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', DAEMON, '-Once', '-Budget', String(budget)],
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
        resolve(JSON.parse(line));
      } catch {
        reject(new Error(`one-shot read returned unparsable output: ${line.slice(0, 200)}`));
      }
    });
  });
}

async function ensureDaemon(basePort) {
  if (readyPort !== null && (await ping(readyPort))) return readyPort;
  readyPort = null;

  for (let port = basePort; port < basePort + PORT_SPAN; port++) {
    if (await ping(port)) {
      readyPort = port;
      return port;
    }
  }

  if (!starting) {
    starting = startDaemon(basePort)
      .then((port) => {
        readyPort = port;
        return port;
      })
      .finally(() => {
        starting = null;
      });
  }
  return starting;
}

function oneLine(value, max) {
  const text = String(value ?? '').replace(/\s+/g, ' ').trim();
  return max && text.length > max ? `${text.slice(0, max)}…` : text;
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
  "Look at what the user is looking at right now on their Windows desktop, without screenshots:",
  'foreground app, window title, focused control with its text, and the other open windows, as a short summary.',
  "Use it when the user refers to something on their screen ('this', 'my screen', 'what do you see') or when their current app would change your answer;",
  'skip it otherwise. Password fields and password managers are reported as redacted.',
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

        let res = null;
        try {
          const port = await ensureDaemon(basePort);
          res = await rpc(port, { op: 'digest', budget }, 4000);
        } catch {
          // 守护进程那条路过不去（起不来 / 半路死了），退回一次性采集
          res = await runOnce(budget);
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

    return dispose;
  }, 'whale-eyes tool');
}
