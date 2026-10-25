import { defineConfig } from 'vitepress'

const repo = 'https://github.com/kenta3578/sarari'

// docs/ の Markdown をそのままサイトにする。ファイル名は GitHub 上のリンクと揃えたまま、
// URL だけ小文字に写す（rewrites）。
export default defineConfig({
  lang: 'ja',
  title: 'sarari',
  description: '完全ローカルで動く、Mac 用の日本語音声入力アプリ',
  base: '/sarari/',
  cleanUrls: true,
  lastUpdated: true,
  // アプリアイコンと同じ絵（scripts/make-icon.sh が docs/public/ に置く）。head の href には base が付かない
  head: [['link', { rel: 'icon', type: 'image/svg+xml', href: '/sarari/logo.svg' }]],
  // サイトは使う人向けの説明書だけにする。docs/README.md（フォルダの目次）と、
  // コードを読む人向けの文書は GitHub 上で読んでもらう
  srcExclude: [
    'README.md',
    'ARCHITECTURE.md',
    'SWIFT-NOTES.md',
    'design-rationale.md',
    'engine-benchmark.md',
    'scenarios.md',
  ],
  rewrites: {
    'MANUAL.md': 'manual.md',
    'PRIVACY.md': 'privacy.md',
  },
  markdown: {
    // docs/ の外（../Tests/README.md や ../presets/engineer.json）への相対リンクはサイトに無いので、
    // GitHub 上のファイルへ向け直す。Markdown 自体は GitHub で読めるよう相対リンクのまま置いておく。
    config(md) {
      const render = md.renderer.rules.link_open
      md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
        const href = tokens[idx].attrGet('href')
        if (href?.startsWith('../')) {
          tokens[idx].attrSet('href', `${repo}/blob/develop/${href.slice(3)}`)
        }
        return render ? render(tokens, idx, options, env, self) : self.renderToken(tokens, idx, options)
      }
    },
  },
  themeConfig: {
    logo: '/logo.svg',
    nav: [
      { text: '説明書', link: '/manual' },
      { text: '更新履歴', link: '/changelog' },
    ],
    sidebar: [
      { text: '説明書', link: '/manual' },
      { text: '更新履歴', link: '/changelog' },
      { text: 'プライバシー', link: '/privacy' },
    ],
    outline: { level: [2, 3], label: 'このページの内容' },
    socialLinks: [{ icon: 'github', link: repo }],
    editLink: { pattern: `${repo}/edit/develop/docs/:path`, text: 'このページを GitHub で直す' },
    search: {
      provider: 'local',
      options: {
        // MiniSearch は空白と記号で語を切るので、空白のない日本語は文ごと1語になり、
        // 文の途中の語で引けない。日本語の連なりは2文字ずつ重ねて切る（bi-gram）。
        // 関数は文字列にしてブラウザへ渡されるので、外の変数を参照しないこと。
        miniSearch: {
          options: {
            tokenize: (text: string) => {
              const tokens: string[] = []
              const cjk = /[\p{scx=Han}\p{scx=Hira}\p{scx=Kana}]+/u
              for (const word of text.match(/[\p{L}\p{N}_]+/gu) ?? []) {
                for (const run of word.split(/([\p{scx=Han}\p{scx=Hira}\p{scx=Kana}]+)/u)) {
                  if (!run) continue
                  if (!cjk.test(run) || run.length === 1) {
                    tokens.push(run)
                    continue
                  }
                  for (let i = 0; i < run.length - 1; i++) tokens.push(run.slice(i, i + 2))
                }
              }
              return tokens
            },
          },
          searchOptions: { combineWith: 'AND', fuzzy: false },
        },
        translations: {
          button: { buttonText: '検索', buttonAriaLabel: '検索' },
          modal: {
            noResultsText: '見つかりませんでした',
            resetButtonTitle: '消す',
            footer: { selectText: '開く', navigateText: '移動', closeText: '閉じる' },
          },
        },
      },
    },
    docFooter: { prev: '前へ', next: '次へ' },
    lastUpdated: { text: '最終更新' },
    darkModeSwitchLabel: '外観',
    sidebarMenuLabel: 'メニュー',
    returnToTopLabel: '上に戻る',
  },
})
