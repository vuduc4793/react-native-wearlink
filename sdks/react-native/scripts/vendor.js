#!/usr/bin/env node
// Chạy khi `npm pack` / `npm publish` (prepack): chép mã nguồn SDK (Kotlin + Swift + podspec) từ `sdks/` của repo vào
// `vendor/sdks/` bên trong gói, giữ nguyên bố cục thư mục. Khi cài từ npm không có repo: Gradle (android/build.gradle) và
// Podfile của app dùng `vendor/sdks`; trong repo thì vẫn dùng thẳng `../..` (vendor không tồn tại).
// Chỉ chép mã chạy (src/main/java, ios/Sources, manifest core), không chép test, research, build.
const fs = require('fs');
const path = require('path');

const pkg = path.resolve(__dirname, '..');
const sdks = path.resolve(pkg, '..');
const out = path.join(pkg, 'vendor', 'sdks');
const MODULES = ['core', 'qring', 'gloryfit', 'standard', 'veepoo'];

function copyDir(from, to) {
  if (!fs.existsSync(from)) throw new Error(`Thiếu ${from}`);
  fs.mkdirSync(to, {recursive: true});
  for (const e of fs.readdirSync(from, {withFileTypes: true})) {
    if (e.name.startsWith('.')) continue;
    const s = path.join(from, e.name);
    const d = path.join(to, e.name);
    if (e.isDirectory()) copyDir(s, d);
    else fs.copyFileSync(s, d);
  }
}

fs.rmSync(path.join(pkg, 'vendor'), {recursive: true, force: true});
let files = 0;
for (const m of MODULES) {
  copyDir(path.join(sdks, m, 'android', 'src', 'main', 'java'), path.join(out, m, 'android', 'src', 'main', 'java'));
  copyDir(path.join(sdks, m, 'ios', 'Sources'), path.join(out, m, 'ios', 'Sources'));
}
for (const f of fs.readdirSync(sdks)) {
  if (f.endsWith('.podspec')) fs.copyFileSync(path.join(sdks, f), path.join(out, f));
}
const count = d => fs.readdirSync(d, {withFileTypes: true}).reduce((n, e) => n + (e.isDirectory() ? count(path.join(d, e.name)) : 1), 0);
files = count(out);
console.log(`vendor: ${files} file từ ${MODULES.join(', ')} → ${path.relative(pkg, out)}`);
