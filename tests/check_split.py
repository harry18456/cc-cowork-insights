#!/usr/bin/env python3
"""Print the v0.4.0 confirmed/ambiguous split and verify it reconciles."""
import json
import sys

j = json.load(open(sys.argv[1], encoding="utf-8"))
s = j["summary"]
c, a = s["cowork_confirmed"], s["desktop_app_ambiguous"]
print(f"analyzed={s['sessions_analyzed']}  "
      f"confirmed={c['sessions']} sess / {c['token_grand_total']:,} tok  "
      f"ambiguous={a['sessions']} sess / {a['token_grand_total']:,} tok")
total = c["token_grand_total"] + a["token_grand_total"]
ok = total == s["token_grand_total"]
print(f"reconcile: {total:,} == grand {s['token_grand_total']:,} -> {ok}")
sys.exit(0 if ok else 1)
