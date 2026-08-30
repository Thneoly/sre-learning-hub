#!/usr/bin/env node
/* 一次性自查脚本：验证 SCENARIOS.md 条目计数、路径与锚点真实性，并与 portal SCN_CATS 对账。
   锚点判定：精确命中标题，或标题以锚点开头（FIXES.md 的 "#11. break-apiserver-port" 类前缀引用为既有惯例）。 */
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');

const md = fs.readFileSync(path.join(ROOT, 'SCENARIOS.md'), 'utf8');
const lines = md.split(/\r?\n/);

// ---- 1. 逐分类统计条目 ----
const counts = {};
const catOrder = [];
let cur = null;
for (const l of lines) {
  const h = l.match(/^## (\d+) .+（/);
  if (h) { cur = h[1]; catOrder.push(cur); counts[cur] = 0; continue; }
  if (/^## /.test(l)) { cur = null; continue; }
  if (l.startsWith('- ') && l.includes('**现象**：')) {
    if (!cur) { console.log('ERROR: 条目不在任何分类下: ' + l.slice(0, 60)); process.exitCode = 1; }
    counts[cur]++;
  }
}
console.log('== SCENARIOS.md 分类计数 ==');
let total = 0;
for (const c of catOrder) { console.log('  ' + c + ' : ' + counts[c]); total += counts[c]; }
console.log('  合计: ' + total);

// ---- 2. 文末统计表对账 ----
const statRows = [...md.matchAll(/^\| (\d+ [^|]+?) \| (\d+) \|$/gm)].map(m => [m[1].trim(), +m[2]]);
const statTotal = (md.match(/\*\*合计\*\* \| \*\*(\d+)\*\*/m) || [])[1];
let statOk = true;
for (const [name, n] of statRows) {
  const id = name.split(' ')[0];
  if (counts[id] !== n) { console.log('ERROR: 统计表 ' + name + '=' + n + ' 实际=' + counts[id]); statOk = false; }
}
const sum = statRows.reduce((a, b) => a + b[1], 0);
if (+statTotal !== sum || sum !== total) { console.log('ERROR: 统计表合计 ' + statTotal + '/表内和 ' + sum + '/实际 ' + total); statOk = false; }
console.log('统计表对账: ' + (statOk ? 'OK' : 'FAIL'));

// ---- 3. 路径与锚点真实性 ----
const anchorCache = {};
function headingsOf(rel) {
  if (anchorCache[rel] !== undefined) return anchorCache[rel];
  const p = path.join(ROOT, rel);
  if (!fs.existsSync(p)) return (anchorCache[rel] = null);
  const set = new Set();
  for (const l of fs.readFileSync(p, 'utf8').split(/\r?\n/)) {
    const m = l.match(/^#{1,6}\s+(.*)$/);
    if (m) set.add(m[1].trim());
  }
  return (anchorCache[rel] = set);
}
let checked = 0, exact = 0, prefix = 0, errs = 0;
const prefixHits = [];
for (const l of lines) {
  if (!l.startsWith('- ') || !l.includes('**现象**：')) continue;
  const m = l.match(/^[-【】\s]*【?靶场?】?\*?\*?现象\*?\*?：.*→ 详见：(.+)$/);
  const rm = l.match(/→ 详见：(.+)$/);
  if (!rm) { console.log('ERROR: 条目无详见: ' + l.slice(0, 60)); errs++; continue; }
  // 先抽出（另见 X）交叉引用，再按 ；拆分
  let ref = rm[1];
  const extras = [];
  ref = ref.replace(/（另见 ([^）]+)）/g, (mm, inner) => { extras.push(inner); return ''; });
  const parts = ref.split(/；/).concat(extras);
  for (let part of parts) {
    part = part.trim();
    if (!part) continue;
    const pm = part.match(/^([\w./-]+\.(?:md|sh|yaml|yml))/);
    if (!pm) { console.log('ERROR: 引用不可解析: ' + part + '  <- ' + l.slice(0, 40)); errs++; continue; }
    const rel = pm[1];
    if (!fs.existsSync(path.join(ROOT, rel))) { console.log('ERROR: 文件不存在: ' + rel + '  <- ' + l.slice(0, 40)); errs++; continue; }
    checked++;
    const rest = part.slice(rel.length);
    if (rest.startsWith('#')) {
      const anchor = rest.slice(1);
      const hs = headingsOf(rel);
      if (hs === null) { console.log('ERROR: 读不到文件: ' + rel); errs++; continue; }
      if (hs.has(anchor)) { exact++; continue; }
      // 惯例一：锚点末尾的（…）是人工注释（如 "#常见坑（救命操作见同文件 …）"），剥掉再精确匹配
      const bare = anchor.replace(/（[^）]*）$/, '').trim();
      if (bare !== anchor && hs.has(bare)) { exact++; continue; }
      // 惯例二：FIXES.md 类引用只写标题前缀（"#11. break-apiserver-port"）
      let pref = null;
      for (const h of hs) { if (h.startsWith(anchor)) { pref = h; break; } }
      if (pref) { prefix++; prefixHits.push(rel + '#' + anchor + '  ->  ' + pref); }
      else { console.log('ERROR: 锚点不存在: ' + rel + '#' + anchor + '  <- ' + l.slice(0, 40)); errs++; }
    }
  }
}
console.log('引用检查: ' + checked + ' 个路径全部存在=' + (errs === 0) + '；锚点精确命中 ' + exact + ' 条、按既有前缀惯例命中 ' + prefix + ' 条');
if (prefixHits.length) { console.log('前缀命中明细:'); prefixHits.forEach(p => console.log('  ' + p)); }

// ---- 4. portal SCN_CATS 对账 ----
const html = fs.readFileSync(path.join(ROOT, 'portal/index.html'), 'utf8');
const scn = html.match(/var SCN_CATS = \[([\s\S]*?)\n  \];/);
if (!scn) { console.log('ERROR: SCN_CATS 未找到'); process.exitCode = 1; } else {
  const cats = [...scn[1].matchAll(/\{ t: '(\d+) [^']+', sub:/g)].map(m => m[1]);
  const itemCount = {};
  for (const c of cats) {
    const re = new RegExp("\\{ t: '" + c + " [^']*', sub: [\\s\\S]*?items: \\[([\\s\\S]*?)\\n    \\] \\}", 'm');
    const body = scn[1].match(re);
    if (!body) { console.log('ERROR: SCN_CATS 分类 ' + c + ' 未匹配'); process.exitCode = 1; continue; }
    itemCount[c] = (body[1].match(/^\s*\['/gm) || []).length;
  }
  console.log('== portal SCN_CATS 计数 ==');
  let ptotal = 0, allOk = true;
  for (const c of cats) { console.log('  ' + c + ' : ' + itemCount[c]); ptotal += itemCount[c]; }
  console.log('  合计: ' + ptotal);
  const catsSet = new Set(cats);
  for (const c of catOrder) {
    if (!catsSet.has(c)) { console.log('ERROR: portal 缺分类 ' + c); allOk = false; }
    else if (itemCount[c] !== counts[c]) { console.log('ERROR: 分类 ' + c + ' SCENARIOS=' + counts[c] + ' portal=' + itemCount[c]); allOk = false; }
  }
  console.log('SCN_CATS 与 SCENARIOS.md 对账: ' + (allOk ? 'OK' : 'FAIL'));
}
