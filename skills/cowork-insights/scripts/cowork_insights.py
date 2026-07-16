#!/usr/bin/env python3
"""cowork-insights: Cowork usage aggregation for HOST Claude Code.

KEEP IN SYNC with cowork_insights.ps1 (PowerShell port for machines without
Python). Outputs are byte-identical by design; when changing behavior here,
mirror it there and re-run a differential comparison of the three output
files over the same data.

Read-only. Scans the host projects tree AND the Cowork
(local-agent-mode-sessions) tree, keeps only Cowork-origin sessions, and
reports usage with NO 30-day limit and NO startup cleanup deletion.

Scan criterion (which files get COLLECTED):
    entrypoint in {"local-agent", "claude-desktop"}
    OR  file located under a local-agent-mode-sessions tree
    (single-line "ai-title" junk files are excluded first)

Confidence split (v3) -- collected does NOT mean confirmed:
    confirmed  = under a LAMS tree OR entrypoint == "local-agent"
    ambiguous  = host-tree claude-desktop: the desktop app stamps the SAME
                 entrypoint on Cowork mounted-folder sessions AND Code-tab
                 sessions, so the logs alone cannot tell them apart. They
                 are reported as a separate bucket and never silently
                 folded into "Cowork"; only the machine's user can resolve
                 which they are.

entrypoint meaning (empirically confirmed on this machine):
    local-agent      -> isolated Cowork (VM + local mode); lives under LAMS tree
    claude-desktop   -> desktop app backend (Cowork mounted-folder OR Code tab);
                        lives in HOST tree
    cli / sdk-* / claude-vscode -> NOT Cowork

Usage:
    python cowork_insights.py [output_dir] [--days N|all]
        output_dir defaults to the plugin's persistent data dir
        (~/.claude/plugins/data/<plugin>-<marketplace>/) when running from a
        plugin install, else <config_dir>/usage-data/cowork-insights.
        Never the cwd -- a casual usage question must not drop report files
        into whatever project the user happens to be in.
        --days defaults to 30 to mirror the built-in /insights window, so the
        numbers stay comparable. Unlike the built-in tool the window is purely
        analytical (nothing is ever deleted), and it IS adjustable: --days 90,
        --days all. A session counts when its last activity falls inside the
        window; the audit consistency check always runs over the full
        population since it detects layout drift, not usage.
Optional overrides via env:
    CLAUDE_CONFIG_DIR   -> host config dir (default: %USERPROFILE%\\.claude)
    CLAUDE_COWORK_ROOT  -> explicit local-agent-mode-sessions path

v3 (2026-07-16) vs v2:
    * cowork_confidence per session + confirmed/ambiguous summary split.
      Field evidence from a machine that uses the desktop Code tab showed
      host-tree claude-desktop sessions being counted as Cowork when they
      were plain Code usage; the old "0 misses / 0 false positives" claim
      only held on machines whose desktop use happened to be Cowork-only.

v2 (2026-07-11) fixes vs v1:
    * File discovery uses os.walk -- the glob module's "**" skips dot-
      directories, so v1 never saw isolated transcripts under
      local_<uuid>/.claude/projects/ and silently counted the per-session
      audit.jsonl files instead.
    * audit.jsonl is excluded from sessions AND tokens: it logs the same API
      calls as the transcript (message-id overlap confirmed; input/cache
      fields identical) with truncated streaming output_tokens. Counting both
      would double-count. Kept only as a 1:1 consistency cross-check.
    * subagents/agent-*.jsonl now counted into token totals (real extra API
      usage) but not into session counts; attached to the parent session.
"""
from __future__ import annotations
import argparse
import json, os, re, sys, glob, html
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

COWORK_ENTRYPOINTS = {"local-agent", "claude-desktop"}
TOKEN_FIELDS = ("input_tokens", "output_tokens",
                "cache_read_input_tokens", "cache_creation_input_tokens")


def find_host_projects() -> Path | None:
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    base = Path(cfg) if cfg else Path.home() / ".claude"
    p = base / "projects"
    return p if p.exists() else None


