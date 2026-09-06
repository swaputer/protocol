#!/usr/bin/env python3
"""Fail closed on release-surface bytecode drift and EIP-170/EIP-3860 limits."""
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESULT = ROOT / "security-results" / "contract-sizes.json"


def byte_length(contract: str, field: str) -> int:
    value = subprocess.check_output(
        ["forge", "inspect", contract, field], cwd=ROOT, text=True
    ).strip()
    if not value.startswith("0x"):
        raise SystemExit(f"unexpected forge output for {contract} {field}")
    return (len(value) - 2) // 2


recorded = json.loads(RESULT.read_text())
failures = []
observed = {}
for name, item in recorded["contracts"].items():
    runtime = byte_length(name, "deployedBytecode")
    initcode = byte_length(name, "bytecode")
    observed[name] = {"runtime": runtime, "initcode": initcode}
    if runtime != item["runtime"] or initcode != item["initcode"]:
        failures.append(f"{name}: bytecode drift recorded={item['runtime']}/{item['initcode']} actual={runtime}/{initcode}")
    if runtime > item["runtimeLimit"] or initcode > item["initcodeLimit"]:
        failures.append(f"{name}: regression threshold exceeded")
    if runtime > 24_576 or initcode > 49_152:
        failures.append(f"{name}: protocol code-size ceiling exceeded")

kernel = observed["SwapVMKernel"]["runtime"]
if recorded["kernelEip170Margin"] != 24_576 - kernel:
    failures.append("SwapVMKernel EIP-170 margin is stale")
print(json.dumps({"status": "PASS" if not failures else "FAIL", "tool": "forge inspect", "observed": observed}, sort_keys=True))
if failures:
    raise SystemExit("\n".join(failures))
