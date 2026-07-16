#!/usr/bin/env python3
"""Synthetic Cowork/host transcript fixtures for differential testing of
cowork_insights.py vs cowork_insights.ps1. Covers every discriminator and
parser edge the aggregators care about."""
import json
import shutil
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "fix"

RECENT = "2026-07-14T10:00:{s:02d}.000Z"   # inside any 30-day window around 2026-07-15
OLD = "2026-01-01T10:00:{s:02d}.000Z"      # outside 30 days, inside --days all


def rec_user(text, ts, ep="claude-desktop", cwd="D:\\proj\\demo", extra=None):
    r = {"parentUuid": None, "isSidechain": False, "userType": "external",
         "cwd": cwd, "sessionId": "s", "version": "2.1.197", "type": "user",
         "message": {"role": "user", "content": text},
         "uuid": "u", "timestamp": ts}
    if ep is not None:
        r["entrypoint"] = ep
    if extra:
        r.update(extra)
    return r


def rec_asst(ts, model="claude-sonnet-5", usage=None, content=None,
             ep="claude-desktop", cwd="D:\\proj\\demo"):
    if usage is None:
        usage = {"input_tokens": 10, "output_tokens": 20,
                 "cache_read_input_tokens": 100, "cache_creation_input_tokens": 5}
    if content is None:
        content = [{"type": "text", "text": "ok"}]
    r = {"parentUuid": "u", "type": "assistant",
         "message": {"id": "m", "type": "message", "role": "assistant",
                     "model": model, "content": content, "usage": usage},
         "uuid": "a", "timestamp": ts, "cwd": cwd}
    if ep is not None:
        r["entrypoint"] = ep
    return r


