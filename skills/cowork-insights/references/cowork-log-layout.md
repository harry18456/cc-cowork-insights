# Cowork Log 佈局速查(排錯用)

來源:`claude-cowork-study` 研究(2026-07-04,勘誤 2026-07-09,audit 發現與 v2 修正 2026-07-11)。
以 Claude Code v2.1.197 / Windows MSIX 版 Claude Desktop 實測;內部結構未文件化,版本更新可能漂移。

## 實體路徑

| 用途 | 路徑 |
|---|---|
| Cowork 實體根(LAMS) | `%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude\local-agent-mode-sessions\` |
| host config dir | `%USERPROFILE%\.claude\`(或 `CLAUDE_CONFIG_DIR`) |
| host projects | `<config_dir>\projects\` |

MSIX 虛擬化:程式內部視角的 `%APPDATA%\Claude\...` 實體上被重導向到上表 LocalCache 路徑。直接在檔案總管開 `%APPDATA%\Claude\local-agent-mode-sessions` 會找不到,是正常的。

## LAMS 樹頂層結構(勘誤重點)

```
local-agent-mode-sessions\
  <accountUuid>\<orgUuid>\          ← 頂層兩組 UUID 是「帳號 + org」,不是執行模式
    local_<session-uuid>\
      audit.jsonl                   ← 稽核副本(見下)
      .claude\projects\<slug>\
        <session-uuid>.jsonl        ← 真正的 transcript
        <session-uuid>\subagents\agent-*.jsonl
      outputs\                      ← session 工作目錄
```

若要做公司/個人帳號分離統計,先按頂層 `accountUuid` 切開再各自聚合。

## 三種執行模式

| 模式 | entrypoint | 落點 |
|---|---|---|
| VM(舊) | `local-agent` 或無欄位 | LAMS 樹,cwd 為 `/sessions/<codename>` |
| 本機隔離 | `local-agent` | LAMS 樹,cwd 為 `...\local_<uuid>\outputs` |
| 掛載資料夾 | `claude-desktop` | **host projects 樹**(與 CLI session 混居) |

判別器(實測 0 漏 0 誤):`entrypoint ∈ {local-agent, claude-desktop}` ∪ 「檔案位於 LAMS 樹下」,前置排除單行 `ai-title` 雜檔。同一個 slug 目錄會混多種來源,必須逐檔看 entrypoint,不能只看目錄。

> **2026-07-16 勘誤**:上行「0 漏 0 誤」只對本機成立——本機桌面 app 恰好只用 Cowork,沒有負樣本。他機實證:桌面 **Code 分頁** session 同樣寫 `entrypoint=claude-desktop`,此判準無法區分兩者。自 v0.4.0 起「收錄」與「確定」分離:收錄判準不變,另對每個 session 標 `cowork_confidence`——LAMS 樹或 `local-agent` = `confirmed`;host 樹 `claude-desktop` = `ambiguous`,由使用者判讀(SKILL.md 第 2b 節)。

## 檔案角色(2026-07-11 確立)

| 檔案 | 角色 | 計量處理 |
|---|---|---|
| `<uuid>.jsonl` | transcript,權威來源 | session + token 都計 |
| `audit.jsonl` | 每個隔離 session 一份的稽核副本:同一批 API 呼叫(message id 完全交集、input/cache 欄位相同),但 output_tokens 是被截斷的串流快照 | **全排除**;僅用於 1:1 一致性自檢 |
| `subagents/agent-*.jsonl` | 子代理呼叫,usage 不在父 transcript 內 | token 計、session 不計 |

## 歷史踩雷

1. **Python `glob` 的 `**` 預設不進入 `.` 開頭目錄**。transcript 藏在 `local_*/.claude/projects/` 下,v1 用 glob 因此一個真 transcript 都沒讀到,誤把 audit.jsonl 當 session(數量恰好 1:1 所以表面看不出來)。v2 改用 `os.walk`。
2. 原生 `/insights` 分析窗硬寫死 30 天,且啟動時 `cleanupPeriodDays`(預設 30)會**物理刪除** mtime 逾期檔——複製舊檔進 config dir 也會被砍。
3. 掛載型 session 的 host 樹裡混有 subagent 檔,不濾會灌水 session 數。

## 漂移排查步驟

audit 一致性警告(audit 檔數 ≠ 隔離 session 數)或數字異常時:

1. 抽最新的 `local_<uuid>` 目錄,確認 transcript 是否仍在 `.claude/projects/<slug>/` 下、`entrypoint` 欄位是否還存在。
2. 抽一對 audit / transcript,比對 assistant usage 的 message id 是否仍重疊(重疊 = audit 仍是副本,繼續排除;不重疊 = 計量規則要重新驗證)。
3. 檢查是否出現新的 jsonl 檔種(比照 audit.jsonl 當年的出現方式)。
4. 確認掛載型 entrypoint 是否仍為 `claude-desktop`(桌面 app 各分頁共用同一後端,此值不區分 Code / Cowork 分頁)。
5. `cowork_confirmed.sessions` 為 0 但 ambiguous 很多:**不是漂移**——該機器可能只用桌面 Code 分頁、從未用過 Cowork;走 SKILL.md 第 2b 節問使用者,不要當資料異常排查。
