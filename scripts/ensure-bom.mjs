// 开发辅助：把 runtime/*.ps1 统一成 UTF-8 with BOM。
// 编辑工具（以及多数编辑器默认保存）会掉 BOM；掉一次就是一次「报错位置差 100 行」。
// 用法：node scripts/ensure-bom.mjs
import { readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const root = path.join(process.cwd(), 'runtime');
const files = [];
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const p = path.join(dir, name);
    const s = statSync(p);
    if (s.isDirectory()) walk(p);
    else if (name.endsWith('.ps1')) files.push(p);
  }
};
walk(root);

let fixed = 0;
for (const f of files) {
  const b = readFileSync(f);
  const hasBom = b.length >= 3 && b[0] === 0xef && b[1] === 0xbb && b[2] === 0xbf;
  if (!hasBom) {
    writeFileSync(f, Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), b]));
    fixed += 1;
    console.log(`[ensure-bom] fixed ${path.relative(process.cwd(), f)}`);
  }
}
console.log(`[ensure-bom] ${files.length} files, fixed ${fixed}`);
