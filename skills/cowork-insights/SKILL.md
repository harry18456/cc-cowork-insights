---
name: cowork-insights
description: Run the REAL built-in /insights engine on this machine's Claude Desktop / Cowork sessions only — same engine, same pipeline, same report template, same 30-day window; two deviations — sources curated to Cowork-only, and the advice sections' feature guidance retargeted to Cowork's real mechanisms (Claude app Settings, not CLI/dotfiles). Also offers an instant in-chat summary (tokens incl. prompt cache, sessions, models, friction) when the user just wants numbers fast. Strictly read-only on transcripts. Use this whenever the user asks about Cowork usage, cost, tokens, session statistics, or wants Cowork usage reviewed — e.g. "Cowork 用了多少 token", "幾個 Cowork session", "Cowork 用量分析 / 使用統計 / insights", "Cowork 用得怎麼樣 / 幫我分析 Cowork 使用狀況" — or complains that the built-in /insights cannot see Cowork sessions. Host-side only.
allowed-tools: Bash(python:*), Bash(py:*), Read
---

# Cowork Insights

產出這台機器的 **Cowork-only 用量報告**(排除純 CLI / SDK / VS Code session):session 數與型態、四欄位 token 併計、模型與工具分布、完整歷史——不受內建 `/insights` 的 30 天分析窗與啟動清理(`cleanupPeriodDays` 會物理刪檔)限制。聚合器**只讀**既有 JSONL,不寫入、不修改任何 session 檔。

## 1. 前置檢查

此 skill 只能在 **host 端**(一般 Claude Code、或桌面 app 掛載資料夾模式)執行。若目前工作目錄位於 `local-agent-mode-sessions` 樹下,表示正在 Cowork 隔離沙箱內——沙箱只看得到自己的 transcript,報告會近乎空白。這種情況直接告訴使用者要回 host 端跑,不要繼續執行。

## 2. 執行聚合器

script 位於本 skill 目錄下的 `scripts/cowork_insights.py`(skill 載入時系統會標出 base directory,用它組出絕對路徑):

```bash
python "<skill-base-dir>/scripts/cowork_insights.py" [輸出目錄]
```

- **分析視窗寫死 30 天,與原生一致**(script 預設即 30;只有使用者明確要求不同期間才用 `--days N|all`——那是原生做不到的加值)。本工具**絕不刪除任何檔案**(內建工具的啟動清理會實體刪檔,這是兩回事)。
- 輸出目錄的決定順序——把**第一個顯示為實際路徑**的傳給 script;顯示成 `${...}` 字面或空白就跳過該項:
  1. 使用者本次指定的位置
  2. 啟用 plugin 時設定的 output_dir:`${user_config.output_dir}`
  3. plugin 持久資料目錄:`${CLAUDE_PLUGIN_DATA}`(目錄字尾隨安裝來源而異:marketplace 名 / `inline` / `skills-dir`)
  4. 都沒有 → 不傳參數,script 自選(marketplace 安裝→plugin data dir;否則 `~/.claude/usage-data/cowork-insights/`)。**任何情況都不會寫進當下專案目錄**。
- `python` 不存在時改試 `py`。
- 特殊環境可用環境變數覆寫:`CLAUDE_CONFIG_DIR`(host config dir)、`CLAUDE_COWORK_ROOT`(明確指定 LAMS 樹路徑)。

script 的判別邏輯(已對實際檔案系統驗證):掃 host projects 樹 + Cowork(local-agent-mode-sessions,下稱 LAMS)樹,session 判別器為 `entrypoint ∈ {local-agent, claude-desktop}` **或** 檔案位於 LAMS 樹下;先排除單行 `ai-title` 雜檔;`audit.jsonl` 全數排除(與 transcript 記錄同一批 API 呼叫,計入會重複);`subagents/*.jsonl` 計入 token 總量但不算 session 數。

## 3. 產出報告——照原生 `/insights` 的管線

本 skill 的 `assets/native/` 內含**從內建 /insights 引擎抽出的全套 prompt 與報告模板**(來源、版本與 Cowork 改寫紀錄見 `assets/native/provenance.md`;7 個 section prompt 中 5 個逐字不變,`suggestions` 的功能查表與 `on_the_horizon` 的工具提示已改指 Cowork 實際可行途徑——app 設定,而非 CLI/dotfiles)。使用者要報告時照原生管線執行,來源已被 collector 整理成 Cowork-only:

