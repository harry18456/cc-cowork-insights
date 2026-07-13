English | [繁體中文](README.zh-TW.md)

# cowork-insights

Ask Claude "**how many tokens has my Cowork used?**" or "**analyze how I've been using Cowork**" and get a **Cowork-only analysis** for this machine — a two-layer report on par with the built-in `/insights`, differing only in that sources are curated to Cowork and the window is adjustable.

- **It IS the native /insights pipeline — only the sources and the advice targeting change**: the skill ships the full prompt set extracted from the built-in engine (facet extraction, the 7 section-synthesis prompts, At-a-Glance) plus the same report template (`skills/cowork-insights/assets/native/`; see its `provenance.md` for origins and the modification log). The analysis flow and output layout match the original; 5 of the 7 section prompts are verbatim, while the feature lookup table in `suggestions` and the tool tips in `on_the_horizon` are retargeted to what is actually actionable in Cowork (Claude app Settings — not CLI commands/dotfiles, since the Cowork sandbox cannot read `~/.claude` and the native CLI approaches don't work there)
- **30-day window matches native (hard-coded)**: numbers are directly comparable; only reach for `--days N|all` for advanced needs (something native can't do). This tool is strictly read-only — the built-in startup cleanup physically deletes expired transcripts; we never touch any files
- **Read-only, zero-dependency, no network**: pure Python stdlib, only reads existing session JSONL files
- **Correct accounting**: sums all four token fields (prompt cache is usually ~99%; counting only input+output underestimates by ~100×); `audit.jsonl` audit copies are auto-excluded to avoid double counting; subagent usage counts toward tokens without inflating session counts
- **Drift self-check**: a 1:1 consistency check between audit file count and isolated session count (always over the full population, unaffected by the window) — if a Claude Desktop update changes the log layout, you get a warning instead of silently wrong numbers

> ⚠️ **Only verified on Windows (MSIX Claude Desktop)**. LAMS path detection relies on `%LOCALAPPDATA%` / `%APPDATA%`; on other platforms point the `CLAUDE_COWORK_ROOT` environment variable at the right place manually. Requires Python 3 (3.10+ recommended).

## Installation

```
/plugin marketplace add harry18456/cc
/plugin install cowork-insights@harry18456
```

Restart Claude Code to take effect. On enable it asks for a report output directory (may be left empty; see the default location below).

### Use locally right away (no push, no marketplace)

Junction the repo into the skills directory and the next session auto-loads it as `cowork-insights@skills-dir`:

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\.claude\skills\cowork-insights" -Target "D:\side_project\cc-cowork-insights"
```

> ⚠️ Before switching to a proper marketplace install later, remove this junction first (`Remove-Item $env:USERPROFILE\.claude\skills\cowork-insights`) to avoid loading the same-named skill twice.

## Usage

Once installed, just ask in natural language (the skill triggers automatically):

- "Run a Cowork insights report" → produces `cowork_report.html` in the same format as native (30-day window)
- "How many tokens has Cowork used?" → quick in-chat numbers (cache share, audit self-check)
- "Analyze how I've been using Cowork" → two-layer in-chat summary (the in-a-hurry version)
- Advanced: "look at the past 90 days / the full history" (`--days`, which native can't do)

Want a report "produced 100% by the factory engine itself"? `--stage` curates the Cowork sources into a standalone config dir; copy `.claude.json` and `.credentials.json` into it, then interactively launch `CLAUDE_CONFIG_DIR=<stage> claude` and type `/insights` (the built-in command is interactive-only; `-p` won't expand it; **remember to delete the credential copies inside the stage when done**).

You can also name the output directory yourself: "run cowork insights, put the results in `D:\reports`".

Output: the in-chat report + three files — `cowork_full.json` (per-session detail), `cowork_digest.json` (curated sources for the qualitative analysis), `cowork_insights.html` (open in a browser).

Default report location: the plugin's persistent data directory (the official `${CLAUDE_PLUGIN_DATA}`), i.e. `~\.claude\plugins\data\cowork-insights-<source>\` — **the directory suffix depends on the install source**: `-harry18456` for marketplace installs, `-inline` for `--plugin-dir` loading, `-skills-dir` for skills-dir loading; plugin updates don't clear it. If output_dir was set at enable time, that wins; outside plugin contexts it falls back to `~\.claude\usage-data\cowork-insights\`. **It never writes into your current project directory.**

> ⚠️ **Uninstalling also deletes the data directory** (the reports inside vanish with it). To keep reports, use `claude plugin uninstall cowork-insights --keep-data`, or set output_dir to a folder of your own at enable time.

## Testing

Run the script directly without Claude (should print a JSON summary and write two report files):

```
python "<plugin>/skills/cowork-insights/scripts/cowork_insights.py" %TEMP%\cowork-test
```

## Notes

- **Host-side only**: inside the Cowork isolation sandbox other sessions aren't visible and the report comes out nearly empty; the skill has this check built in.
- **Division of labor vs the built-in `/insights`**: same type of analysis (quantitative + qualitative); this tool only looks at Cowork sources and has an adjustable window. For "every session on the whole machine", use the built-in `/insights`.
- **Privacy**: the report contains each session's cwd path; check before sharing report files.
- **Version drift**: the internal structure of Claude Desktop logs is undocumented (tested against v2.1.197). If an audit consistency warning shows up after an update, see the troubleshooting steps in the skill's `references/cowork-log-layout.md`.

## This plugin's components

Currently uses **skills** only (`skills/cowork-insights/`, auto-discovered by Claude Code — no plugin.json declaration needed). `commands/`, `agents/`, `hooks/`, `output-styles/`, `bin/` are reserved skeletons; future extensions just drop files in.
