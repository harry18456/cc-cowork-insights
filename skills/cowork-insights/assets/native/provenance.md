# 來源與注意事項

本資料夾內容抽取自 Claude Code **v2.1.207** 內建 `/insights` 引擎(`claude.exe` 內嵌 JS 模組,
匯出名 `generateUsageReport` / `buildInsightsResponsePrompt` / `aggregateData` 等),2026-07-11 抽取。

| 檔案 | 對應原始碼 | 用途 |
|---|---|---|
| `facet-prompt.txt` | `tW_` | 每個 session 的結構化 facet 抽取(goal/satisfaction/friction) |
| `chunk-summary-prompt.txt` | `lW_` | 過長 transcript 的分段摘要 |
| `section-prompts.txt` | `gW_` 陣列 | 7 個報告章節的合成 prompt(project_areas / interaction_style / what_works / friction_analysis / suggestions / on_the_horizon / fun_ending),各 maxTokens 8192 |
| `at-a-glance-prompt.txt` | `yW_` 內聯 | 最終 At-a-Glance 統整(吃前面所有 section 輸出) |
| `data-assembly-spec.js.txt` | `yW_` 前段 | 餵給 section prompt 的 DATA 組裝規格:aggregate JSON + 前 50 條 session 摘要 + 前 20 條 friction 細節 + 前 15 條 user instructions |
| `report-template.html` | `AW_` 渲染輸出 | 與原生報告同 CSS/結構的骨架,`{{TOKEN}}` 為填充點 |

原生管線:掃描(30 天窗,`Date.now()-days*86400e3`,依檔案 mtime)→ 逐 session facet 抽取(快取於
`usage-data/facets/`)→ 程式端彙總 → 7 個 section 平行合成 → At-a-Glance → 填模板寫
`usage-data/report.html`。

**注意**:
1. 這是未文件化的內部實作,Claude Code 改版時可能變動;版本升級後若報告品質異常,重新照
   `claude-cowork-study` 研究 repo 的方法從新版 exe 重抽。
2. 內容屬 Anthropic 的產品實作。個人使用無虞;**公開發佈本 repo 前留意這個資料夾的再散布問題**
   (可改為安裝時從使用者本機 exe 現抽)。
3. 內建 `/insights` 為互動模式限定(builtin prompt command,`-p` 不展開)。要跑「100% 原廠」:
   `cowork_insights.py <out> --stage <dir>` 後,互動啟動 `CLAUDE_CONFIG_DIR=<dir> claude` 並輸入
   `/insights`(需自行複製 `.claude.json` 與憑證進 `<dir>`,用完刪除憑證副本)。

## Cowork 改寫紀錄(對逐字抽出內容的偏離)

2026-07-13。原生 `suggestions` prompt 內嵌的功能查表教的是 CLI 作法(`claude mcp add`、
`.claude/skills/` 檔案、`settings.json` hooks、headless),在 Cowork 全數無法執行——本機實測
(`cowork-skill-study` 的 skill-level-test-report):Cowork 沙箱未掛載 `~/.claude`,連接資料夾的
`.claude/skills/` 非技能掃描來源;skills/connectors/plugins 一律由 Claude app 的 Settings 安裝,
session 啟動時凍結(重啟才載入);global 指示位於 Claude app > Settings > Cowork > Global
instructions(非 `~/.claude/CLAUDE.md`);Scheduled tasks 與 Trusted Cowork folders 為 app 層功能
(Settings > Cowork,均經 app 畫面確認)。

改動清單(改版重抽 prompt 後需重套):

1. `section-prompts.txt` / `suggestions`:`CC FEATURES REFERENCE` 整塊換成
   `COWORK FEATURES REFERENCE`(Connectors / Skills / Plugins / Task Agents / Scheduled tasks /
   Trusted Cowork folders,表頭含「可能已安裝/受 admin 管控」但書);`claude_md_additions` 的
   `addition` 與 `prompt_scaffold` 改指 Settings > Cowork > Global instructions;`example_code`
   欄位說明改為「Settings 路徑或操作」(**JSON key 全部不動**,渲染鏈不受影響);結尾
   `Pick 2-3 from the CC…` 改指新表名。
2. `section-prompts.txt` / `on_the_horizon`:`how_to_try` 欄位說明加環境限定子句
   (app Settings 或直接請 Claude;非 CLI/dotfiles)。
3. `report-template.html`:`<h3>Suggested CLAUDE.md Additions</h3>` →
   `<h3>Suggested Global Instructions (Claude app &gt; Settings &gt; Cowork)</h3>`。
4. `report-template.html` / Cowork 措辭:nav 連結「How You Use CC」與章節標題
   `<h2>How You Use Claude Code</h2>` → 均改為「How You Use Cowork」。
5. `report-template.html` / 重建骨架時的簡化(2026-07-22 對 v2.1.216 復核時補記;
   非 Cowork 語義改寫,是抽取當時的取捨):
   - 原生硬寫的 `<title>`/`<h1>`「Claude Code Insights」與 subtitle 組字改為
     `{{TITLE}}`/`{{SUBTITLE}}` 填充點;
   - 移除原生的 Google Fonts `<link>` 外連(報告須離線可開、不打外網);
   - 移除 `<h3>` 下方的「Just copy this into Claude…」說明段;
   - CSS 取原生 109 條規則中的 76 條(未收 copy 按鈕 / checkbox / feedback 卡片 /
     collapsible / feature-example 等互動樣式——本管線產出靜態報告用不到);
   - body 字型堆疊補了 `'Segoe UI'`。

其餘全部維持逐字:`facet-prompt`、`chunk-summary-prompt`、`at-a-glance-prompt`、
`data-assembly-spec`、另 5 個 section prompt(project_areas / interaction_style / what_works /
friction_analysis / fun_ending)。模板為同 CSS 骨架與章節結構的快照,逐項偏離以上面
3–5 為完整清單。

## 漂移復核紀錄

- **2026-07-22 vs Claude Code v2.1.216**(對 exe 內嵌 bundle 逐 byte 比對):
  - prompt 層零漂移——facet / chunk-summary / at-a-glance / 未改寫的 5 個 section
    prompt / 兩個 enum 逐字相同(facet 與 chunk 檔尾多一個空行:原生字串在該處收尾、
    引擎於其後續接 transcript 內容,實質等價);`suggestions` 與 `on_the_horizon`
    對原生的全部差異即上方改動清單,JSON key 一致。
  - minified 符號名已改(`yW_`→`Be_`、`_W_`→`je_`、`bW_`→`We_`),重抽時請以
    prompt 內文錨點(如首句)搜尋定位,勿依符號名。
  - 原生報告模板已擴充(Lines/Files/Days 統計列、Languages / Session Types /
    Response Time / Multi-Clauding / Time of Day 圖表、Team Feedback 區塊、
    copy/collapsible 互動)。本資料夾模板維持 v2.1.207 世代快照,質性七章節 +
    At-a-Glance 佈局仍與原生對齊,skill 管線不受影響;想跟上新版樣式需整套重抽。
