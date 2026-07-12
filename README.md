# cowork-insights

問 Claude「**我的 Cowork 用了多少 token?**」或「**幫我分析 Cowork 用得怎麼樣**」,就能拿到這台機器的 **Cowork-only 分析** —— 跟內建 `/insights` 同級的兩層報告,差別只在來源整理成 Cowork-only、視窗可調。

- **就是原生 /insights 的管線,只換來源**:skill 內含從內建引擎逐字抽出的全套 prompt(facet 抽取、7 個章節合成、At-a-Glance)與同款報告模板(`skills/cowork-insights/assets/native/`,來源見其 `provenance.md`)——分析流程與產出版式與原版一致,唯一差異是來源被整理成 Cowork-only
- **30 天窗與原生一致(寫死)**:數字可直接對照;進階需求才用 `--days N|all` 拉長(原生做不到)。本工具純唯讀——內建的啟動清理會實體刪除逾期 transcript,我們不動任何檔案
- **唯讀、零依賴、不連網**:純 Python stdlib,只讀既有 session JSONL
- **計量正確**:四欄位 token 併計(prompt cache 通常佔 ~99%,只算 input+output 會低估約 100 倍);`audit.jsonl` 稽核副本自動排除避免重複計量;subagent 用量計入 token 但不灌水 session 數
- **漂移自檢**:audit 檔數 ↔ 隔離 session 數 1:1 一致性檢查(恆為全母體、不受視窗影響),Claude Desktop log 佈局改版時會出警告而不是默默給錯數字

> ⚠️ **僅在 Windows(MSIX 版 Claude Desktop)驗證**。LAMS 路徑偵測依賴 `%LOCALAPPDATA%` / `%APPDATA%`;其他平台可用 `CLAUDE_COWORK_ROOT` 環境變數手動指定。需要 Python 3(建議 3.10+)。

## 安裝

```
/plugin marketplace add harry18456/cc
/plugin install cowork-insights@harry18456
```

重開 Claude Code 生效。啟用時會詢問報告輸出目錄(可留空,見下方預設落點)。

### 本機立即使用(免 push、免 marketplace)

把 repo 以 junction 連到 skills 目錄,下個 session 就自動以 `cowork-insights@skills-dir` 載入:

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\cowork-insights" -Target "D:\side_project\cc-cowork-insights"
```

> ⚠️ 之後改從 marketplace 正式安裝前,先移除這個 junction(`Remove-Item $env:USERPROFILE\.claude\skills\cowork-insights`),避免同名 skill 重複載入。

## 使用

裝好後直接用自然語言問即可(skill 會自動觸發):

- 「跑一份 Cowork insights」→ 產出與原生同款的 `cowork_report.html`(30 天窗)
- 「Cowork 用了多少 token?」→ 對話內快速量化(cache 佔比、audit 自檢)
- 「幫我分析 Cowork 用得怎麼樣?」→ 對話內兩層摘要(趕時間版)
- 進階:「看過去 90 天 / 完整歷史」(`--days`,原生做不到)

想跑「100% 原廠引擎親自出的報告」:`--stage` 會把 Cowork 來源整理成獨立 config dir,複製 `.claude.json` 與 `.credentials.json` 進去後,互動啟動 `CLAUDE_CONFIG_DIR=<stage> claude` 輸入 `/insights` 即可(內建指令為互動限定,`-p` 不展開;**用完記得刪除 stage 內的憑證副本**)。

也可手動指定輸出目錄:「跑 cowork insights,結果放到 `D:\reports`」。

產出:對話內報告 + 三個檔案 —— `cowork_full.json`(逐 session 明細)、`cowork_digest.json`(質化分析用的來源整理)、`cowork_insights.html`(可開瀏覽器看)。

報告檔預設落點:plugin 的持久資料目錄(官方 `${CLAUDE_PLUGIN_DATA}`),即 `~\.claude\plugins\data\cowork-insights-<來源>\` —— **目錄字尾隨安裝來源而異**:marketplace 安裝是 `-harry18456`、`--plugin-dir` 載入是 `-inline`、skills-dir 是 `-skills-dir`;plugin 更新不會清掉這裡。啟用時若在 output_dir 設定了位置則優先;非 plugin 情境 fallback 到 `~\.claude\usage-data\cowork-insights\`。**不會寫進你當下的專案目錄**。

> ⚠️ **解除安裝會順帶刪掉資料目錄**(裡面的報告一起消失)。想保留報告用 `claude plugin uninstall cowork-insights --keep-data`,或啟用時把 output_dir 設到自己的資料夾。

## 測試

不經 Claude 直接跑 script(應印出 JSON summary 並寫出兩個報告檔):

```
python "<plugin>/skills/cowork-insights/scripts/cowork_insights.py" %TEMP%\cowork-test
```

## 注意事項

- **只能在 host 端跑**:Cowork 隔離沙箱內看不到其他 session,報告會近乎空白;skill 內建此檢查。
- **與內建 `/insights` 的分工**:分析類型相同(量化+質化),本工具只看 Cowork 來源、視窗可調;要「整台機器全部 session」的分析請用內建 `/insights`。
- **隱私**:報告含各 session 的 cwd 路徑;分享報告檔前先確認。
- **版本漂移**:Claude Desktop 的 log 內部結構未文件化(以 v2.1.197 實測),更新後若出現 audit 一致性警告,見 skill 內 `references/cowork-log-layout.md` 的排查步驟。

## 這個 plugin 的組件

目前只用了 **skills**(`skills/cowork-insights/`,Claude Code 自動發現、不必在 plugin.json 宣告)。`commands/`、`agents/`、`hooks/`、`output-styles/`、`bin/` 為預留骨架,日後擴充直接放檔案即可。
