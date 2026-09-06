#!/usr/bin/env python3
import json
import sys
from collections import Counter
from pathlib import Path

root = Path(__file__).resolve().parents[1]
expected = json.loads((root / "security-results/slither-summary.json").read_text())
actual = json.loads(Path(sys.argv[1]).read_text())
if actual.get("success") is not True:
    raise SystemExit("Slither did not produce a successful analysis result")
detectors = actual.get("results", {}).get("detectors", [])
counts = dict(sorted(Counter(item["check"] for item in detectors).items()))
if counts != expected["counts"] or len(detectors) != expected["resultCount"]:
    print(json.dumps({"status": "FAIL", "counts": counts, "resultCount": len(detectors)}, sort_keys=True))
    raise SystemExit("Slither result drift requires explicit triage")
print(json.dumps({"status": "PASS", "tool": expected["tool"], "version": expected["version"], "counts": counts, "resultCount": len(detectors)}, sort_keys=True))
