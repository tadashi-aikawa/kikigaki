// HEADの描画と、粗いミニマップだけを足した描画を/tmpへ生成する。作業ツリー・同梱資産は書き換えない。
import { build } from 'esbuild';
import { execFileSync } from 'node:child_process';
import { cp, mkdir } from 'node:fs/promises';
import { dirname, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
const directory = dirname(fileURLToPath(import.meta.url)), root = resolve(directory, '../..');
const output = resolve(process.argv[2] || '');
if (!output.startsWith('/tmp/') && !output.startsWith('/private/tmp/')) throw new Error('出力先は/tmp配下だけ');
const original = file => execFileSync('git', ['show', `HEAD:web/minutes/${file}`], { cwd:root, encoding:'utf8' });
for (const variant of ['before', 'coarse']) {
  const target = resolve(output, variant); await mkdir(target, { recursive:true });
  await build({ entryPoints:[resolve(directory,'preview.js')], outfile:resolve(target,'preview.js'), bundle:true,
    minify:true, format:'iife', target:'safari18', plugins:[{
      name:'measurement-variant', setup(build) {
        build.onLoad({ filter:/(preview|diagrams)\.js$/ }, args => {
          if (dirname(args.path) !== directory) return;
          let contents = original(basename(args.path));
          if (variant === 'coarse' && basename(args.path) === 'diagrams.js') {
            const source = "const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');\n    use.setAttribute('href', '#' + svg.id); use.setAttribute('pointer-events', 'none');";
            if (!contents.includes(source)) throw new Error('HEADのミニマップ生成箇所を見つけられません');
            contents = "import { createMinimap } from './minimap.js';\n" + contents.replace(source, 'const use = createMinimap(svg);');
          }
          return { contents, loader:'js', resolveDir:directory };
        });
      }
    }] });
  for (const file of ['index.html','preview.css','katex.min.css','fonts']) {
    await cp(resolve(root,'Sources/Kikigaki/MinutesAssets',file),resolve(target,file),{ recursive:true });
  }
  console.log('計測資産: ' + target);
}
