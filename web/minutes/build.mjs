// 通常のSwiftビルドはNode不要。npm ci && npm run build で同梱資産を再生成する。
import { build } from 'esbuild';
import { cp, mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
const out = '../../Sources/Kikigaki/MinutesAssets';
await mkdir(out, { recursive: true });
await build({ entryPoints: ['preview.js'], outfile: `${out}/preview.js`, bundle: true,
  minify: true, format: 'iife', target: 'safari18', legalComments: 'linked' });
for (const file of ['preview.css', 'index.html']) await cp(file, `${out}/${file}`);
await cp('node_modules/katex/dist/katex.min.css', `${out}/katex.min.css`);
await cp('node_modules/katex/dist/fonts', `${out}/fonts`, { recursive: true });
const notices = [];
async function licenses(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    const root = `${dir}/${entry.name}`;
    if (entry.name.startsWith('@')) { await licenses(root); continue; }
    for (const file of await readdir(root)) {
      if (/^(licen[sc]e|copying|notice)(\.|$)/i.test(file))
        notices.push(`\n--- ${root}/${file} ---\n${await readFile(`${root}/${file}`, 'utf8')}`);
    }
    try { await licenses(`${root}/node_modules`); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  }
}
await licenses('node_modules');
await writeFile(`${out}/THIRD-PARTY-NOTICES.txt`, notices.join('\n'));
