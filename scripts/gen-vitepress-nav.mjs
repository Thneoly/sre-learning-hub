#!/usr/bin/env node
/**
 * 扫描仓库模块目录，生成 VitePress 的侧栏（sidebar）与模块导航数据。
 *
 * - 由 `npm run docs:dev` / `npm run docs:build` 在启动 vitepress 前自动执行
 * - 输出: docs/.vitepress/sidebar.generated.json（已进 .gitignore，勿提交）
 *   结构: { sidebar: { '/': [...], '/01-linux/': [...] }, modules: [...] }
 * - 只按「文件实际存在」生成条目：
 *   - 05-cka/question-bank-manual-v1.35.md（gitignore 排除的题库手册）不会被列出
 *   - 04-k8s-fundamentals 没有 labs/ 目录时自动省略 Labs 分组
 *   - task.md / solution.md 缺失任意一侧时也能生成
 *
 * 用法: node scripts/gen-vitepress-nav.mjs
 */
import { readdirSync, readFileSync, existsSync, writeFileSync, mkdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = fileURLToPath(new URL('..', import.meta.url))

/** 模块元数据：pillar 对应 README「能力支柱视图」的四支柱
 *  platform=云原生平台域 devops=DevOps 工程域 observability=可观测与 SRE 域 aiops=AIOps 智能域 */
const MODULES = [
  { dir: '01-linux', title: '01 · Linux 底座', pillar: 'platform' },
  { dir: '02-programming', title: '02 · 编程基础（Shell/Python/Go）', pillar: 'platform' },
  { dir: '03-docker', title: '03 · Docker 容器', pillar: 'platform' },
  { dir: '04-k8s-fundamentals', title: '04 · Kubernetes 原理', pillar: 'platform' },
  { dir: '05-cka', title: '05 · CKA 备考', pillar: 'platform' },
  { dir: '06-cicd-iac-gitops', title: '06 · CI/CD · IaC · GitOps', pillar: 'devops' },
  { dir: '07-cks', title: '07 · CKS 安全', pillar: 'platform' },
  { dir: '08-pca', title: '08 · PCA 可观测', pillar: 'observability' },
  { dir: '09-otel', title: '09 · OpenTelemetry', pillar: 'observability' },
  { dir: '10-logging', title: '10 · 日志体系（ELK/Loki）', pillar: 'observability' },
  {
    dir: '11-middleware',
    title: '11 · 中间件四件套',
    pillar: 'platform',
    topics: [
      { dir: 'nginx', title: 'Nginx' },
      { dir: 'mysql', title: 'MySQL' },
      { dir: 'redis', title: 'Redis' },
      { dir: 'mongodb', title: 'MongoDB' },
    ],
  },
  {
    dir: '12-data-streaming',
    title: '12 · 数据流（Kafka/Flink）',
    pillar: 'platform',
    topics: [
      { dir: 'kafka', title: 'Kafka' },
      { dir: 'flink', title: 'Flink' },
    ],
  },
  { dir: '13-sre-methodology', title: '13 · SRE 方法论', pillar: 'observability' },
  { dir: '14-cloud', title: '14 · 云平台', pillar: 'platform' },
  { dir: '15-aiops-llm', title: '15 · AIOps 与 LLM', pillar: 'aiops' },
  { dir: '16-bigdata', title: '16 · 大数据体系', pillar: 'platform' },
  { dir: '17-distributed', title: '17 · 分布式理论', pillar: 'platform' },
]

// ---------- 工具 ----------

const toPosix = (p) => p.split('\\').join('/')

/** 仓库根相对路径 -> 站点路由（VitePress 默认非 cleanUrls，页面以 .html 结尾） */
const pageLink = (absFile) =>
  '/' + toPosix(absFile.slice(ROOT.length)).replace(/\.md$/, '.html')

/** 取 md 的第一个 `# ` 标题作为侧栏文本（去掉行内代码/加粗记号） */
const firstHeading = (absFile) => {
  try {
    const m = readFileSync(absFile, 'utf8').match(/^#\s+(.+)$/m)
    if (m) return m[1].replace(/[`*]/g, '').trim()
  } catch {
    /* ignore */
  }
  return null
}

const fileNameToText = (name) => name.replace(/\.md$/, '').replace(/-/g, ' ')

/** 目录下 NN-*.md 章节列表（按文件名排序；跳过题库手册等非章节文件） */
const chapterItems = (dir) => {
  if (!existsSync(dir)) return []
  return readdirSync(dir)
    .filter((f) => /^\d{2}-.*\.md$/.test(f) && !/question-bank/.test(f))
    .sort()
    .map((f) => ({
      text: firstHeading(join(dir, f)) ?? fileNameToText(f),
      link: pageLink(join(dir, f)),
    }))
}

/** labs 目录 -> 侧栏条目：
 *  - NN-xxx/ 子目录 -> 可折叠的 "Lab NN · 标题"（题目/解答两个子项）
 *  - 直接散落的 .md（如 08-pca 的题集）-> 单独条目 */
const labItems = (labsDir) => {
  if (!existsSync(labsDir)) return []
  const entries = readdirSync(labsDir, { withFileTypes: true }).sort((a, b) =>
    a.name < b.name ? -1 : 1
  )
  const items = []
  for (const e of entries) {
    if (e.isFile() && e.name.endsWith('.md')) {
      const abs = join(labsDir, e.name)
      items.push({ text: firstHeading(abs) ?? fileNameToText(e.name), link: pageLink(abs) })
    }
  }
  for (const e of entries) {
    if (!e.isDirectory() || !/^\d{2}-/.test(e.name)) continue
    const task = join(labsDir, e.name, 'task.md')
    const solution = join(labsDir, e.name, 'solution.md')
    const num = e.name.match(/^\d{2}/)?.[0] ?? e.name
    const raw = firstHeading(task) ?? e.name
    const title = raw.replace(/^Lab\s*\d+\s*[·•:：.\-—]\s*/, '').trim() || e.name
    const children = []
    if (existsSync(task)) children.push({ text: '题目', link: pageLink(task) })
    if (existsSync(solution)) children.push({ text: '解答', link: pageLink(solution) })
    if (children.length === 0) continue
    if (children.length === 1) items.push({ text: `Lab ${num} · ${title}`, link: children[0].link })
    else items.push({ text: `Lab ${num} · ${title}`, collapsed: true, items: children })
  }
  return items
}

/** 单模块侧栏（嵌套模块按 topic 分组） */
const moduleSidebar = (mod) => {
  const modDir = join(ROOT, mod.dir)
  if (!existsSync(modDir)) return null
  if (mod.topics) {
    const groups = mod.topics
      .map((t) => {
        const tDir = join(modDir, t.dir)
        if (!existsSync(tDir)) return null
        const items = [...chapterItems(tDir)]
        const labs = labItems(join(tDir, 'labs'))
        if (labs.length) items.push({ text: 'Labs', collapsed: false, items: labs })
        return items.length ? { text: t.title, collapsed: false, items } : null
      })
      .filter(Boolean)
    return groups.length ? groups : null
  }
  const items = []
  const chapters = chapterItems(modDir)
  const labs = labItems(join(modDir, 'labs'))
  if (chapters.length) items.push({ text: '章节', collapsed: false, items: chapters })
  if (labs.length) items.push({ text: 'Labs', collapsed: false, items: labs })
  return items.length ? items : null
}

/** 深度优先取分组里第一个真实链接（作为导航进入模块的入口页） */
const firstLink = (items) => {
  for (const it of items ?? []) {
    if (it.link) return it.link
    const found = firstLink(it.items)
    if (found) return found
  }
  return null
}

// ---------- 生成 ----------

const sidebar = {
  '/': [
    {
      text: '知识库',
      collapsed: false,
      items: [
        { text: '首页', link: '/' },
        { text: '学习路线图（27 周 / 10 阶段）', link: '/ROADMAP.html' },
        { text: '故障场景速查', link: '/SCENARIOS.html' },
        { text: '仓库说明（README）', link: '/README.html' },
      ],
    },
  ],
}

const modules = []
let chapterCount = 0
let labCount = 0

const countItems = (items) => {
  for (const it of items) {
    if (it.link) {
      if (/\/labs\//.test(it.link)) labCount++
      else if (/\.html$/.test(it.link)) chapterCount++
      if (it.items) countItems(it.items)
    } else if (it.items) {
      countItems(it.items)
    }
  }
}

for (const mod of MODULES) {
  const items = moduleSidebar(mod)
  if (!items) continue
  sidebar[`/${mod.dir}/`] = items
  countItems(items)
  const link = firstLink(items)
  if (link) modules.push({ dir: mod.dir, title: mod.title, pillar: mod.pillar, link })
}

const out = {
  generatedAt: new Date().toISOString(),
  sidebar,
  modules,
}

const outFile = join(ROOT, 'docs', '.vitepress', 'sidebar.generated.json')
mkdirSync(dirname(outFile), { recursive: true })
writeFileSync(outFile, JSON.stringify(out, null, 2) + '\n', 'utf8')

console.log(
  `[gen-vitepress-nav] ${modules.length} 个模块 / ${chapterCount} 个章节页 / ${labCount} 个 lab 页 -> ${toPosix(outFile.slice(ROOT.length))}`
)
