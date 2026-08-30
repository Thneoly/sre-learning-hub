#!/usr/bin/env node
// gen-skill-cards.mjs —— 从学习中心三处内容挖掘"技能卡"，一次产出三份文件：
//   1. _meta/skill-cards.json      卡片库主数据（version/generated/cards）
//   2. portal/cards-data.js        window.HUB_CARDS = {...}（与 quiz-data.js 同机制，file:// 可用）
//   3. _meta/skill-cards-anki.csv  Anki 导出（front,back,tags 三列，UTF-8，逗号转义）
//
// 卡片来源：
//   a) 各章末尾"## 自测"小节的 <details> 问答（最大来源，支持两种版式：
//      版式 A：问题在 <summary> 里，答案在正文；
//      版式 B：问题是 <details> 前的普通文本行，<summary> 为"答案"）
//   b) 根目录 SCENARIOS.md 的场景条目（现象 → 先查 → 详见）
//   c) portal/quiz-data.js 的 window.QUIZ_DATA（16 库 265 题）
//
// 用法（在仓库任意位置）：node scripts/gen-skill-cards.mjs [--root <learning-hub 根目录>]
// 可重复运行：全部输出来自源文件即时解析，无中间状态。
// 解析失败按条记录日志但不中断；失败率 ≥5% 时以非零码退出提醒。

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/* ---------------- 参数与路径 ---------------- */
const argv = process.argv.slice(2);
let rootArg = null;
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--root' && argv[i + 1]) { rootArg = argv[i + 1]; i++; }
}
const ROOT = path.resolve(rootArg || path.join(path.dirname(fileURLToPath(import.meta.url)), '..'));
const log = (msg) => console.log(msg);

/* ---------------- 通用小工具 ---------------- */
function readText(p) {
  // 去掉可能的 UTF-8 BOM
  return fs.readFileSync(p, 'utf8').replace(/^﻿/, '');
}
function exists(p) { try { fs.accessSync(p); return true; } catch { return false; } }
const LIMIT = 300; // back 精炼上限（字符）
const isItemLine = (l) => /^([-*+]|\d+[.)])\s+/.test(l);
const stripItem = (l) => l.replace(/^([-*+]|\d+[.)])\s+/, '');

function joinLines(lines) {
  let out = '', buf = [];
  const flush = () => { if (buf.length) { out += (out ? '\n' : '') + buf.join(' '); buf = []; } };
  for (const l of lines) {
    if (isItemLine(l)) { flush(); out += (out ? '\n' : '') + '· ' + stripItem(l); }
    else { buf.push(l); }
  }
  flush();
  return out;
}

// back 精炼：≤LIMIT 原样保留；超限取正文首段 + 列表要点，再硬截断
function condenseBack(raw) {
  const lines = String(raw || '').replace(/\r/g, '').split('\n').map((s) => s.trim()).filter(Boolean);
  if (!lines.length) { return ''; }
  if (lines.join(' ').length <= LIMIT) { return joinLines(lines); }
  const para = [];
  for (const l of lines) { if (isItemLine(l)) { break; } para.push(l); }
  const items = lines.filter(isItemLine).map(stripItem);
  let out = para.join(' ');
  if (items.length) { out += (out ? '\n' : '') + '要点：' + items.join('；'); }
  if (out.length > LIMIT) { out = out.slice(0, LIMIT - 1) + '…'; }
  return out;
}

// 取解析首句（到第一个句号/分号），用于 quiz 解析浓缩
function firstSentence(s) {
  const t = String(s || '').trim();
  if (!t) { return ''; }
  const m = t.match(/^[^。；;！!？?]*[。；;！!？?]?/);
  let one = m ? m[0] : t;
  if (one.length > 160) { one = one.slice(0, 159) + '…'; }
  return one;
}