1. **Facet 抽取**:讀 `assets/native/facet-prompt.txt`。對 `cowork_digest.json` 列出的每個 session 平行派 subagent(用快的模型即可,與原生相同的省錢邏輯),每個 subagent Read 該 session 的 transcript(digest `file` 欄位;過長就先按 `chunk-summary-prompt.txt` 分段摘要再抽),回傳 facet JSON(underlying_goal / outcome / brief_summary / goal_categories / user_satisfaction_counts / friction_counts / claude_helpfulness / friction_detail / user_instructions_to_claude)。存到輸出目錄 `facets/`。
2. **組 DATA**:照 `assets/native/data-assembly-spec.js.txt` 的規格——aggregate 統計(sessions、date_range、messages、top_tools、top_goals、outcomes、satisfaction、friction、languages)+ 最多 50 條 session 摘要 + 最多 20 條 friction 細節 + 最多 15 條 user instructions。
3. **章節合成**:`assets/native/section-prompts.txt` 內 7 個 prompt(project_areas、interaction_style、what_works、friction_analysis、suggestions、on_the_horizon、fun_ending)各接同一份 DATA,平行執行,各回 JSON。
4. **At-a-Glance**:跑 `assets/native/at-a-glance-prompt.txt`(吃前面所有 section 輸出)。
5. **渲染**:把結果填進 `assets/native/report-template.html` 的 `{{TOKEN}}`,statistics 列與兩張 bar chart 用 collector 的量化數字,寫到輸出目錄 `cowork_report.html`,開給使用者並附路徑。

**建議內容環境守則(報告與輕量替代皆適用)**:凡「建議使用者接下來怎麼做」的內容(features_to_try、quick wins、how_to_try、claude_md_additions 等),只能指向 Cowork 實際可行途徑——Claude app 的 Settings(Connectors / Skills / Plugins / Cowork > Global instructions)或直接請 Claude 做;不得出現 CLI-only 機制(`claude mcp add`、`.claude/` 與 `~/.claude` 檔案、`claude -p`、hooks)。渲染前發現就改寫成 Cowork 對應途徑。**描述歷史事件不受此限**:session 本身若在操作那些路徑(例如測試 `.claude/skills`),照實描述即可。

**輕量替代**(使用者趕時間、或只想在對話裡看):跳過 subagent 管線,直接讀 `cowork_digest.json` 在對話中依同樣章節輸出摘要,並附量化重點(session 數、四欄位 token 與 **cache 佔比**——通常 ~99%,只看 input+output 會低估約百倍;audit 一致性檢查結果,不相等要警告佈局漂移)。

## 4. 100% 原廠路徑(選用)

內建 `/insights` 是互動限定的 builtin 指令(`-p` 不展開),想跑「原廠引擎親自出的報告」:

```bash
python "<skill-base-dir>/scripts/cowork_insights.py" <out> --stage <out>/stage
```

然後請使用者把 `~/.claude/.claude.json` 與 `~/.claude/.credentials.json` 複製進 `<out>/stage/`,互動啟動 `CLAUDE_CONFIG_DIR=<out>/stage claude` 並輸入 `/insights`;報告會在 `<out>/stage/usage-data/report.html`。**跑完提醒使用者刪除 stage 裡的憑證副本。**

此路徑的報告是**原廠 CLI 視角**:其建議章節(features/suggestions)教的是 CLI 作法(`claude mcp add`、`.claude/` 檔案、hooks、headless),在 Cowork 沙箱內無法執行——Cowork 對應途徑是 Claude app 的 Settings(Connectors / Skills / Plugins / Cowork > Global instructions)。交報告時要提醒使用者這點。

## 4b. 與內建 /insights 的關係

同引擎同管線同模板同 30 天窗;差異有二:(1) 來源(Cowork-only vs host 全量——內建看不到隔離型 Cowork);(2) 建議章節的功能指引已改指 Cowork 的 app 設定途徑(原生查表教 CLI 作法,在 Cowork 無法執行)。使用者要「整台機器全部 session」的分析時,指回內建 `/insights`。

## 5. 疑難排解

找不到 LAMS 樹、數字明顯異常、audit 一致性警告、或想驗證判別器邏輯時,讀本 skill 的 `references/cowork-log-layout.md`——內含實體路徑速查(MSIX 重導向)、三種執行模式對照、檔案角色(transcript / audit / subagent)、歷史踩雷紀錄(Python glob 預設跳過 dot 目錄)與漂移排查步驟。
