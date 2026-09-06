#!/usr/bin/env python3
"""Prepare and verify the network-independent Swaputer v1.2 candidate freeze.

The freeze is deliberately two phase. ``generate`` writes only the immutable
commitments that belong in candidate commit C. After an annotated tag points to
C, ``finalize --ref <tag>`` writes candidate.json as evidence for a later
evidence commit E. The evidence binds the tag's peeled commit and tree, never
the current HEAD or working-tree state.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from contextlib import contextmanager
from pathlib import Path, PurePosixPath
from typing import Callable, Iterator, Optional


REPO = Path(__file__).resolve().parents[1]
RELEASE_DIR = REPO / "release/v1.2"
SCOPE_PATH = RELEASE_DIR / "candidate-scope.json"
SOURCE_SCOPE_PATH = RELEASE_DIR / "source-scope.json"
SOURCE_LIST_PATH = RELEASE_DIR / "source-files.sha256"
ARTIFACTS_PATH = RELEASE_DIR / "artifacts.json"
TOOLCHAIN_PATH = RELEASE_DIR / "toolchain.json"
SUBMODULES_PATH = RELEASE_DIR / "submodules.json"
CANDIDATE_PATH = RELEASE_DIR / "candidate.json"
CANDIDATE_TAG = "swaputer-v1.2-stage7m-rc3"

CORE_CONTRACTS = (
    "SwapVMCreationCodeStore",
    "SwapVMGasToken",
    "SwapVMHook",
    "SwapVMKernel",
    "SwapVMReferenceRegistry",
    "SwapVMRouter",
    "SwapVMWorldDeployer",
    "SwapVMWorldFactory",
)
EXCLUDED_APPLICATION_CONTRACTS = (
    "SwapVMSRC20Market",
    "SwaputerSRC20MarketFactory",
    "SwapVMSETHVault",
    "SwapVMSRC20AuctionHouse",
    "SwaputerSRC20AuctionFactory",
)
SECRET_RULES = (
    ("pem-private-key", re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("credentialed-url", re.compile(rb"https?://[^\s/:]+:[^\s/@]+@")),
    ("aws-access-key", re.compile(rb"AKIA[0-9A-Z]{16}")),
    ("absolute-user-path", re.compile(rb"/(?:Users|home)/[^/\s]+/")),
    (
        "assigned-secret",
        re.compile(
            rb"(?i)(?:private[_-]?key|mnemonic|seed[_-]?phrase|api[_-]?token|api[_-]?key)"
            rb"\s*[=:]\s*['\"]?(?!null\b|none\b|redacted\b|example\b|placeholder\b)[A-Za-z0-9+/=_-]{12,}"
        ),
    ),
)


class CandidateError(RuntimeError):
    pass


def run(
    arguments: list[str], *, cwd: Optional[Path] = None, check: bool = True
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        arguments,
        cwd=REPO if cwd is None else cwd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        detail = result.stderr.decode(errors="replace").strip()
        raise CandidateError(f"command failed ({' '.join(arguments)}): {detail}")
    return result


def canonical_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def strict_json_bytes(data: bytes, path: str) -> dict:
    def pairs(values: list[tuple[str, object]]) -> dict:
        output: dict[str, object] = {}
        for key, value in values:
            if key in output:
                raise CandidateError(f"duplicate JSON member in {path}: {key}")
            output[key] = value
        return output

    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=pairs)
    except (UnicodeDecodeError, ValueError) as exc:
        raise CandidateError(f"invalid JSON: {path}") from exc
    if not isinstance(value, dict):
        raise CandidateError(f"expected JSON object: {path}")
    return value


def read_json(path: Path) -> dict:
    return strict_json_bytes(path.read_bytes(), path.relative_to(REPO).as_posix())


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def exact_keys(value: dict, expected: set[str], location: str) -> None:
    actual = set(value)
    if actual != expected:
        raise CandidateError(
            f"{location} keys mismatch: missing={sorted(expected - actual)} extra={sorted(actual - expected)}"
        )


def validate_candidate_scope(scope: dict) -> None:
    exact_keys(
        scope,
        {"schemaVersion", "release", "launch", "excludedMainnetApplications", "testnetCompatibility"},
        "scope",
    )
    if scope["schemaVersion"] != "swaputer-release-scope/1":
        raise CandidateError("unsupported candidate scope schema")
    release = scope["release"]
    launch = scope["launch"]
    compatibility = scope["testnetCompatibility"]
    if not isinstance(release, dict) or not isinstance(launch, dict) or not isinstance(compatibility, dict):
        raise CandidateError("candidate scope objects are malformed")
    exact_keys(
        release,
        {"name", "protocolVersion", "status", "candidateKind", "mainnetAuthorized", "signatureStatus"},
        "scope.release",
    )
    expected_release = {
        "name": CANDIDATE_TAG,
        "protocolVersion": "1.2",
        "status": "unaudited experimental",
        "candidateKind": "local-candidate-freeze",
        "mainnetAuthorized": False,
        "signatureStatus": "not-required-for-local-candidate-freeze",
    }
    if release != expected_release:
        raise CandidateError("candidate release policy mismatch")
    exact_keys(
        launch,
        {"profile", "contracts", "integratedComponents", "officialInterfaces", "routing", "observability"},
        "scope.launch",
    )
    if launch["profile"] != "core+explorer+studio+open-mint" or tuple(launch["contracts"]) != CORE_CONTRACTS:
        raise CandidateError("candidate core launch contract scope mismatch")
    if launch["integratedComponents"] != ["SwapVMMiniVM"]:
        raise CandidateError("candidate integrated component scope mismatch")
    if launch["officialInterfaces"] != ["explorer", "studio", "open-mint-minter"]:
        raise CandidateError("candidate official interface scope mismatch")
    if launch["routing"] != ["canonical-swaputer-router", "official-uniswap-universal-router-v4-swap"]:
        raise CandidateError("candidate routing scope mismatch")
    excluded = scope["excludedMainnetApplications"]
    if not isinstance(excluded, list) or [item.get("id") for item in excluded if isinstance(item, dict)] != [
        "src20-market",
        "seth",
        "auction",
    ]:
        raise CandidateError("candidate excluded application scope mismatch")
    expected_artifacts = {
        "src20-market": ["SwapVMSRC20Market", "SwaputerSRC20MarketFactory"],
        "seth": ["SwapVMSETHVault"],
        "auction": ["SwapVMSRC20AuctionHouse", "SwaputerSRC20AuctionFactory"],
    }
    for item in excluded:
        if not isinstance(item, dict):
            raise CandidateError("candidate excluded application entry is malformed")
        exact_keys(
            item,
            {
                "id",
                "contractArtifacts",
                "officialRoutes",
                "sourceDisposition",
                "deployedByOfficialLaunch",
                "officialInterfaceEnabled",
            },
            f"scope.excluded.{item.get('id')}",
        )
        if (
            item["contractArtifacts"] != expected_artifacts[item["id"]]
            or item["sourceDisposition"] != "evidence-only"
            or item["deployedByOfficialLaunch"] is not False
            or item["officialInterfaceEnabled"] is not False
        ):
            raise CandidateError(f"excluded application is not fail-closed: {item['id']}")
    exact_keys(
        compatibility,
        {"environments", "preserveMarket", "preserveSETH", "preserveAuctionEvidence"},
        "scope.testnetCompatibility",
    )
    if compatibility != {
        "environments": ["local", "testnet"],
        "preserveMarket": True,
        "preserveSETH": True,
        "preserveAuctionEvidence": True,
    }:
        raise CandidateError("testnet compatibility policy mismatch")


def validate_source_scope(scope: dict) -> None:
    expected_keys = {
        "schemaVersion",
        "pathFormat",
        "trackedFiles",
        "excludedExact",
        "preparationFiles",
        "submoduleGitlinks",
        "forbiddenBasenames",
        "allowedEnvironmentExamples",
        "forbiddenDirectoryNames",
        "forbiddenSuffixes",
        "secretScanExceptions",
    }
    exact_keys(scope, expected_keys, "sourceScope")
    if (
        scope["schemaVersion"] != "swaputer-source-scope/1"
        or scope["pathFormat"] != "repository-relative-posix"
        or scope["trackedFiles"] != "all"
    ):
        raise CandidateError("unsupported source scope")
    expected_exclusions = [
        "release/v1.2/candidate.json",
        "release/v1.2/source-files.sha256",
        "security-results/stage7m-s7b002.json",
        "security-results/stage7m-multiseed.json",
        "security-results/stage7m-base-mainnet-fork.json",
    ]
    if scope["excludedExact"] != expected_exclusions:
        raise CandidateError("source scope self-reference/evidence exclusions changed")
    if scope["submoduleGitlinks"] != ["lib/forge-std", "lib/v4-core", "lib/v4-periphery"]:
        raise CandidateError("top-level submodule scope changed")


def index_entries() -> tuple[set[str], dict[str, str]]:
    regular: set[str] = set()
    submodules: dict[str, str] = {}
    output = run(["git", "ls-files", "--stage", "-z"]).stdout
    for raw in output.split(b"\0"):
        if not raw:
            continue
        try:
            metadata, path_bytes = raw.split(b"\t", 1)
            mode, object_id, stage = metadata.decode("ascii").split()
            path = path_bytes.decode("utf-8")
        except (ValueError, UnicodeDecodeError) as exc:
            raise CandidateError("malformed Git index entry") from exc
        if stage != "0":
            raise CandidateError(f"unmerged Git index entry: {path}")
        if mode == "160000":
            submodules[path] = object_id
        elif mode in {"100644", "100755"}:
            regular.add(path)
        else:
            raise CandidateError(f"unsupported tracked file mode {mode}: {path}")
    return regular, submodules


def ref_entries(ref: str) -> tuple[set[str], dict[str, str]]:
    regular: set[str] = set()
    submodules: dict[str, str] = {}
    output = run(["git", "ls-tree", "-r", "-z", "--full-tree", ref]).stdout
    for raw in output.split(b"\0"):
        if not raw:
            continue
        try:
            metadata, path_bytes = raw.split(b"\t", 1)
            mode, object_type, object_id = metadata.decode("ascii").split()
            path = path_bytes.decode("utf-8")
        except (ValueError, UnicodeDecodeError) as exc:
            raise CandidateError(f"malformed Git tree entry for {ref}") from exc
        if mode == "160000" and object_type == "commit":
            submodules[path] = object_id
        elif mode in {"100644", "100755"} and object_type == "blob":
            regular.add(path)
        else:
            raise CandidateError(f"unsupported candidate tree entry {mode} {object_type}: {path}")
    return regular, submodules


def is_forbidden_path(path: str, scope: dict) -> bool:
    posix = PurePosixPath(path)
    if any(part in scope["forbiddenDirectoryNames"] for part in posix.parts[:-1]):
        return True
    name = posix.name
    if name in scope["allowedEnvironmentExamples"]:
        return False
    if name in scope["forbiddenBasenames"] or name.startswith(".env."):
        return True
    return any(name.endswith(suffix) for suffix in scope["forbiddenSuffixes"])


def validate_candidate_paths(paths: set[str], scope: dict) -> list[str]:
    included = paths - set(scope["excludedExact"])
    for path in included:
        if "\n" in path or "\r" in path or "\0" in path:
            raise CandidateError("source path contains a forbidden control character")
        if is_forbidden_path(path, scope):
            raise CandidateError(f"forbidden path in candidate: {path}")
    return sorted(included)


def worktree_source_paths(scope: dict) -> tuple[list[str], dict[str, str]]:
    tracked, submodules = index_entries()
    if set(submodules) != set(scope["submoduleGitlinks"]):
        raise CandidateError(f"top-level submodule gitlinks mismatch: {sorted(submodules)}")
    preparation = set(scope["preparationFiles"])
    for path in preparation:
        target = REPO / path
        if not target.is_file() or target.is_symlink():
            raise CandidateError(f"missing candidate preparation file: {path}")
    paths = validate_candidate_paths(tracked | preparation, scope)
    for path in paths:
        target = REPO / path
        if target.is_symlink() or not target.is_file():
            raise CandidateError(f"candidate path is not a regular file: {path}")
    return paths, submodules


def ref_source_paths(ref: str, scope: dict) -> tuple[list[str], dict[str, str]]:
    tracked, submodules = ref_entries(ref)
    if set(submodules) != set(scope["submoduleGitlinks"]):
        raise CandidateError(f"top-level submodule gitlinks mismatch at {ref}: {sorted(submodules)}")
    if "release/v1.2/candidate.json" in tracked:
        raise CandidateError("candidate.json must be post-tag evidence and cannot be stored in candidate commit C")
    return validate_candidate_paths(tracked, scope), submodules


def scan_secrets(paths: list[str], scope: dict, read_bytes: Callable[[str], bytes]) -> None:
    exceptions = {(item["rule"], item["path"]) for item in scope["secretScanExceptions"]}
    findings: list[tuple[str, str]] = []
    for path in paths:
        data = read_bytes(path)
        for rule, pattern in SECRET_RULES:
            if pattern.search(data) and (rule, path) not in exceptions:
                findings.append((rule, path))
    if findings:
        for rule, path in findings:
            print(f"CANDIDATE_SECRET_SCAN {rule} {path}", file=sys.stderr)
        raise CandidateError("secret scan failed; matched content intentionally omitted")


def source_lines(paths: list[str], read_bytes: Callable[[str], bytes]) -> bytes:
    return "".join(f"{sha256_bytes(read_bytes(path))}  {path}\n" for path in paths).encode("utf-8")


def parse_source_lines(data: bytes) -> dict[str, str]:
    output: dict[str, str] = {}
    try:
        lines = data.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        raise CandidateError("source hash list is not UTF-8") from exc
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\0\r\n]+)", line)
        if match is None:
            raise CandidateError("malformed source hash line")
        digest, path = match.groups()
        if path in output:
            raise CandidateError(f"duplicate source hash path: {path}")
        output[path] = digest
    return output


def inspect_bytecode(contract: str, field: str, root: Path) -> str:
    value = run(["forge", "inspect", contract, field], cwd=root).stdout.decode("ascii").strip()
    if not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", value):
        raise CandidateError(f"invalid forge bytecode output: {contract}.{field}")
    return value.lower()


def keccak_hex(value: str, root: Path) -> str:
    output = run(["cast", "keccak", value], cwd=root).stdout.decode("ascii").strip().lower()
    if not re.fullmatch(r"0x[0-9a-f]{64}", output):
        raise CandidateError("invalid cast keccak output")
    return output


def artifact_entry(contract: str, disposition: str, root: Path) -> dict:
    creation = inspect_bytecode(contract, "bytecode", root)
    runtime = inspect_bytecode(contract, "deployedBytecode", root)
    initcode_bytes = (len(creation) - 2) // 2
    runtime_bytes = (len(runtime) - 2) // 2
    return {
        "disposition": disposition,
        "creationCodeHash": keccak_hex(creation, root),
        "templateRuntimeCodeHash": keccak_hex(runtime, root),
        "initcodeBytes": initcode_bytes,
        "runtimeBytes": runtime_bytes,
        "eip170MarginBytes": 24_576 - runtime_bytes,
        "eip3860MarginBytes": 49_152 - initcode_bytes,
    }


def build_artifacts(root: Path = REPO) -> dict:
    # `forge inspect` may otherwise reuse an artifact compiled before recursive
    # submodules changed auto-detected remappings. A forced build makes the
    # recorded metadata-bearing bytecode match a fresh candidate checkout.
    run(
        ["forge", "build", "--force", "--skip", "test", "--skip", "script"],
        cwd=root,
    )
    contracts: dict[str, dict] = {}
    for name in CORE_CONTRACTS:
        contracts[name] = artifact_entry(name, "official-launch", root)
    for name in EXCLUDED_APPLICATION_CONTRACTS:
        contracts[name] = artifact_entry(name, "evidence-only-excluded-mainnet-application", root)
    for name, item in contracts.items():
        if item["runtimeBytes"] > 24_576 or item["initcodeBytes"] > 49_152:
            raise CandidateError(f"contract exceeds protocol code-size ceiling: {name}")
    return {
        "schemaVersion": "swaputer-artifact-inventory/1",
        "compilerProfile": "solc-0.8.26-via-ir-optimizer-200-cancun",
        "limits": {"eip170RuntimeBytes": 24_576, "eip3860InitcodeBytes": 49_152},
        "contracts": contracts,
        "integratedComponents": {
            "SwapVMMiniVM": {
                "standaloneDeployment": False,
                "ownedByArtifact": "SwapVMKernel",
                "source": "src/SwapVMMiniVM.sol",
                "sourceSha256": sha256_file(root / "src/SwapVMMiniVM.sol"),
            }
        },
        "creationCodeStoreCommitments": {
            "kernel": contracts["SwapVMKernel"]["creationCodeHash"],
            "hook": contracts["SwapVMHook"]["creationCodeHash"],
        },
    }


def command_version(arguments: list[str]) -> str:
    result = run(arguments)
    output = result.stdout or result.stderr
    return output.decode("utf-8", errors="strict").strip()


def build_toolchain(root: Path, tracked: set[str]) -> dict:
    lockfiles = sorted(path for path in tracked if path.endswith("package-lock.json"))
    go_files = sorted(path for path in tracked if path.endswith("/go.mod") or path.endswith("/go.sum"))
    dockerfiles = sorted(
        path
        for path in tracked
        if PurePosixPath(path).name == "Dockerfile" or path.endswith(".Dockerfile")
    )
    images: list[dict] = []
    for path in dockerfiles:
        for line in (root / path).read_text(encoding="utf-8").splitlines():
            match = re.match(r"^FROM\s+([^\s]+)", line)
            if match is None or match.group(1).startswith("${"):
                continue
            reference = match.group(1)
            images.append(
                {"dockerfile": path, "reference": reference, "digestPinned": "@sha256:" in reference}
            )
    frozen = [
        "docs/spec/SwapVM-v1.2-executor-context-spec.md",
        "docs/spec/SwapVM-ISA-v2.json",
        "docs/spec/SwapVM-v1.2-freeze-manifest.json",
        "docs/spec/SwapVM-v1.1-frozen-spec.md",
        "docs/spec/SwapVM-ISA-v1.json",
        "docs/spec/SwapVM-v1.1-freeze-manifest.json",
    ]
    return {
        "schemaVersion": "swaputer-toolchain/1",
        "versions": {
            "forge": command_version(["forge", "--version"]),
            "cast": command_version(["cast", "--version"]),
            "node": command_version(["node", "--version"]),
            "npm": command_version(["npm", "--version"]),
            "python": command_version(["python3", "--version"]),
            "go": command_version(["go", "version"]),
        },
        "lockfilesSha256": {path: sha256_file(root / path) for path in lockfiles},
        "goModuleFilesSha256": {path: sha256_file(root / path) for path in go_files},
        "frozenFilesSha256": {path: sha256_file(root / path) for path in frozen},
        "buildConfigurationSha256": {
            "foundry.toml": sha256_file(root / "foundry.toml"),
            "requirements-security.txt": sha256_file(root / "requirements-security.txt"),
        },
        "dockerfilesSha256": {path: sha256_file(root / path) for path in dockerfiles},
        "containerImages": images,
        "containerImagesFullyDigestPinned": all(item["digestPinned"] for item in images),
        "mainnetImagePinningDeferred": True,
    }


def build_submodules(expected_top_level: dict[str, str]) -> dict:
    entries: list[dict] = []
    output = run(["git", "submodule", "status", "--recursive"]).stdout.decode("utf-8")
    for line in output.splitlines():
        match = re.fullmatch(r"(.)([0-9a-f]{40}) ([^ ]+)(?: .*)?", line)
        if match is None:
            raise CandidateError(f"malformed recursive submodule status: {line}")
        state, commit, path = match.groups()
        if state != " ":
            raise CandidateError(f"submodule is uninitialized, conflicted or at the wrong commit: {path}")
        if run(
            ["git", "-C", path, "status", "--porcelain", "--ignore-submodules=none"]
        ).stdout:
            raise CandidateError(f"dirty submodule: {path}")
        entries.append({"path": path, "commit": commit})
    if not entries:
        raise CandidateError("no recursive submodules discovered")
    actual_top_level = {
        entry["path"]: entry["commit"]
        for entry in entries
        if entry["path"] in expected_top_level
    }
    if actual_top_level != expected_top_level:
        raise CandidateError(
            f"checked-out top-level submodules do not match candidate: expected={expected_top_level} actual={actual_top_level}"
        )
    return {
        "schemaVersion": "swaputer-submodules/1",
        "recursive": True,
        "submodules": entries,
    }


def validate_feature_gate(scope: dict, root: Path = REPO) -> None:
    feature_source = (root / "apps/swaputer-web/src/lib/releaseScope.ts").read_text(encoding="utf-8")
    router_source = (root / "apps/swaputer-web/src/router.ts").read_text(encoding="utf-8")
    header_source = (root / "apps/swaputer-web/src/components/AppHeader.vue").read_text(encoding="utf-8")
    required = ["explorer: true", "studio: true", "openMintMinter: true", "applicationTestEnvironment"]
    if any(token not in feature_source for token in required):
        raise CandidateError("web feature scope implementation drift")
    for token in ["OFFICIAL_FEATURES.market", "OFFICIAL_FEATURES.seth"]:
        if token not in router_source or token not in header_source:
            raise CandidateError(f"web route/navigation feature gate missing: {token}")
    excluded = {item["id"] for item in scope["excludedMainnetApplications"]}
    if excluded != {"src20-market", "seth", "auction"}:
        raise CandidateError("web feature gate does not match excluded application scope")


def verify_source_list(
    paths: list[str], recorded_bytes: bytes, read_bytes: Callable[[str], bytes]
) -> None:
    recorded = parse_source_lines(recorded_bytes)
    if set(recorded) != set(paths):
        raise CandidateError(
            f"source path set mismatch: missing={sorted(set(paths) - set(recorded))} "
            f"extra={sorted(set(recorded) - set(paths))}"
        )
    for path in paths:
        if recorded[path] != sha256_bytes(read_bytes(path)):
            raise CandidateError(f"source hash mismatch: {path}")


def resolve_candidate_tag(ref: str) -> dict:
    if ref != CANDIDATE_TAG and ref != f"refs/tags/{CANDIDATE_TAG}":
        raise CandidateError(f"release-candidate ref must be the fixed tag {CANDIDATE_TAG}")
    full_ref = f"refs/tags/{CANDIDATE_TAG}"
    tag_result = run(["git", "rev-parse", "--verify", full_ref], check=False)
    if tag_result.returncode != 0:
        raise CandidateError(f"candidate tag is not present: {CANDIDATE_TAG}")
    tag_object = tag_result.stdout.decode("ascii").strip()
    tag_type = run(["git", "cat-file", "-t", tag_object]).stdout.decode("ascii").strip()
    if tag_type != "tag":
        raise CandidateError("candidate tag must be annotated")
    candidate_commit = run(["git", "rev-parse", f"{full_ref}^{{commit}}"]).stdout.decode("ascii").strip()
    candidate_tree = run(["git", "rev-parse", f"{candidate_commit}^{{tree}}"]).stdout.decode("ascii").strip()
    return {
        "candidateTag": CANDIDATE_TAG,
        "tagStatus": "frozen",
        "tagObject": tag_object,
        "tagType": "annotated",
        "candidateCommit": candidate_commit,
        "candidateTree": candidate_tree,
    }


def ref_blob(ref: str, path: str) -> bytes:
    result = run(["git", "show", f"{ref}:{path}"], check=False)
    if result.returncode != 0:
        raise CandidateError(f"missing candidate file at {ref}: {path}")
    return result.stdout


def extract_git_archive(repository: Path, ref: str, destination: Path) -> None:
    archive = run(
        ["git", "-C", str(repository), "archive", "--format=tar", ref]
    ).stdout
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as bundle:
        for member in bundle.getmembers():
            relative = PurePosixPath(member.name)
            if relative.is_absolute() or ".." in relative.parts:
                raise CandidateError("unsafe path in candidate Git archive")
            target = destination.joinpath(*relative.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                raise CandidateError(f"unsupported archive entry type: {member.name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            source = bundle.extractfile(member)
            if source is None:
                raise CandidateError(f"cannot read archive entry: {member.name}")
            target.write_bytes(source.read())
            target.chmod(member.mode & 0o777)


@contextmanager
def materialize_ref(ref: str, submodules: dict[str, str]) -> Iterator[Path]:
    """Materialize exact main-repository and recursive-submodule Git objects.

    Copying archives preserves repository-relative Solidity source-unit names.
    Symlinking a submodule checkout can leak its absolute host path into solc
    metadata and make otherwise identical bytecode hashes checkout-dependent.
    """

    with tempfile.TemporaryDirectory(prefix="swaputer-v1.2-candidate-") as directory:
        root = Path(directory)
        extract_git_archive(REPO, ref, root)
        for path, commit in sorted(
            submodules.items(), key=lambda item: (item[0].count("/"), item[0])
        ):
            checkout = REPO / path
            actual = run(["git", "-C", str(checkout), "rev-parse", "HEAD"]).stdout.decode("ascii").strip()
            if actual != commit:
                raise CandidateError(f"local submodule checkout does not match {ref}: {path}")
            target = root / path
            if target.exists():
                if target.is_dir():
                    shutil.rmtree(target)
                else:
                    target.unlink()
            extract_git_archive(checkout, commit, target)
        yield root


def commitment_fields(
    paths: list[str],
    scope_bytes: bytes,
    source_list_bytes: bytes,
    artifact_bytes: bytes,
    toolchain_bytes: bytes,
    submodule_bytes: bytes,
    freeze: dict,
) -> dict:
    return {
        "scopeSha256": sha256_bytes(scope_bytes),
        "sourceListSha256": sha256_bytes(source_list_bytes),
        "sourceFileCount": len(paths),
        "artifactInventorySha256": sha256_bytes(artifact_bytes),
        "toolchainSha256": sha256_bytes(toolchain_bytes),
        "submodulesSha256": sha256_bytes(submodule_bytes),
        "specSha256": freeze["specification"]["sha256"],
        "isaKeccak256": freeze["isa"]["keccak256"],
    }


def build_candidate(scope: dict, source_control: dict, commitments: dict) -> dict:
    report = {
        "schemaVersion": "swaputer-release-candidate/1",
        "release": {
            "name": scope["release"]["name"],
            "protocolVersion": scope["release"]["protocolVersion"],
            "status": scope["release"]["status"],
            "candidateKind": scope["release"]["candidateKind"],
            "mainnetAuthorized": scope["release"]["mainnetAuthorized"],
        },
        "sourceControl": source_control,
        "scope": {
            "path": "release/v1.2/candidate-scope.json",
            "profile": scope["launch"]["profile"],
            "includedContracts": scope["launch"]["contracts"],
            "officialInterfaces": scope["launch"]["officialInterfaces"],
            "excludedMainnetApplications": [
                item["id"] for item in scope["excludedMainnetApplications"]
            ],
        },
        "commitments": commitments,
        "verification": {
            "exactTrackedSourceHashes": True,
            "submoduleCommits": True,
            "artifactHashesAndSizes": True,
            "secretScan": True,
            "forbiddenPaths": True,
            "featureScope": True,
            "candidateTagResolved": True,
            "tagPeelsToCandidateCommit": True,
        },
        "signature": {
            "status": scope["release"]["signatureStatus"],
            "algorithm": None,
            "signer": None,
            "message": None,
            "signature": None,
        },
    }
    report["integrity"] = {
        "algorithm": "sha256",
        "reportHash": sha256_bytes(canonical_json(report).encode("utf-8")),
    }
    return report


def validate_candidate_integrity(candidate: dict) -> None:
    exact_keys(
        candidate,
        {"schemaVersion", "release", "sourceControl", "scope", "commitments", "verification", "signature", "integrity"},
        "candidate",
    )
    integrity = candidate["integrity"]
    if (
        not isinstance(integrity, dict)
        or integrity.get("algorithm") != "sha256"
        or not re.fullmatch(r"[0-9a-f]{64}", str(integrity.get("reportHash", "")))
    ):
        raise CandidateError("candidate integrity record is malformed")
    payload = {key: value for key, value in candidate.items() if key != "integrity"}
    expected = sha256_bytes(canonical_json(payload).encode("utf-8"))
    if integrity["reportHash"] != expected:
        raise CandidateError("candidate report hash mismatch")


def generate() -> dict:
    scope = read_json(SCOPE_PATH)
    source_scope = read_json(SOURCE_SCOPE_PATH)
    validate_candidate_scope(scope)
    validate_source_scope(source_scope)
    validate_feature_gate(scope)
    tracked, submodule_gitlinks = index_entries()
    write_json(ARTIFACTS_PATH, build_artifacts(REPO))
    write_json(
        TOOLCHAIN_PATH,
        build_toolchain(REPO, tracked | set(source_scope["preparationFiles"])),
    )
    write_json(SUBMODULES_PATH, build_submodules(submodule_gitlinks))
    paths, _submodules = worktree_source_paths(source_scope)
    reader = lambda path: (REPO / path).read_bytes()
    scan_secrets(paths, source_scope, reader)
    source_list = source_lines(paths, reader)
    SOURCE_LIST_PATH.write_bytes(source_list)
    return {
        "candidate": scope["release"]["name"],
        "mainnetAuthorized": False,
        "signatureStatus": scope["release"]["signatureStatus"],
        "sourceFileCount": len(paths),
        "status": "PRETAG_READY",
        "tagStatus": "pending",
        "candidateEvidence": "not-generated-before-tag",
        "sourceListSha256": sha256_bytes(source_list),
    }


def verify_worktree() -> dict:
    scope = read_json(SCOPE_PATH)
    source_scope = read_json(SOURCE_SCOPE_PATH)
    validate_candidate_scope(scope)
    validate_source_scope(source_scope)
    validate_feature_gate(scope)
    paths, submodule_gitlinks = worktree_source_paths(source_scope)
    reader = lambda path: (REPO / path).read_bytes()
    scan_secrets(paths, source_scope, reader)
    verify_source_list(paths, SOURCE_LIST_PATH.read_bytes(), reader)
    tracked, _submodules = index_entries()
    if read_json(ARTIFACTS_PATH) != build_artifacts(REPO):
        raise CandidateError("artifact inventory mismatch")
    if read_json(TOOLCHAIN_PATH) != build_toolchain(
        REPO, tracked | set(source_scope["preparationFiles"])
    ):
        raise CandidateError("toolchain inventory mismatch")
    if read_json(SUBMODULES_PATH) != build_submodules(submodule_gitlinks):
        raise CandidateError("recursive submodule inventory mismatch")
    return {
        "candidate": scope["release"]["name"],
        "mainnetAuthorized": False,
        "signatureStatus": scope["release"]["signatureStatus"],
        "sourceFileCount": len(paths),
        "status": "WORKTREE_PASS",
        "tagStatus": "pending",
        "candidateEvidence": "not-required-before-tag",
        "sourceListSha256": sha256_file(SOURCE_LIST_PATH),
    }


def verify_ref(ref: str, *, verify_evidence: bool = True) -> tuple[dict, Optional[dict]]:
    source_control = resolve_candidate_tag(ref)
    immutable_ref = source_control["candidateCommit"]
    scope_bytes = ref_blob(immutable_ref, "release/v1.2/candidate-scope.json")
    source_scope_bytes = ref_blob(immutable_ref, "release/v1.2/source-scope.json")
    source_list_bytes = ref_blob(immutable_ref, "release/v1.2/source-files.sha256")
    artifact_bytes = ref_blob(immutable_ref, "release/v1.2/artifacts.json")
    toolchain_bytes = ref_blob(immutable_ref, "release/v1.2/toolchain.json")
    submodule_bytes = ref_blob(immutable_ref, "release/v1.2/submodules.json")
    freeze_bytes = ref_blob(immutable_ref, "docs/spec/SwapVM-v1.2-freeze-manifest.json")
    scope = strict_json_bytes(scope_bytes, f"{immutable_ref}:candidate-scope.json")
    source_scope = strict_json_bytes(source_scope_bytes, f"{immutable_ref}:source-scope.json")
    artifacts = strict_json_bytes(artifact_bytes, f"{immutable_ref}:artifacts.json")
    toolchain = strict_json_bytes(toolchain_bytes, f"{immutable_ref}:toolchain.json")
    submodule_inventory = strict_json_bytes(submodule_bytes, f"{immutable_ref}:submodules.json")
    freeze = strict_json_bytes(freeze_bytes, f"{immutable_ref}:freeze-manifest.json")
    validate_candidate_scope(scope)
    validate_source_scope(source_scope)
    paths, submodule_gitlinks = ref_source_paths(immutable_ref, source_scope)
    reader = lambda path: ref_blob(immutable_ref, path)
    scan_secrets(paths, source_scope, reader)
    verify_source_list(paths, source_list_bytes, reader)
    if submodule_inventory != build_submodules(submodule_gitlinks):
        raise CandidateError("recursive submodule inventory mismatch at candidate tag")
    recursive_submodules = {
        entry["path"]: entry["commit"]
        for entry in submodule_inventory.get("submodules", [])
        if isinstance(entry, dict) and set(entry) == {"path", "commit"}
    }
    if len(recursive_submodules) != len(submodule_inventory.get("submodules", [])):
        raise CandidateError("recursive submodule inventory is malformed")
    with materialize_ref(immutable_ref, recursive_submodules) as root:
        validate_feature_gate(scope, root)
        if artifacts != build_artifacts(root):
            raise CandidateError("artifact inventory mismatch at candidate tag")
        tracked, _gitlinks = ref_entries(immutable_ref)
        if toolchain != build_toolchain(root, tracked):
            raise CandidateError("toolchain inventory mismatch at candidate tag")
    commitments = commitment_fields(
        paths,
        scope_bytes,
        source_list_bytes,
        artifact_bytes,
        toolchain_bytes,
        submodule_bytes,
        freeze,
    )
    expected = build_candidate(scope, source_control, commitments)
    evidence: Optional[dict] = None
    if verify_evidence and CANDIDATE_PATH.is_file():
        evidence = read_json(CANDIDATE_PATH)
        validate_candidate_integrity(evidence)
        if evidence != expected:
            raise CandidateError("candidate evidence does not bind exactly to the requested tag")
    return expected, evidence


def finalize(ref: str) -> dict:
    candidate, _evidence = verify_ref(ref, verify_evidence=False)
    write_json(CANDIDATE_PATH, candidate)
    return candidate


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("generate", "verify", "finalize"))
    parser.add_argument("--ref", help=f"candidate tag (must be {CANDIDATE_TAG})")
    args = parser.parse_args()
    try:
        if args.command == "generate":
            if args.ref:
                raise CandidateError("generate is pre-tag only and does not accept --ref")
            result = generate()
        elif args.command == "finalize":
            if not args.ref:
                raise CandidateError("finalize requires --ref")
            candidate = finalize(args.ref)
            result = {
                "candidate": candidate["release"]["name"],
                "mainnetAuthorized": candidate["release"]["mainnetAuthorized"],
                "signatureStatus": candidate["signature"]["status"],
                "sourceFileCount": candidate["commitments"]["sourceFileCount"],
                "status": "FINALIZED",
                "tagStatus": candidate["sourceControl"]["tagStatus"],
                "candidateCommit": candidate["sourceControl"]["candidateCommit"],
            }
        elif args.ref:
            candidate, evidence = verify_ref(args.ref)
            result = {
                "candidate": candidate["release"]["name"],
                "mainnetAuthorized": candidate["release"]["mainnetAuthorized"],
                "signatureStatus": candidate["signature"]["status"],
                "sourceFileCount": candidate["commitments"]["sourceFileCount"],
                "status": "TAG_PASS",
                "tagStatus": candidate["sourceControl"]["tagStatus"],
                "candidateCommit": candidate["sourceControl"]["candidateCommit"],
                "candidateEvidence": "verified" if evidence is not None else "not-present",
            }
        else:
            result = verify_worktree()
        print(canonical_json(result))
        return 0
    except (CandidateError, OSError) as exc:
        print(f"RELEASE_CANDIDATE_ERROR {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
