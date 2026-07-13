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

其餘全部維持逐字:`facet-prompt`、`chunk-summary-prompt`、`at-a-glance-prompt`、
`data-assembly-spec`、另 5 個 section prompt(project_areas / interaction_style / what_works /
friction_analysis / fun_ending)、模板其他部分。
