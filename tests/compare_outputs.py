#!/usr/bin/env python3
"""Byte-compare the three report files between a Python-produced and a
PowerShell-produced output directory. --normalize-cutoff blanks the runtime
window.cutoff value (differs by seconds between runs) before comparing."""
import re
import sys

FILES = ("cowork_full.json", "cowork_digest.json", "cowork_insights.html")
CUT = re.compile(rb'"cutoff": "[^"]*"')


def main():
    a, b = sys.argv[1], sys.argv[2]
    normalize = "--normalize-cutoff" in sys.argv
    ok = True
    for name in FILES:
        try:
            da = open(f"{a}/{name}", "rb").read()
            db = open(f"{b}/{name}", "rb").read()
        except OSError as e:
            print(f"{name}: MISSING ({e})")
            ok = False
            continue
        if normalize:
            da = CUT.sub(b'"cutoff": "X"', da)
            db = CUT.sub(b'"cutoff": "X"', db)
        if da == db:
            print(f"{name}: IDENTICAL ({len(da)} bytes)")
        else:
            ok = False
            print(f"{name}: DIFF (a={len(da)} b={len(db)} bytes)")
            # locate first differing byte and show context
            n = min(len(da), len(db))
            i = next((j for j in range(n) if da[j] != db[j]), n)
            lo = max(0, i - 120)
            print(f"  first diff at byte {i}")
            print(f"  A: ...{da[lo:i+160]!r}")
            print(f"  B: ...{db[lo:i+160]!r}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
