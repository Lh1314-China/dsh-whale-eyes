// prepack 断言：runtime/*.ps1 必须是 UTF-8 with BOM。
//
// 起因（2026-11-16）：用不带 BOM 的编辑器重存 daemon.ps1 后，PowerShell 5.1 按 ANSI
// 读中文注释，某个字节把后面的引号吃掉，报错位置和真因差 100 行。这个坑会复发，
// 所以让打包直接失败，而不是等到线上玄学。

import { readdirSync, readFileSync, statSync } from 'node:fs';
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
  console.error(`[check-bom] cannot read runtime/: ${err.message}`);
  process.exit(1);
}

const bad = files.filter((f) => {
  const b = readFileSync(f);
  return !(b.length >= 3 && b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf);
});

if (bad.length > 0) {
  console.error('[check-bom] 这些 .ps1 缺 UTF-8 BOM，PowerShell 5.1 会按 ANSI 读并吞掉引号：');
  for (const f of bad) console.error(`  - ${path.relative(root, f)}`);
  process.exit(1);
}

console.log(`[check-bom] ok (${files.length} .ps1 files)`);
