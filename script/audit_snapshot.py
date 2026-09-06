#!/usr/bin/env python3
"""Generate and verify the deterministic Stage 7C audit source commitment."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath


REPO = Path(__file__).resolve().parents[1]
CHECKSUM_PATH = "audit/source-files.sha256"
SCOPE_PATH = "audit/source-scope.json"
ARTIFACTS_PATH = "audit/artifacts.json"
SUBMODULES_PATH = "audit/submodules.json"
TOOLCHAIN_PATH = "audit/toolchain.json"

# Exact test/diagnostic fixtures only. Each exception is documented in
# audit/SECRET-SCAN-EXCEPTIONS.md; no directory or pattern-wide suppression.
SECRET_SCAN_EXCEPTIONS = {
    ("assigned-secret", "test/invariant/SwapVMStage4Invariant.t.sol"),
    ("credentialed-url", "tooling/indexer/test/cli.test.ts"),
    ("assigned-secret", "tooling/tinysol/src/errors.ts"),
}


class SnapshotError(RuntimeError):
    pass


def run(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(args, cwd=REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise SnapshotError(f"command failed ({' '.join(args)}): {result.stderr.decode(errors='replace').strip()}")
    return result


def read_bytes(path: str, ref: str | None) -> bytes:
    if ref is None:
        return (REPO / path).read_bytes()
    return run(["git", "show", f"{ref}:{path}"]).stdout


def read_json(path: str, ref: str | None) -> dict:
    try:
        return json.loads(read_bytes(path, ref))
    except (OSError, ValueError) as exc:
        raise SnapshotError(f"invalid JSON: {path}") from exc


def is_excluded(path: str, scope: dict) -> bool:
    posix = PurePosixPath(path)
    if path in scope["excludedExact"]:
        return True
    if any(part in scope["excludedNames"] for part in posix.parts):
        return True
    return any(path.endswith(suffix) for suffix in scope["excludedSuffixes"])


def discover_worktree(scope: dict) -> list[str]:
    files: set[str] = set()
    for relative in scope["rootFiles"]:
        target = REPO / relative
        if target.is_symlink() or not target.is_file():
            raise SnapshotError(f"missing or non-regular root allowlist file: {relative}")
        files.add(PurePosixPath(relative).as_posix())

    for tree in scope["trees"]:
        root = REPO / tree
        if root.is_symlink() or not root.is_dir():
            raise SnapshotError(f"missing or non-directory allowlist tree: {tree}")
        for current, dirs, names in os.walk(root):
            current_path = Path(current)
            kept_dirs: list[str] = []
            for name in dirs:
                child = current_path / name
                relative = child.relative_to(REPO).as_posix()
                if is_excluded(relative, scope):
                    continue
                if child.is_symlink():
                    raise SnapshotError(f"symlink in audit allowlist: {relative}")
                kept_dirs.append(name)
            dirs[:] = kept_dirs
            for name in names:
                child = current_path / name
                relative = child.relative_to(REPO).as_posix()
                if is_excluded(relative, scope):
                    continue
                if child.is_symlink() or not child.is_file():
                    raise SnapshotError(f"non-regular file in audit allowlist: {relative}")
                files.add(relative)
    return sorted(files)


def discover_ref(scope: dict, ref: str) -> tuple[list[str], set[str]]:
    output = run(["git", "ls-tree", "-r", "--name-only", "-z", ref]).stdout
    all_paths = {item.decode() for item in output.split(b"\0") if item}
    files: set[str] = set()
    for relative in scope["rootFiles"]:
        if relative not in all_paths:
            raise SnapshotError(f"root allowlist file missing from {ref}: {relative}")
        files.add(relative)
    for tree in scope["trees"]:
        prefix = f"{tree}/"
        for path in all_paths:
            if path.startswith(prefix) and not is_excluded(path, scope):
                files.add(path)
    return sorted(files), all_paths


def parse_checksums(data: bytes) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw_line in data.decode("utf-8").splitlines():
        if not raw_line:
            continue
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\0\r\n]+)", raw_line)
        if not match:
            raise SnapshotError("malformed source-files.sha256 line")
        digest, path = match.groups()
        if path in result:
            raise SnapshotError(f"duplicate checksum path: {path}")
        result[path] = digest
    return result


def scan_secrets(files: list[str], ref: str | None) -> None:
    rules = [
        ("pem-private-key", re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
        ("credentialed-url", re.compile(rb"https?://[^\s/:]+:[^\s/@]+@")),
        ("aws-access-key", re.compile(rb"AKIA[0-9A-Z]{16}")),
        ("absolute-user-path", re.compile(rb"/(?:Users|home)/[^/\s]+/")),
        (
            "assigned-secret",
            re.compile(
                rb"(?i)(?:private[_-]?key|mnemonic|seed[_-]?phrase|api[_-]?token|api[_-]?key|rpc[_-]?key)"
                rb"\s*[=:]\s*['\"]?(?!null\b|none\b|redacted\b|example\b|placeholder\b)[A-Za-z0-9+/=_-]{12,}"
            ),
        ),
    ]
    findings: list[tuple[str, str]] = []
    for path in files:
        data = read_bytes(path, ref)
        for rule, pattern in rules:
            if pattern.search(data) and (rule, path) not in SECRET_SCAN_EXCEPTIONS:
                findings.append((rule, path))
    if findings:
        for rule, path in findings:
            print(f"SECRET_SCAN {rule} {path}", file=sys.stderr)
        raise SnapshotError("secret scan failed; output intentionally omits matched content")


def verify_unclassified(files: list[str], scope: dict) -> None:
    expected = set(files) | {CHECKSUM_PATH} | set(scope["submoduleGitlinks"])
    untracked = {
        item.decode()
        for item in run(["git", "ls-files", "--others", "--exclude-standard", "-z"]).stdout.split(b"\0")
        if item
    }
    unexpected = sorted(untracked - expected)
    if unexpected:
        for path in unexpected:
            print(f"UNCLASSIFIED {path}", file=sys.stderr)
        raise SnapshotError("unclassified untracked files exist")


def verify_submodules(expected: dict, ref: str | None) -> None:
    for entry in expected["submodules"]:
        path = entry["path"]
        commit = entry["expectedAuditCommit"]
        if ref is not None:
            line = run(["git", "ls-tree", ref, "--", path]).stdout.decode().strip()
            parts = line.split()
            if len(parts) < 3 or parts[0] != "160000" or parts[2] != commit:
                raise SnapshotError(f"submodule gitlink mismatch at {ref}: {path}")
        local_commit = run(["git", "-C", path, "rev-parse", "HEAD"]).stdout.decode().strip()
        if local_commit != commit:
            raise SnapshotError(f"submodule checkout mismatch: {path}")
        if run(["git", "-C", path, "status", "--porcelain"]).stdout:
            raise SnapshotError(f"dirty submodule: {path}")
        remote = run(["git", "-C", path, "remote", "get-url", "origin"]).stdout.decode().strip()
        if remote != entry["remoteUrl"]:
            raise SnapshotError(f"submodule remote mismatch: {path}")


def inspect_artifact(contract: str) -> dict[str, int | str]:
    creation = run(["forge", "inspect", contract, "bytecode"]).stdout.decode().strip()
    runtime = run(["forge", "inspect", contract, "deployedBytecode"]).stdout.decode().strip()
    return {
        "creationCodeHash": run(["cast", "keccak", creation]).stdout.decode().strip(),
        "deployedRuntimeCodeHash": run(["cast", "keccak", runtime]).stdout.decode().strip(),
        "initcodeBytes": (len(creation) - 2) // 2,
        "runtimeBytes": (len(runtime) - 2) // 2,
    }


def verify_artifacts(expected: dict) -> None:
    for contract, fields in expected["contracts"].items():
        observed = inspect_artifact(contract)
        for key, value in observed.items():
            if fields[key] != value:
                raise SnapshotError(f"artifact mismatch: {contract}.{key}")
        if fields["eip170MarginBytes"] != expected["limits"]["eip170RuntimeBytes"] - observed["runtimeBytes"]:
            raise SnapshotError(f"EIP-170 margin mismatch: {contract}")
        if fields["eip3860MarginBytes"] != expected["limits"]["eip3860InitcodeBytes"] - observed["initcodeBytes"]:
            raise SnapshotError(f"EIP-3860 margin mismatch: {contract}")


def verify_toolchain_hashes(toolchain: dict, ref: str | None) -> None:
    mappings = [toolchain["lockfilesSha256"], toolchain["frozenSha256"]]
    for mapping in mappings:
        for path, expected in mapping.items():
            actual = hashlib.sha256(read_bytes(path, ref)).hexdigest()
            if actual != expected:
                raise SnapshotError(f"toolchain/frozen hash mismatch: {path}")
    generated = hashlib.sha256(read_bytes("tooling/tinysol/src/generated-compiler-identity.ts", ref)).hexdigest()
    if generated != toolchain["compilerIdentity"]["generatedFileSha256"]:
        raise SnapshotError("compiler identity file mismatch")
    for name, expected in toolchain["indexerMigrationsSha256"].items():
        path = f"tooling/indexer/migrations/{name}"
        if hashlib.sha256(read_bytes(path, ref)).hexdigest() != expected:
            raise SnapshotError(f"indexer migration mismatch: {name}")


def generate() -> None:
    scope = read_json(SCOPE_PATH, None)
    files = discover_worktree(scope)
    scan_secrets(files, None)
    lines = [f"{hashlib.sha256((REPO / path).read_bytes()).hexdigest()}  {path}" for path in files]
    (REPO / CHECKSUM_PATH).write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(json.dumps({"status": "GENERATED", "sourceFileCount": len(files)}, sort_keys=True))


def verify(ref: str | None) -> None:
    if ref is not None:
        peeled = run(["git", "rev-parse", f"{ref}^{{commit}}"]).stdout.decode().strip()
        head = run(["git", "rev-parse", "HEAD"]).stdout.decode().strip()
        if peeled != head:
            raise SnapshotError("verification requires the requested ref checked out at HEAD")
    scope = read_json(SCOPE_PATH, ref)
    if ref is None:
        files = discover_worktree(scope)
        all_ref_paths: set[str] | None = None
    else:
        files, all_ref_paths = discover_ref(scope, ref)
    checksums = parse_checksums(read_bytes(CHECKSUM_PATH, ref))
    if set(files) != set(checksums):
        missing = sorted(set(files) - set(checksums))
        extra = sorted(set(checksums) - set(files))
        raise SnapshotError(f"source set mismatch; missing={missing} extra={extra}")
    for path in files:
        actual = hashlib.sha256(read_bytes(path, ref)).hexdigest()
        if actual != checksums[path]:
            raise SnapshotError(f"source hash mismatch: {path}")
    scan_secrets(files, ref)
    if ref is None:
        verify_unclassified(files, scope)
    elif all_ref_paths is not None:
        expected_tree = set(files) | {CHECKSUM_PATH} | set(scope["submoduleGitlinks"])
        unexpected = sorted(all_ref_paths - expected_tree)
        if unexpected:
            raise SnapshotError(f"unclassified files in {ref}: {unexpected}")
    verify_submodules(read_json(SUBMODULES_PATH, ref), ref)
    verify_toolchain_hashes(read_json(TOOLCHAIN_PATH, ref), ref)
    verify_artifacts(read_json(ARTIFACTS_PATH, ref))
    print(json.dumps({"status": "PASS", "sourceFileCount": len(files), "ref": ref or "WORKTREE"}, sort_keys=True))


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("generate")
    verifier = sub.add_parser("verify")
    verifier.add_argument("--ref")
    args = parser.parse_args()
    try:
        if args.command == "generate":
            generate()
        else:
            verify(args.ref)
        return 0
    except SnapshotError as exc:
        print(f"AUDIT_SNAPSHOT_ERROR {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
