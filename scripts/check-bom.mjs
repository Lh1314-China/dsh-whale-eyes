// prepack 断言：runtime/*.ps1 必须 (1) 是 UTF-8 with BOM，(2) 能被 PowerShell 解析器读通。
//
// 起因（2026-11-16）：用不带 BOM 的编辑器重存 daemon.ps1 后，PowerShell 5.1 按 ANSI
// 读中文注释，某个字节把后面的引号吃掉，报错位置和真因差 100 行。复核又补了一刀：
// 只验 BOM 不够——BOM 齐全但语法坏的 ps1 照样能打包。所以这里再加一道解析器检查。

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';

const root = process.cwd();
const runtime = path.join(root, 'runtime');

const files = [];
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const p = path.join(dir, name);
    const s = statSync(p);
    if (s.isDirectory()) walk(p);
    else if (name.endsWith('.ps1')) files.push(p);
  }
};

try {
  walk(runtime);
} catch (err) {
  console.error(`[check-ps] cannot read runtime/: ${err.message}`);
  process.exit(1);
}

// 1) BOM
const badBom = files.filter((f) => {
  const b = readFileSync(f);
  return !(b.length >= 3 && b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf);
});

if (badBom.length > 0) {
  console.error('[check-ps] 这些 .ps1 缺 UTF-8 BOM，PowerShell 5.1 会按 ANSI 读并吞掉引号：');
  for (const f of badBom) console.error(`  - ${path.relative(root, f)}`);
  process.exit(1);
}

// 2) 语法（Windows 上才有 PowerShell；其它平台跳过，插件本来就 os: win32）
if (process.platform === 'win32') {
  const psRoot = process.env.SystemRoot || 'C:\\Windows';
  const ps = path.join(psRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  const quote = (s) => `'${s.replace(/'/g, "''")}'`;
  const body = files
    .map(
      (f) =>
        `$e=$null; $null=[System.Management.Automation.Language.Parser]::ParseFile(${quote(f)}, [ref]$null, [ref]$e); ` +
        `if ($e -and $e.Count) { Write-Error ('${path.relative(root, f)}: ' + $e[0].Message); exit 1 }`,
    )
    .join('; ');
  const r = spawnSync(ps, ['-NoProfile', '-NonInteractive', '-Command', body], { encoding: 'utf8' });
  if (r.status !== 0) {
    console.error('[check-ps] PowerShell 解析失败：');
    console.error((r.stderr || r.stdout || '').trim().slice(0, 800));
    process.exit(1);
  }
}

console.log(`[check-ps] ok (${files.length} .ps1, BOM + 语法)`);