def find_lams_roots() -> list[Path]:
    roots: list[Path] = []
    ov = os.environ.get("CLAUDE_COWORK_ROOT")
    if ov and Path(ov).exists():
        roots.append(Path(ov))
    la = os.environ.get("LOCALAPPDATA")
    if la:  # MSIX-packaged Desktop app redirects %APPDATA% here
        pat = str(Path(la) / "Packages" / "Claude_*" / "LocalCache"
                  / "Roaming" / "Claude" / "local-agent-mode-sessions")
        roots += [Path(p) for p in glob.glob(pat)]
    ap = os.environ.get("APPDATA")
    if ap:  # non-packaged fallback
        cand = Path(ap) / "Claude" / "local-agent-mode-sessions"
        if cand.exists():
            roots.append(cand)
    seen, out = set(), []
    for r in roots:
        rp = r.resolve()
        if rp not in seen:
            seen.add(rp)
            out.append(r)
    return out


def under_any(path: Path, roots: list[Path]) -> bool:
    rp = path.resolve()
    for r in roots:
        try:
            rp.relative_to(r.resolve())
            return True
        except ValueError:
            continue
    return False


def iter_jsonl(root: Path) -> list[Path]:
    # os.walk, NOT glob: glob's "**" skips dot-directories, and the isolated
    # transcripts live under local_<uuid>/.claude/projects/
    out: list[Path] = []
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if fn.endswith(".jsonl"):
                out.append(Path(dirpath) / fn)
    return out


def file_role(fp: Path) -> str:
    if fp.name == "audit.jsonl":
        return "audit"
    if fp.parent.name == "subagents":
        return "subagent"
    return "main"


