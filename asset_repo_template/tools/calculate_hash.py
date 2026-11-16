#!/usr/bin/env python3
"""Print the SHA-256 and size of one or more files (streaming).

Usage:
  python tools/calculate_hash.py release-assets/audio.zip [more files...]
  python tools/calculate_hash.py --json release-assets/*
"""

from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fdam_common import sha256_file  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+")
    ap.add_argument("--json", action="store_true", help="print JSON instead of text")
    args = ap.parse_args(argv)
    rows = []
    rc = 0
    for path in args.files:
        if not os.path.isfile(path):
            print(f"error: not a file: {path}", file=sys.stderr)
            rc = 1
            continue
        rows.append({"file": path, "sizeBytes": os.path.getsize(path), "sha256": sha256_file(path)})
    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        for r in rows:
            print(f"{r['sha256']}  {r['sizeBytes']:>12}  {r['file']}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