def write_jsonl(path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        for r in records:
            if isinstance(r, str):
                fh.write(r + "\n")   # raw line (garbage / blank tests)
            else:
                fh.write(json.dumps(r, ensure_ascii=False) + "\n")


def main():
    if ROOT.exists():
        shutil.rmtree(ROOT)
    cfg = ROOT / "cfg"
    proj = cfg / "projects"
    la = ROOT / "la"
    ap = ROOT / "ap"
    lams = (la / "Packages" / "Claude_testpkg" / "LocalCache" / "Roaming"
            / "Claude" / "local-agent-mode-sessions")
    ap.mkdir(parents=True)

    slug_a = proj / "D--proj-demo"

    # --- aaaa1111: mounted Cowork session, the kitchen sink -----------------
    tool_err_list = [{"type": "text",
                      "text": "File not found: C:\\tmp\\x\nline2 with 'quotes' and \"doubles\""}]
    write_jsonl(slug_a / "aaaa1111.jsonl", [
        rec_user("幫我分析 這個  專案的  token 用量 🚀", RECENT.format(s=0)),
        rec_asst(RECENT.format(s=1), model="claude-sonnet-5",
                 content=[{"type": "text", "text": "好"},
                          {"type": "tool_use", "id": "t1", "name": "Bash", "input": {}},
                          {"type": "tool_use", "id": "t2", "name": "Read", "input": {}}]),
        rec_user([{"type": "tool_result", "tool_use_id": "t1", "is_error": True,
                   "content": tool_err_list},
                  {"type": "tool_result", "tool_use_id": "t2", "is_error": True,
                   "content": "plain string error"},
                  {"type": "text", "text": "<system-reminder>injected stuff</system-reminder> hi"},
                  {"type": "text", "text": "[Request interrupted by user]"},
                  {"type": "text", "text": "  continue   the\tanalysis  "}],
                 RECENT.format(s=2)),
        rec_asst(RECENT.format(s=3), model="claude-opus-4-8",
                 usage={"input_tokens": 7, "output_tokens": None,
                        "cache_read_input_tokens": 3.0},
                 content=[{"type": "tool_use", "id": "t3", "input": {}},
                          {"type": "tool_use", "id": "t4", "name": "Bash", "input": {}}]),
        rec_asst(RECENT.format(s=4), model="claude-sonnet-5"),
        # codepoint-slice edge: astral char early, text longer than the
        # 280-codepoint user clip / 200-codepoint error clip
        rec_user("🚀 " + "字x" * 200, RECENT.format(s=5)),
        rec_user([{"type": "tool_result", "tool_use_id": "t9", "is_error": True,
                   "content": "💥 boom " + "e" * 300}],
                 RECENT.format(s=6)),
    ])

    # --- badjson: included session with garbage lines in between ------------
    write_jsonl(slug_a / "badjson.jsonl", [
        rec_user("first valid", RECENT.format(s=10)),
        "this is not json at all {",
        "",
        '{"type":"assistant","broken":',
        '{"dup":"a","dup":"b","type":"summary"}',
        rec_asst(RECENT.format(s=11)),
    ])

    # --- bbbb2222: plain CLI session (must be excluded) ----------------------
    write_jsonl(slug_a / "bbbb2222.jsonl", [
        rec_user("cli session", RECENT.format(s=20), ep="cli"),
        rec_asst(RECENT.format(s=21), ep="cli",
                 usage={"input_tokens": 999, "output_tokens": 999,
                        "cache_read_input_tokens": 999,
                        "cache_creation_input_tokens": 999}),
    ])

    # --- cccc3333: ai-title junk (no real turn) ------------------------------
    write_jsonl(slug_a / "cccc3333.jsonl", [
        {"type": "summary", "summary": "Some title", "leafUuid": "x"},
    ])

    # --- dddd4444: mounted but OLD (only in --days all) ----------------------
    write_jsonl(slug_a / "dddd4444.jsonl", [
        rec_user("old mounted session", OLD.format(s=0)),
        rec_asst(OLD.format(s=1),
                 usage={"input_tokens": 11, "output_tokens": 13,
                        "cache_read_input_tokens": 17,
                        "cache_creation_input_tokens": 19}),
    ])

    # --- empty file: skipped --------------------------------------------------
    write_jsonl(slug_a / "eeee0000.jsonl", [])

    # --- bom: first line carries a UTF-8 BOM (fails json.loads), second is ok
    bom_path = slug_a / "ffff6666.jsonl"
    bom_path.parent.mkdir(parents=True, exist_ok=True)
    line1 = json.dumps(rec_user("bom line", RECENT.format(s=30)), ensure_ascii=False)
    line2 = json.dumps(rec_asst(RECENT.format(s=31)), ensure_ascii=False)
    with open(bom_path, "wb") as fh:
        fh.write(b"\xef\xbb\xbf" + line1.encode("utf-8") + b"\n"
                 + line2.encode("utf-8") + b"\n")

    # --- gggg7777: invalid UTF-8 byte inside a string; errors="ignore"
    #     drops the byte so the line still parses
    bad_path = slug_a / "gggg7777.jsonl"
    l1 = json.dumps(rec_user("byte@@MARK@@here", RECENT.format(s=35)),
                    ensure_ascii=False).encode("utf-8").replace(b"@@MARK@@", b"\xff")
    l2 = json.dumps(rec_asst(RECENT.format(s=36)), ensure_ascii=False).encode("utf-8")
    with open(bad_path, "wb") as fh:
        fh.write(l1 + b"\n" + l2 + b"\n")

    # --- tiebrk5555: entrypoint tie (claude-desktop first -> wins) and
    #     model tie (first-inserted wins)
    write_jsonl(slug_a / "tiebrk5555.jsonl", [
        rec_user("tie one", RECENT.format(s=40), ep="claude-desktop"),
        rec_asst(RECENT.format(s=41), model="model-A", ep="cli"),
        rec_asst(RECENT.format(s=42), model="model-B", ep=None),
    ])

    # --- host-tree audit.jsonl (excluded by name, counted) --------------------
    write_jsonl(slug_a / "audit.jsonl", [
        rec_user("audit copy", RECENT.format(s=50)),
    ])

    # --- subagents in host tree -----------------------------------------------
    write_jsonl(slug_a / "aaaa1111" / "subagents" / "agent-yy.jsonl", [
        rec_user("sub work", RECENT.format(s=5), ep="claude-desktop"),
        rec_asst(RECENT.format(s=6), ep="claude-desktop",
                 usage={"input_tokens": 1, "output_tokens": 2,
                        "cache_read_input_tokens": 4, "cache_creation_input_tokens": 8},
                 content=[{"type": "tool_use", "id": "t9", "name": "Grep", "input": {}}]),
    ])
    write_jsonl(slug_a / "bbbb2222" / "subagents" / "agent-zz.jsonl", [
        rec_user("cli sub", RECENT.format(s=22), ep="cli"),
        rec_asst(RECENT.format(s=23), ep="cli",
                 usage={"input_tokens": 555, "output_tokens": 555,
                        "cache_read_input_tokens": 555,
                        "cache_creation_input_tokens": 555}),
    ])
    write_jsonl(slug_a / "dddd4444" / "subagents" / "agent-dd.jsonl", [
        rec_user("sub of old parent, recent itself", RECENT.format(s=7),
                 ep="claude-desktop"),
        rec_asst(RECENT.format(s=8), ep="claude-desktop",
                 usage={"input_tokens": 100, "output_tokens": 200,
                        "cache_read_input_tokens": 400,
                        "cache_creation_input_tokens": 800}),
    ])

    # --- LAMS tree -------------------------------------------------------------
    iso1 = lams / "acct-uuid" / "org-uuid" / "local_e5f6"
    write_jsonl(iso1 / "audit.jsonl", [
        rec_user("audit twin", RECENT.format(s=50), ep="local-agent"),
    ])
    slug_b = iso1 / ".claude" / "projects" / "outputs-slug"
    write_jsonl(slug_b / "e5f6a7b8.jsonl", [
        rec_user("isolated local work", RECENT.format(s=51), ep="local-agent",
                 cwd="C:\\Users\\t\\lams\\local_e5f6\\outputs"),
        rec_asst(RECENT.format(s=52), model="claude-haiku-4-5", ep="local-agent",
                 cwd="C:\\Users\\t\\lams\\local_e5f6\\outputs",
                 usage={"input_tokens": 21, "output_tokens": 22,
                        "cache_read_input_tokens": 23,
                        "cache_creation_input_tokens": 24}),
    ])
    write_jsonl(slug_b / "e5f6a7b8" / "subagents" / "agent-ss.jsonl", [
        rec_user("lams sub", RECENT.format(s=53), ep="local-agent",
                 cwd="C:\\Users\\t\\lams\\local_e5f6\\outputs"),
        rec_asst(RECENT.format(s=54), ep="local-agent",
                 cwd="C:\\Users\\t\\lams\\local_e5f6\\outputs",
                 usage={"input_tokens": 31, "output_tokens": 32,
                        "cache_read_input_tokens": 33,
                        "cache_creation_input_tokens": 34}),
    ])
    write_jsonl(slug_b / "e5f6a7b8" / "subagents" / "agent-junk.jsonl", [
        {"type": "summary", "summary": "junk sub"},
    ])

    iso2 = lams / "acct-uuid" / "org-uuid" / "local_f7g8"
    slug_c = iso2 / ".claude" / "projects" / "vm-slug"
    write_jsonl(slug_c / "f7g8h9i0.jsonl", [
        rec_user("vm style, no entrypoint", OLD.format(s=10), ep=None,
                 cwd="/sessions/tester"),
        rec_asst(RECENT.format(s=60), ep=None, cwd="/sessions/tester",
                 model="claude-sonnet-5",
                 usage={"input_tokens": 41, "output_tokens": 42,
                        "cache_read_input_tokens": 43,
                        "cache_creation_input_tokens": 44}),
    ])
    write_jsonl(slug_c / "orphan-dir" / "subagents" / "agent-oo.jsonl", [
        rec_user("orphan sub under lams", RECENT.format(s=61), ep=None,
                 cwd="/sessions/tester"),
        rec_asst(RECENT.format(s=62), ep=None, cwd="/sessions/tester",
                 usage={"input_tokens": 51, "output_tokens": 52,
                        "cache_read_input_tokens": 53,
                        "cache_creation_input_tokens": 54}),
    ])

    (cfg / "projects").mkdir(parents=True, exist_ok=True)
    print(f"fixtures written under {ROOT}")


if __name__ == "__main__":
    main()
