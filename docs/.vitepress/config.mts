import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vitepress'

const repoUrl = 'https://github.com/Thneoly/sre-learning-hub'

// ---------- 读取 gen-vitepress-nav.mjs 生成的侧栏/模块数据 ----------
// （docs:dev / docs:build 会先跑 scripts/gen-vitepress-nav.mjs；直接 vitepress dev 时给空兜底）
type GeneratedNav = {
  sidebar: Record<string, any>
  modules: { dir: string; title: string; pillar: string; link: string }[]
}

let sidebar: GeneratedNav['sidebar'] = {}
let modules: GeneratedNav['modules'] = []
try {
  const gen = JSON.parse(
    readFileSync(fileURLToPath(new URL('./sidebar.generated.json', import.meta.url)), 'utf-8')
  ) as GeneratedNav
  sidebar = gen.sidebar ?? {}
  modules = gen.modules ?? []
} catch {
  // 尚未生成（首次 clone 直接跑 vitepress）——侧栏为空，跑一次 gen 脚本即可
}

// ---------- 四支柱导航（分组依据 README「能力支柱视图」） ----------
const PILLARS = [
  { key: 'platform', text: '云原生平台' },
  { key: 'devops', text: 'DevOps 工程' },
  { key: 'observability', text: '可观测与 SRE' },
  { key: 'aiops', text: 'AIOps' },
]

const nav = [
  { text: '首页', link: '/' },
  { text: '学习路线图', link: '/ROADMAP.html' },
  { text: '场景速查', link: '/SCENARIOS.html' },
  ...PILLARS.map((p) => ({
    text: p.text,
    items: modules
      .filter((m) => m.pillar === p.key)
      .map((m) => ({ text: m.title, link: m.link })),
  })).filter((g) => g.items.length > 0),
]

// ---------- 内容兼容层（不改动任何内容 md） ----------
// 两个已知坑（根因相同：表格单元格里「反引号代码段包含 |」会把单元格截断，
// 使 Jinja2/shell 片段裸露在正文里，GitHub 渲染时只是显示难看，但 VitePress 会先过
// Vue 模板编译而直接报错）：
//   1. `{{ ... }}`（Jinja2/docker --format）被当成 Vue 插值表达式；
//   2. `<res>` `<ns>` 等占位符被当成未闭合的 HTML 标签。
// 处理：对 markdown 渲染结果统一做转义——{{ -> &#123;&#123;（浏览器解码后显示不变，
// 但 Vue 模板编译器不再识别为插值）；非标准 HTML 标签 -> &lt;...&gt;。
const KNOWN_HTML_TAGS = new Set(
  (
    'a abbr acronym address area article aside b base bdi bdo big blockquote body br ' +
    'button caption center cite code col colgroup dd del details dfn dialog div dl dt ' +
    'em fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 head header hr html i ' +
    'img input ins kbd label legend li main map mark menu meta nav ol optgroup option p ' +
    'param picture pre q rp rt ruby s samp section select slot small source span strike ' +
    'strong style sub summary sup table tbody td template textarea tfoot th thead time ' +
    'title tr track tt u ul var video wbr'
  ).split(' ')
)

function escapeUnknownTags(html: string): string {
  return html.replace(
    /<(\/?)([a-zA-Z][a-zA-Z0-9-]*)([^<>]*?)(\/?)>/g,
    (raw, _slash: string, name: string) =>
      KNOWN_HTML_TAGS.has(name.toLowerCase()) ? raw : `&lt;${raw.slice(1)}`
  )
}

// ---------- 中文可用的本地搜索分词 ----------
// MiniSearch 默认按空白/标点切词，中文整句会变成一个 token，搜不到子串。
// 这里在默认行为之上补充「单汉字 + 相邻二字词」，使中文子串检索可用。
const isCJKRun = (s: string) => /^[一-鿿]+$/.test(s)

function tokenize(text: string): string[] {
  const tokens: string[] = []
  for (const seg of text.split(/([一-鿿]+)/)) {
    if (!seg) continue
    if (isCJKRun(seg)) {
      for (let i = 0; i < seg.length; i++) {
        tokens.push(seg[i])
        if (i + 1 < seg.length) tokens.push(seg.slice(i, i + 2))
      }
    } else {
      for (const w of seg.split(/[^0-9A-Za-z_]+/)) if (w) tokens.push(w.toLowerCase())
    }
  }
  return tokens
}

export default defineConfig({
  lang: 'zh-CN',
  title: 'Learning Hub · 云原生 SRE 学习中心',
  description:
    '15 个模块的云原生 SRE 系统学习资料：Linux 底座、容器、Kubernetes、CI/CD 与 GitOps、可观测（Prometheus/OpenTelemetry/日志）、中间件、SRE 方法论与 AIOps，面向 CKA / CKS / PCA 三证。',

  // GitHub Pages 项目页：<user>.github.io/sre-learning-hub/
  base: '/sre-learning-hub/',

  // 内容直接用仓库根：docs/ 只放 index.md 与 .vitepress/
  srcDir: '..',
  rewrites: {
    'docs/index.md': 'index.md',
  },
  // 排除：内部规划/调研资料（_meta 含本地凭据文件）、不入库的题库手册；
  // portal/ 下无 .md，无需排除
  srcExclude: ['_meta/**', '**/question-bank-manual*.md'],
  // 正文引用了「gitignore 排除的题库手册」「_meta 调研」等 CI 中不存在的文件，
  // 内容 md 又不允许改动，因此关闭死链校验
  ignoreDeadLinks: true,

  markdown: {
    lineNumbers: true,
    config(md) {
      // 渲染结果统一过兼容层（{{ 转义 + 非标准标签转义，见文件顶部说明）
      const origRender = md.render.bind(md)
      md.render = (src: string, env: any) =>
        escapeUnknownTags(origRender(src, env)).replace(/\{\{/g, '&#123;&#123;')
    },
  },

  themeConfig: {
    siteTitle: 'Learning Hub',

    nav,
    sidebar,

    search: {
      provider: 'local',
      options: {
        translations: {
          button: {
            buttonText: '搜索文档',
            buttonAriaLabel: '搜索文档',
          },
          modal: {
            noResultsText: '没有找到相关结果',
            resetButtonTitle: '清空搜索词',
            footer: {
              selectText: '选择',
              navigateText: '切换',
              closeText: '关闭',
            },
          },
        },
        miniSearch: {
          options: { tokenize },
          searchOptions: { tokenize },
        },
      },
    },

    outline: 'deep',

    socialLinks: [{ icon: 'github', link: repoUrl }],

    docFooter: {
      prev: '上一篇',
      next: '下一篇',
    },
    returnToTopLabel: '回到顶部',
    sidebarMenuLabel: '菜单',
    darkModeSwitchLabel: '外观',
    lightModeSwitchTitle: '切换到浅色模式',
    darkModeSwitchTitle: '切换到深色模式',

    editLink: {
      pattern: `${repoUrl}/edit/main/:path`,
      text: '在 GitHub 上编辑此页',
    },

    footer: {
      message: '基于 MIT 许可发布，文档采用 CC BY-NC-SA 4.0。',
      copyright: 'Learning Hub · 云原生 SRE 学习中心',
    },
  },
})