/* ---------------- 1. 章节自测挖掘 ---------------- */
const STOPWORDS = new Set(['and', 'the', 'of', 'with', 'for', 'and', 'deep', 'into', 'usage', 'guide']);
function chapterTags(file) {
  // 04-k8s-fundamentals/05-service-and-dns.md → ['service', 'dns']
  const stem = path.basename(file).replace(/^\d{2}-/, '').replace(/\.md$/, '');
  const toks = stem.split('-')
    .map((s) => s.toLowerCase())
    .filter((s) => s.length >= 3 && /^[a-z0-9]+$/.test(s) && !STOPWORDS.has(s))
    .slice(0, 3);
  return toks;
}

// 提取一个文件的"## 自测"小节原文；找不到返回 null
function sliceSelfTest(text) {
  const lines = text.replace(/\r/g, '').split('\n');
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (/^##\s*自测\s*$/.test(lines[i])) { start = i + 1; break; }
  }
  if (start < 0) { return null; }
  const body = [];
  for (let i = start; i < lines.length; i++) {
    if (/^##\s+\S/.test(lines[i])) { break; }
    body.push(lines[i]);
  }
  return body.join('\n');
}

// 状态机解析 details 问答块；防呆：围栏代码块内的 <details>/<summary> 字样不当作标记，
// details 嵌套按深度计数（当前各章无此情况，纯防御）
function parseSelfTest(bodyText, relPath, failures) {
  const lines = bodyText.split('\n');
  const out = [];
  let inFence = false, depth = 0, buf = [], pendingQ = [];
  for (const line of lines) {
    if (/^\s*```/.test(line)) { inFence = !inFence; }
    let rest = line;
    if (!inFence) {
      // 逐段消化本行里的 <details ...> / </details> 标记
      let m;
      while ((m = rest.match(/<details\b[^>]*>|<\/details>/))) {
        const before = rest.slice(0, m.index);
        if (before.trim()) {
          if (depth === 0) { pendingQ.push(before.trim()); }
          else if (depth === 1) { buf.push(before.trim()); }
        }
        if (m[0] === '</details>') {
          depth--;
          if (depth === 0) {
            out.push(finishBlock(buf.join('\n'), pendingQ));
            buf = []; pendingQ = [];
          }
        } else {
          depth++;
          if (depth === 1) { buf = []; }
        }
        rest = rest.slice(m.index + m[0].length);
      }
      if (rest.trim()) {
        if (depth === 0) { pendingQ.push(rest.trim()); }
        else if (depth >= 1) { buf.push(rest.trim()); }
      }
    } else if (depth >= 1) {
      buf.push(line); // 代码块内容按原文保留（含缩进）
    }
  }
  if (depth !== 0) { failures.push(`${relPath}: 自测小节 details 未闭合（depth=${depth}）`); }
  return out.filter(Boolean);

  function finishBlock(raw, qLines) {
    const sm = raw.match(/<summary>([\s\S]*?)<\/summary>/i);
    const summary = sm ? sm[1].trim() : '';
    const inner = raw
      .replace(/^\s*<summary>[\s\S]*?<\/summary>/i, '')
      .replace(/\s+/g, ' ')
      .trim();
    let front = '';
    if (/^\s*答案\s*[:：]?\s*$/.test(summary)) {
      front = qLines.join(' '); // 版式 B：问题在 details 之前的普通文本行
    } else {
      front = summary.replace(/\s+/g, ' ').trim(); // 版式 A：问题在 summary 里
    }
    const back = condenseBack(inner);
    if (!front || !back) {
      failures.push(`${relPath}: 问答块缺 ${!front ? '问题' : '答案'}（front=${JSON.stringify(front.slice(0, 40))}）`);
      return null;
    }
    return { front, back };
  }
}

function collectChapters() {
  const mods = fs.readdirSync(ROOT, { withFileTypes: true })
    .filter((d) => d.isDirectory() && /^\d{2}-/.test(d.name))
    .map((d) => d.name)
    .sort();
  const files = [];
  for (const mod of mods) {
    const walk = (dir, rel) => {
      for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
        const relPath = rel ? `${rel}/${ent.name}` : ent.name;
        if (ent.isDirectory()) {
          if (ent.name === 'labs') { continue; } // lab 的 task/solution 不在挖掘范围
          walk(path.join(dir, ent.name), relPath);
        } else if (/^\d{2}-.*\.md$/.test(ent.name)) {
          files.push({ mod, rel: relPath });
        }
      }
    };
    walk(path.join(ROOT, mod), mod);
  }
  files.sort((a, b) => (a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0));
  return files;
}

/* ---------------- 2. SCENARIOS.md 场景条目 ---------------- */
// 靶场条目（详见指向 scripts/faults/FIXES.md）没有模块路径，用故障名映射归属模块
const FAULT_MODULE = {
  'break-coredns': '04-k8s-fundamentals',
  'break-dns-config': '04-k8s-fundamentals',
  'break-etcd-endpoint': '05-cka',
  'break-kubelet': '05-cka',
  'break-apiserver-port': '05-cka',
  'break-static-pod': '04-k8s-fundamentals',
  'break-cni': '04-k8s-fundamentals',
  'break-rbac': '07-cks',
  'break-endpoints': '04-k8s-fundamentals',
  'break-ipforward': '04-k8s-fundamentals',
  'break-scheduler-pod': '04-k8s-fundamentals',
  'break-imagepull': '04-k8s-fundamentals'
};

function parseScenarios(failures) {
  const p = path.join(ROOT, 'SCENARIOS.md');
  if (!exists(p)) { failures.push('SCENARIOS.md 不存在，场景卡为 0'); return []; }
  const out = [];
  const lines = readText(p).split('\n');
  let ln = 0;
  for (const line of lines) {
    ln++;
    const m = line.match(/^- (【靶场】)?\*\*现象\*\*：(.*)$/);
    if (!m) { continue; }
    const drill = !!m[1];
    const rest = m[2];
    const i1 = rest.indexOf(' → 先查：');
    const i2 = i1 >= 0 ? rest.indexOf(' → 详见：', i1) : -1;
    if (i1 < 0 || i2 < 0) {
      failures.push(`SCENARIOS.md:${ln}: 条目缺少「先查/详见」段，已跳过`);
      continue;
    }
    const front = rest.slice(0, i1).trim();
    const action = rest.slice(i1 + ' → 先查：'.length, i2).trim();
    const ref = rest.slice(i2 + ' → 详见：'.length).trim();
    if (!front || !action) {
      failures.push(`SCENARIOS.md:${ln}: 现象或先查为空，已跳过`);
      continue;
    }
    // 归属模块：详见里第一个模块目录段；靶场条目退回故障名映射
    let module = (ref.match(/\d{2}-[a-z0-9-]+/) || [])[0] || '';
    if (!module) {
      const fault = (ref.match(/break-[a-z-]+/) || [])[0];
      module = FAULT_MODULE[fault] || '05-cka';
    }
    out.push({ module, front, back: action, ref, drill, line: ln });
  }
  return out;
}

/* ---------------- 3. quiz-data.js 题库 ---------------- */
const QUIZ_MODULE = {
  pca: '08-pca', cka: '05-cka', cks: '07-cks', basics: '04-k8s-fundamentals',
  linux: '01-linux', programming: '02-programming', cicd: '06-cicd-iac-gitops',
  otel: '09-otel', logging: '10-logging', middleware: '11-middleware',
  datastream: '12-data-streaming', sre: '13-sre-methodology', cloud: '14-cloud',
  aiops: '15-aiops-llm', bigdata: '16-bigdata', distributed: '17-distributed'
};
const QUIZ_ORDER = ['pca', 'cka', 'cks', 'basics', 'linux', 'programming', 'cicd', 'otel',
  'logging', 'middleware', 'datastream', 'sre', 'cloud', 'aiops', 'bigdata', 'distributed'];

function loadQuizData() {
  const p = path.join(ROOT, 'portal', 'quiz-data.js');
  if (!exists(p)) { return null; }
  const shim = {};
  try {
    // quiz-data.js 是普通脚本（给 window.QUIZ_DATA 赋值），用 Function 沙箱执行
    new Function('window', readText(p))(shim);
  } catch (e) {
    throw new Error(`quiz-data.js 解析失败：${e.message}`);
  }
  return shim.QUIZ_DATA || null;
}

function parseQuiz(failures) {
  const qd = loadQuizData();
  if (!qd) { failures.push('portal/quiz-data.js 不存在或 QUIZ_DATA 为空，quiz 卡为 0'); return []; }
  const banks = [...QUIZ_ORDER.filter((k) => Array.isArray(qd[k])), ...Object.keys(qd)
    .filter((k) => !QUIZ_ORDER.includes(k) && Array.isArray(qd[k]))];
  const out = [];
  for (const bank of banks) {
    const arr = qd[bank];
    arr.forEach((q, i) => {
      if (!q || !q.q) { failures.push(`quiz ${bank}[${i}]: 缺题干，已跳过`); return; }
      const opts = Array.isArray(q.options) ? q.options : [];
      const ansIdx = typeof q.answer === 'number' ? q.answer : -1;
      const ansText = ansIdx >= 0 && opts[ansIdx] !== undefined ? opts[ansIdx] : '';
      const raw = (ansText ? `答案：${ansText}` : '') +
        (q.explain ? `${ansText ? '。' : ''}解析：${firstSentence(q.explain)}` : '');
      if (!raw) { failures.push(`quiz ${bank}[${i}]: 无答案且无解析，已跳过`); return; }
      out.push({
        module: QUIZ_MODULE[bank] || bank,
        bank,
        idx: i,
        front: String(q.q).replace(/\s+/g, ' ').trim(),
        back: condenseBack(raw)
      });
    });
  }
  return out;
}

/* ---------------- 主流程 ---------------- */
function main() {
  const failures = [];
  const cards = [];
  const stats = { selftest: 0, scenario: 0, quiz: 0, byModule: {} };
  let chapterFiles = 0, withSection = 0, detailsTotal = 0;

  // 1) 章节自测
  const chapters = collectChapters();
  chapterFiles = chapters.length;
  for (const ch of chapters) {
    const full = path.join(ROOT, ch.rel);
    const body = sliceSelfTest(readText(full));
    if (body === null) { continue; } // 无自测小节（如题库手册）不算失败
    withSection++;
    const tags = chapterTags(ch.rel);
    const qas = parseSelfTest(body, ch.rel, failures);
    detailsTotal += qas.length;
    if (!qas.length) { failures.push(`${ch.rel}: 有自测小节但未解析出问答块`); continue; }
    qas.forEach((qa, i) => {
      cards.push({
        module: ch.mod,
        source: `${ch.rel}#自测`,
        type: 'selftest',
        front: qa.front,
        back: qa.back,
        tags: ['selftest', ...tags, `q${i + 1}`]
      });
    });
  }
  stats.selftest = cards.length;

  // 2) 场景条目
  const scenarios = parseScenarios(failures);
  for (const sc of scenarios) {
    cards.push({
      module: sc.module,
      source: `SCENARIOS.md#L${sc.line}`,
      type: 'scenario',
      front: sc.front,
      back: sc.back,
      tags: sc.drill ? ['scenario', 'drill'] : ['scenario']
    });
  }
  stats.scenario = scenarios.length;

  // 3) 题库
  const quizzes = parseQuiz(failures);
  for (const q of quizzes) {
    cards.push({
      module: q.module,
      source: `portal/quiz-data.js#${q.bank}[${q.idx}]`,
      type: 'quiz',
      front: q.front,
      back: q.back,
      tags: ['quiz', `quiz-${q.bank}`]
    });
  }
  stats.quiz = quizzes.length;

  // 编号 + 模块统计
  cards.forEach((c, i) => {
    c.id = 'sc-' + String(i + 1).padStart(4, '0');
    stats.byModule[c.module] = (stats.byModule[c.module] || 0) + 1;
  });
  // 统一卡片字段顺序
  const ordered = cards.map((c) => ({
    id: c.id, module: c.module, source: c.source, type: c.type,
    front: c.front, back: c.back, tags: c.tags
  }));

  const generated = new Date().toISOString().slice(0, 10);
  const data = { version: 1, generated, cards: ordered };

  /* ---- 产物 1：_meta/skill-cards.json ---- */
  const metaDir = path.join(ROOT, '_meta');
  fs.mkdirSync(metaDir, { recursive: true });
  fs.writeFileSync(path.join(metaDir, 'skill-cards.json'), JSON.stringify(data, null, 2) + '\n');

  /* ---- 产物 2：portal/cards-data.js ---- */
  const header = [
    '// cards-data.js · 学习中心技能卡库（由 scripts/gen-skill-cards.mjs 生成，请勿手工编辑）',
    `// 生成时间：${generated} · 总卡数：${ordered.length}（自测 ${stats.selftest} / 场景 ${stats.scenario} / 题库 ${stats.quiz}）`,
    '// 结构：window.HUB_CARDS = { version, generated, cards:[{id,module,source,type,front,back,tags}] }',
    '// 来源：各章"## 自测"问答 + SCENARIOS.md 场景条目 + quiz-data.js 题库；',
    '// 重新生成：node scripts/gen-skill-cards.mjs（同时产出 _meta/skill-cards.json 与 _meta/skill-cards-anki.csv）。',
    ''
  ].join('\n');
  fs.writeFileSync(path.join(ROOT, 'portal', 'cards-data.js'),
    header + 'window.HUB_CARDS = ' + JSON.stringify(data) + ';\n');

  /* ---- 产物 3：_meta/skill-cards-anki.csv ---- */
  const csvEsc = (s) => {
    let v = String(s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/\r?\n/g, '<br>');
    if (/[",]/.test(v)) { v = '"' + v.replace(/"/g, '""') + '"'; }
    return v;
  };
  const csv = ['front,back,tags',
    ...ordered.map((c) => `${csvEsc(c.front)},${csvEsc(c.back)},${csvEsc(c.tags.join(' '))}`)]
    .join('\r\n') + '\r\n';
  fs.writeFileSync(path.join(metaDir, 'skill-cards-anki.csv'), csv);

  /* ---- 日志与结果 ---- */
  log(`[gen-skill-cards] 章节文件 ${chapterFiles} 个，含自测小节 ${withSection} 个，解析问答块 ${stats.selftest} 张`);
  log(`[gen-skill-cards] 场景卡 ${stats.scenario} 张 · 题库卡 ${stats.quiz} 张 · 合计 ${ordered.length} 张`);
  const mods = Object.keys(stats.byModule).sort();
  log('[gen-skill-cards] 按模块：' + mods.map((m) => `${m}=${stats.byModule[m]}`).join(' '));
  if (failures.length) {
    log(`[gen-skill-cards] 解析问题 ${failures.length} 条：`);
    for (const f of failures) { log('  [warn] ' + f); }
  }
  const denom = Math.max(1, stats.selftest + stats.scenario + stats.quiz);
  const rate = failures.length / denom;
  log(`[gen-skill-cards] 失败率 ${(rate * 100).toFixed(2)}%（${failures.length}/${denom}）`);
  log(`[gen-skill-cards] 产物：_meta/skill-cards.json · portal/cards-data.js · _meta/skill-cards-anki.csv`);
  if (rate >= 0.05) {
    log('[gen-skill-cards] 失败率 ≥5%，请检查上方 warn 日志');
    process.exitCode = 1;
  }
}

main();