def read_records(fp: Path) -> list[dict]:
    recs = []
    try:
        with open(fp, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    recs.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        pass
    return recs


def analyze_file(fp: Path):
    """Return session facts, or None if unreadable / ai-title junk."""
    recs = read_records(fp)
    if not recs:
        return None
    # ai-title junk = no real user/assistant turn
    if not any(r.get("type") in ("user", "assistant") for r in recs):
        return None

    eps = Counter(r.get("entrypoint") for r in recs if r.get("entrypoint"))
    cwd = next((r.get("cwd") for r in recs if r.get("cwd")), None)
    models, tools, tokens = Counter(), Counter(), Counter()
    msgs, ts = 0, []
    for r in recs:
        if r.get("type") in ("user", "assistant"):
            msgs += 1
        if r.get("timestamp"):
            ts.append(r["timestamp"])
        msg = r.get("message") or {}
        if r.get("type") == "assistant" and isinstance(msg, dict):
            if msg.get("model"):
                models[msg["model"]] += 1
            usage = msg.get("usage") or {}
            for k in TOKEN_FIELDS:
                tokens[k] += int(usage.get(k) or 0)
            for item in (msg.get("content") or []):
                if isinstance(item, dict) and item.get("type") == "tool_use":
                    tools[item.get("name", "?")] += 1
    return {
        "file": str(fp),
        "entrypoints": dict(eps),
        "entrypoint": (eps.most_common(1)[0][0] if eps else None),
        "cwd": cwd,
        "model": (models.most_common(1)[0][0] if models else None),  # most-frequent = stable
        "messages": msgs,
        "tool_calls": sum(tools.values()),
        "tools": dict(tools),
        "tokens": {k: tokens.get(k, 0) for k in TOKEN_FIELDS},
        "token_total": sum(tokens.values()),
        "first": min(ts) if ts else None,
        "last": max(ts) if ts else None,
        "bytes": fp.stat().st_size if fp.exists() else 0,
    }


def default_output_dir() -> Path:
    """Report home when no output_dir argument is given.

    Running from a plugin install (.../plugins/cache/<marketplace>/<plugin>/
    <version>/skills/...), use the harness's persistent per-plugin data dir
    ~/.claude/plugins/data/<id>/ -- the same directory ${CLAUDE_PLUGIN_DATA}
    resolves to, which survives plugin updates. That variable is only
    substituted inside component config files, not in shell commands Claude
    writes, so derive the path from this file's own location instead.
    Anywhere else, fall back to <config_dir>/usage-data/cowork-insights.
    """
    # DO NOT read CLAUDE_PLUGIN_DATA / CLAUDE_PLUGIN_OPTION_* here: those are
    # per-plugin scoped, exported only inside a plugin's OWN hook/MCP
    # subprocesses. A model-run Bash shell is shared and may carry ANOTHER
    # plugin's values (observed: codex's data dir). Plugin-scoped values reach
    # this script safely as argv, via ${...} text substitution in SKILL.md.
    parts = Path(__file__).resolve().parts
    for i in range(len(parts) - 3):
        if parts[i] == "plugins" and parts[i + 1] == "cache":
            marketplace, plugin = parts[i + 2], parts[i + 3]
            plugin_id = re.sub(r"[^a-zA-Z0-9_-]", "-", f"{plugin}@{marketplace}")
            return Path(*parts[: i + 1]) / "data" / plugin_id
    cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    base = Path(cfg) if cfg else Path.home() / ".claude"
    return base / "usage-data" / "cowork-insights"


def classify_kind(sess, in_lams) -> str:
    cwd = sess.get("cwd") or ""
    if in_lams:
        if sess.get("entrypoint") is None or cwd.startswith("/sessions"):
            return "iso-vm"
        return "iso-local"
    return "mounted"  # host tree + cowork entrypoint (claude-desktop)


def _clip(s, n: int) -> str:
    return re.sub(r"\s+", " ", str(s)).strip()[:n]


def extract_signals(fp: Path, max_user=15, max_err=8) -> dict:
    """Qualitative raw material for ONE session, kept small enough that the
    full digest across all sessions stays readable in one go. The analysis
    itself (friction points, suggestions) is done by the model reading the
    digest -- same division of labor as the built-in /insights, just with
    curated Cowork-only sources."""
    users, errors = [], []
    interruptions = 0
    for r in read_records(fp):
        if r.get("type") != "user":
            continue
        msg = r.get("message") or {}
        content = msg.get("content") if isinstance(msg, dict) else None
        parts = [content] if isinstance(content, str) else (content or [])
        for c in parts:
            if isinstance(c, dict):
                if c.get("type") == "tool_result" and c.get("is_error"):
                    if len(errors) < max_err:
                        errors.append(_clip(c.get("content"), 200))
                    continue
                c = c.get("text") if c.get("type") == "text" else None
            if not c or not isinstance(c, str):
                continue
            if "[Request interrupted" in c:
                interruptions += 1
            elif "<system-reminder>" in c[:80]:
                continue  # injected context, not the user's own words
            elif len(users) < max_user:
                users.append(_clip(c, 280))
    return {"user_messages": users, "tool_errors": errors,
            "interruptions": interruptions}


def parse_cli() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Cowork-only usage report (read-only aggregation)")
    p.add_argument("output_dir", nargs="?", default=None,
                   help="report directory (default: plugin data dir / usage-data)")
    p.add_argument("--days", default="30",
                   help="analysis window in days, or 'all' for full history "
                        "(default: 30, mirroring the built-in /insights window)")
    p.add_argument("--stage", default=None, metavar="DIR",
                   help="ALSO stage the windowed Cowork transcripts into "
                        "DIR/projects/ so the NATIVE /insights engine can run "
                        "on them via CLAUDE_CONFIG_DIR=DIR (source files are "
                        "only copied, never modified)")
    return p.parse_args()


def stage_sources(stage_dir: Path, live: list[dict], subagent_files: list[Path],
                  live_parent_keys: set) -> int:
    """Copy windowed Cowork transcripts into <stage>/projects/ preserving the
    original slug directory names, so the built-in /insights (which reads
    <config_dir>/projects/**.jsonl) can analyze exactly this curated set.
    Copies get a fresh mtime, which also keeps them clear of the engine's
    startup cleanup."""
    import shutil
    proj = stage_dir / "projects"
    proj.mkdir(parents=True, exist_ok=True)
    n = 0
    for s in live:
        src = Path(s["file"])
        dst_dir = proj / src.parent.name
        dst_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy(src, dst_dir / src.name)
        n += 1
    for fp in subagent_files:  # keep subagent transcripts with their parent
        parent_dir = fp.parent.parent
        if (str(parent_dir.parent.resolve()), parent_dir.name) in live_parent_keys:
            dst_dir = proj / parent_dir.parent.name / parent_dir.name / "subagents"
            dst_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy(fp, dst_dir / fp.name)
            n += 1
    return n


def window_cutoff(days_arg: str) -> tuple[float | None, str | None]:
    """Return (days, ISO cutoff) -- (None, None) means full history."""
    if str(days_arg).strip().lower() in ("all", "full", "0"):
        return None, None
    days = float(days_arg)
    cut = datetime.now(timezone.utc) - timedelta(days=days)
    # session timestamps are uniform UTC "...Z" strings; lexicographic compare works
    return days, cut.strftime("%Y-%m-%dT%H:%M:%S.000Z")


def main():
    args = parse_cli()
    days, cutoff = window_cutoff(args.days)
    host_projects = find_host_projects()
    lams_roots = find_lams_roots()

    scan_roots = ([host_projects] if host_projects else []) + lams_roots
    files, seen = [], set()
    for root in scan_roots:
        for fp in iter_jsonl(root):
            rp = str(fp.resolve())
            if rp not in seen:
                seen.add(rp)
                files.append(fp)

    audit_files = [f for f in files if file_role(f) == "audit"]
    subagent_files = [f for f in files if file_role(f) == "subagent"]
    main_files = [f for f in files if file_role(f) == "main"]

    sessions, index = [], {}
    for fp in main_files:
        in_lams = under_any(fp, lams_roots)
        sess = analyze_file(fp)
        if sess is None:
            continue
        if not ((sess["entrypoint"] in COWORK_ENTRYPOINTS) or in_lams):
            continue
        sess = {**sess,
                "kind": classify_kind(sess, in_lams),
                # confidence follows the SIGNAL, not the kind: LAMS location
                # and local-agent are hard Cowork evidence; a bare
                # claude-desktop marker is shared with the desktop Code tab
                "cowork_confidence": ("confirmed"
                                      if (in_lams or sess["entrypoint"] == "local-agent")
                                      else "ambiguous"),
                "subagents": 0, "subagent_tokens": 0}
        sessions.append(sess)
        index[(str(fp.parent.resolve()), fp.stem)] = sess

    # analysis window: a session counts when its last activity is inside it
    live = [s for s in sessions
            if cutoff is None or (s.get("last") or "") >= cutoff]
    live_ids = {id(s) for s in live}

    # subagent transcripts: real extra API usage, but not separate sessions
    sub_tokens, sub_tools, sub_count = Counter(), Counter(), 0
    orphan_conf_tokens, orphan_amb_tokens = 0, 0
    for fp in subagent_files:
        parent_dir = fp.parent.parent          # .../<slug>/<session-uuid>/
        parent = index.get((str(parent_dir.parent.resolve()), parent_dir.name))
        info = analyze_file(fp)
        if info is None:
            continue
        if (parent is None
                and info["entrypoint"] not in COWORK_ENTRYPOINTS
                and not under_any(fp, lams_roots)):
            continue                            # subagent of a non-Cowork session
        if parent is not None:
            parent["subagents"] += 1
            parent["subagent_tokens"] += info["token_total"]
            in_window = id(parent) in live_ids  # follow the parent session
        else:
            in_window = cutoff is None or (info.get("last") or "") >= cutoff
        if not in_window:
            continue
        sub_count += 1
        for k, v in info["tokens"].items():
            sub_tokens[k] += v
        for t, c in info["tools"].items():
            sub_tools[t] += c
        if parent is None:  # attribute orphans by the same confidence signal
            if under_any(fp, lams_roots) or info["entrypoint"] == "local-agent":
                orphan_conf_tokens += info["token_total"]
            else:
                orphan_amb_tokens += info["token_total"]

    agg = Counter()
    models, tools, kinds, eps = Counter(), Counter(), Counter(), Counter()
    firsts, lasts = [], []
    for s in live:
        for k, v in s["tokens"].items():
            agg[k] += v
        if s["model"]:
            models[s["model"]] += 1
        for t, c in s["tools"].items():
            tools[t] += c
        kinds[s["kind"]] += 1
        eps[s["entrypoint"]] += 1
        if s["first"]:
            firsts.append(s["first"])
        if s["last"]:
            lasts.append(s["last"])

    tokens_main = {k: agg.get(k, 0) for k in TOKEN_FIELDS}
    for k, v in sub_tokens.items():   # grand totals include subagent usage
        agg[k] += v
    for t, c in sub_tools.items():
        tools[t] += c

    # drift detector, not a usage stat: always checked over the FULL population
    iso_sessions = sum(1 for s in sessions if s["kind"] != "mounted")

    # confirmed/ambiguous split over the live window; sums reconcile exactly
    # with token_grand_total (attached subagent tokens ride their parent,
    # orphans were attributed by signal above)
    conf_live = [s for s in live if s["cowork_confidence"] == "confirmed"]
    amb_live = [s for s in live if s["cowork_confidence"] == "ambiguous"]
    conf_tokens = (sum(s["token_total"] + s["subagent_tokens"] for s in conf_live)
                   + orphan_conf_tokens)
    amb_tokens = (sum(s["token_total"] + s["subagent_tokens"] for s in amb_live)
                  + orphan_amb_tokens)

    summary = {
        "sessions_analyzed": len(live),
        "cowork_confirmed": {
            "sessions": len(conf_live),
            "token_grand_total": conf_tokens,
            "note": "LAMS tree or entrypoint local-agent: definitely Cowork",
        },
        "desktop_app_ambiguous": {
            "sessions": len(amb_live),
            "token_grand_total": amb_tokens,
            "note": "host-tree claude-desktop: the desktop app stamps the same "
                    "entrypoint on Cowork mounted-folder AND Code-tab sessions, "
                    "so the logs cannot tell them apart -- ask the machine's "
                    "user (per-session cwd is in the digest)",
        },
        "window": {
            "days": days,
            "cutoff": cutoff,
            "note": "sessions whose last activity falls inside the window; "
                    "use --days all for full history (nothing is ever deleted)",
        },
        "kinds": dict(kinds),
        "entrypoints": dict(eps),
        "span": {"first": min(firsts) if firsts else None,
                 "last": max(lasts) if lasts else None},
        "tokens": {k: agg.get(k, 0) for k in TOKEN_FIELDS},
        "token_grand_total": sum(agg.values()),
        "token_input_output_only": agg["input_tokens"] + agg["output_tokens"],
        "tokens_main_only": tokens_main,
        "subagent_files_counted": sub_count,
        "subagent_token_total": sum(sub_tokens.values()),
        "audit_consistency": {
            "audit_files_excluded": len(audit_files),
            "isolated_sessions": iso_sessions,
            "note": "expect ~1:1 (one audit.jsonl per isolated Cowork session); "
                    "divergence may signal a Desktop-app layout change; "
                    "checked over full history regardless of --days",
        },
        "models": dict(models.most_common()),
        "tools_top": dict(tools.most_common(15)),
        "host_projects": str(host_projects) if host_projects else None,
        "lams_roots": [str(r) for r in lams_roots],
    }

    # qualitative digest: curated raw material for the model-side analysis
    keep = ("file", "kind", "cowork_confidence", "entrypoint", "model", "cwd",
            "first", "last", "messages", "tool_calls", "token_total", "subagents")
    digest = [{**{k: s[k] for k in keep}, **extract_signals(Path(s["file"]))}
              for s in live]

    out_dir = Path(args.output_dir) if args.output_dir else default_output_dir()
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "cowork_full.json").write_text(
        json.dumps({"summary": summary, "sessions": live},
                   ensure_ascii=False, indent=2), encoding="utf-8")
    (out_dir / "cowork_digest.json").write_text(
        json.dumps({"window": summary["window"], "sessions": digest},
                   ensure_ascii=False, indent=1), encoding="utf-8")
    write_html(out_dir / "cowork_insights.html", summary, live)

    if args.stage:
        live_parent_keys = {k for k, v in index.items() if id(v) in live_ids}
        staged = stage_sources(Path(args.stage), live, subagent_files,
                               live_parent_keys)
        print(f"STAGED: {staged} transcript files -> "
              f"{Path(args.stage) / 'projects'}", file=sys.stderr)

    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"\nWROTE: {out_dir / 'cowork_full.json'}")
    print(f"WROTE: {out_dir / 'cowork_digest.json'}")
    print(f"WROTE: {out_dir / 'cowork_insights.html'}")


