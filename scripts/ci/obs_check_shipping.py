#!/usr/bin/env python3
"""Reduce OBS `_result` XML to a per-shipping-repo terminal-state verdict.

Reads the OBS API response on stdin and exits:
  0 — all shipping repos READY (succeeded, or every arch is excluded/broken/blocked)
  1 — any shipping repo FAILED (any arch is failed/unresolvable)
  2 — any shipping repo still PENDING / MISSING data

A one-line per-repo summary is printed on stdout for the workflow log,
regardless of exit code.

The "shipping repos" list defines which (repo, arch) combinations we
actually care about for GitHub Release uploads — niche arches like
openSUSE_Factory_RISCV / Factory_PowerPC / Slowroll-aarch64 sit in
`blocked`/`broken` indefinitely and would otherwise hold the publish
workflow hostage until the 60-minute deadline. This script lets the
wait loop exit the moment our seven shipping repos are done.
"""

from __future__ import annotations

import re
import sys

# OBS reports the Leap repos under their bare-version names (`15.6`, `16.0`)
# rather than the `openSUSE_Leap_*` prefix used in the publish artefact
# filenames. obs-publish.yml's discover/upload step normalises them back.
SHIP_REPOS = [
    "openSUSE_Tumbleweed",
    "15.6",  # → published as openSUSE_Leap_15.6
    "16.0",  # → published as openSUSE_Leap_16.0
    "openSUSE_Slowroll",
    "Fedora_42",
    "Fedora_43",
    "Fedora_44",
]


def reduce_codes(codes: list[str]) -> str:
    if not codes:
        return "MISSING"
    if any(c in ("failed", "unresolvable") for c in codes):
        return "FAILED"
    if any(c == "succeeded" for c in codes):
        return "READY"
    if all(c in ("excluded", "broken", "blocked") for c in codes):
        return "READY"
    return "PENDING"


def main() -> int:
    xml = sys.stdin.read()
    blocks = re.findall(r"<result\b[^>]*>.*?</result>", xml, re.DOTALL)

    per_repo: dict[str, list[str]] = {}
    for block in blocks:
        repo_m = re.search(r'repository="([^"]+)"', block)
        if not repo_m:
            continue
        repo = repo_m.group(1)
        if repo not in SHIP_REPOS:
            continue
        code_m = re.search(r'<status\s+package="winpodx"\s+code="([^"]+)"', block)
        if not code_m:
            continue
        per_repo.setdefault(repo, []).append(code_m.group(1))

    states = {r: reduce_codes(per_repo.get(r, [])) for r in SHIP_REPOS}
    summary = " ".join(f"{r}={s}" for r, s in states.items())

    if any(s == "FAILED" for s in states.values()):
        print(f"FAILED {summary}")
        return 1
    if any(s in ("PENDING", "MISSING") for s in states.values()):
        print(f"PENDING {summary}")
        return 2
    print(f"READY {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
