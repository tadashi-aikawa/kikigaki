// HEADの更新経路を/tmpへ生成する。同じ依存・他の描画ソースでpreview.jsの変更だけを比べる。
import { build } from 'esbuild';
import { execFileSync } from 'node:child_process';
import { cp, mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
const directory = dirname(fileURLToPath(import.meta.url)), root = resolve(directory, '../..');
const output = resolve(process.argv[2] || '');
if (!output.startsWith('/tmp/') && !output.startsWith('/private/tmp/')) throw new Error('出力先は/tmp配下だけ');
await mkdir(output, { recursive:true });
await build({ stdin:{
  contents:execFileSync('git', ['show', 'HEAD:web/minutes/preview.js'], { cwd:root, encoding:'utf8' }),
  resolveDir:directory, sourcefile:'preview.js', loader:'js',
}, outfile:resolve(output, 'preview.js'), bundle:true, minify:true, format:'iife', target:'safari18' });
for (const file of ['index.html','preview.css','katex.min.css','fonts'])
  await cp(resolve(root,'Sources/Kikigaki/MinutesAssets',file),resolve(output,file),{ recursive:true });
console.log('比較資産: ' + output);