def write_html(path: Path, summary: dict, sessions: list):
    esc = lambda x: html.escape(str(x))
    tk = summary["tokens"]
    rows = "".join(
        f"<tr><td>{esc(s['kind'])}</td><td>{esc(s['cowork_confidence'])}</td>"
        f"<td>{esc(s['entrypoint'])}</td>"
        f"<td>{esc(s['model'])}</td><td class=n>{s['messages']}</td>"
        f"<td class=n>{s['tool_calls']}</td><td class=n>{s['token_total']:,}</td>"
        f"<td class=n>{s['subagents']}</td>"
        f"<td>{esc((s['first'] or '')[:10])}</td>"
        f"<td class=c>{esc((s['cwd'] or '')[:64])}</td></tr>"
        for s in sorted(sessions, key=lambda x: x.get("last") or "", reverse=True))
    doc = f"""<!doctype html><meta charset="utf-8"><title>Cowork Insights</title>
<style>body{{font-family:system-ui,Segoe UI,Arial;margin:24px;color:#222}}
h1{{font-size:20px;margin:0 0 4px}}p{{margin:6px 0;font-size:13px}}
table{{border-collapse:collapse;width:100%;font-size:12px;margin-top:12px}}
td,th{{border:1px solid #ddd;padding:4px 8px}}th{{background:#f4f4f4;text-align:left}}
.n{{text-align:right}}.c{{font-size:11px;color:#555}}
.kpi{{display:inline-block;margin:8px 20px 8px 0}}.kpi b{{font-size:22px;display:block}}</style>
{"<h1>Cowork Insights &mdash; last " + f"{summary['window']['days']:g} days (analysis window only; nothing deleted)</h1>" if summary['window']['days'] else "<h1>Cowork Insights &mdash; full history</h1>"}
<div class=kpi>Sessions analyzed<b>{summary['sessions_analyzed']}</b></div>
<div class=kpi>Confirmed Cowork<b>{summary['cowork_confirmed']['sessions']}</b></div>
<div class=kpi>Desktop app (ambiguous)<b>{summary['desktop_app_ambiguous']['sessions']}</b></div>
<div class=kpi>Grand total tokens<b>{summary['token_grand_total']:,}</b></div>
<div class=kpi>input+output only<b>{summary['token_input_output_only']:,}</b></div>
<div class=kpi>Span<b>{esc((summary['span']['first'] or '')[:10])} &rarr; {esc((summary['span']['last'] or '')[:10])}</b></div>
<p>cowork confidence: confirmed={summary['cowork_confirmed']['sessions']} sessions / {summary['cowork_confirmed']['token_grand_total']:,} tokens &middot; desktop-app ambiguous={summary['desktop_app_ambiguous']['sessions']} / {summary['desktop_app_ambiguous']['token_grand_total']:,} &mdash; the desktop app stamps the same marker on Cowork mounted-folder and Code-tab sessions; ask the machine's user which they use</p>
<p>kinds = {esc(summary['kinds'])} &middot; entrypoints = {esc(summary['entrypoints'])}</p>
<p>tokens (incl. subagents): input={tk['input_tokens']:,} &middot; output={tk['output_tokens']:,} &middot; cache_read={tk['cache_read_input_tokens']:,} &middot; cache_creation={tk['cache_creation_input_tokens']:,}</p>
<p>subagent files counted: {summary['subagent_files_counted']} ({summary['subagent_token_total']:,} tokens) &middot; audit.jsonl excluded: {summary['audit_consistency']['audit_files_excluded']} (duplicate usage log; cross-check vs {summary['audit_consistency']['isolated_sessions']} isolated sessions)</p>
<p>models: {esc(summary['models'])}</p>
<p>top tools: {esc(summary['tools_top'])}</p>
<table><tr><th>kind</th><th>conf</th><th>entrypoint</th><th>model</th><th>msgs</th><th>tools</th><th>tokens</th><th>subs</th><th>date</th><th>cwd</th></tr>
{rows}</table>"""
    path.write_text(doc, encoding="utf-8")


if __name__ == "__main__":
    main()
