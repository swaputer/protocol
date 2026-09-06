#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

readonly candidate_tag="swaputer-v1.2-stage7m-rc3"
readonly candidate_file="release/v1.2/candidate.json"
readonly s7b002_file="security-results/stage7m-s7b002.json"
readonly multiseed_file="security-results/stage7m-multiseed.json"
readonly fork_file="security-results/stage7m-base-mainnet-fork.json"

for command_name in git jq node npm python3 shasum; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "$command_name is required" >&2; exit 1; }
done

for required_file in "$candidate_file" "$s7b002_file" "$multiseed_file" "$fork_file"; do
  [[ -f "$required_file" ]] || { echo "missing Stage 7M evidence: $required_file" >&2; exit 1; }
done

candidate_commit="$(git rev-parse --verify "refs/tags/${candidate_tag}^{commit}")"
[[ "$(git cat-file -t "refs/tags/$candidate_tag")" == "tag" ]] || {
  echo "candidate tag must be annotated: $candidate_tag" >&2
  exit 1
}

python3 script/release_candidate.py verify --ref "$candidate_tag" >/dev/null
npm run build --prefix tooling/deployment-manifest >/dev/null
node script/s7b002-evidence.mjs verify "$s7b002_file" --formal >/dev/null
node script/stage7m-assurance-evidence.mjs validate-multiseed "$multiseed_file" >/dev/null
node script/stage7m-assurance-evidence.mjs validate-fork "$fork_file" >/dev/null

[[ "$(jq -er '.sourceControl.candidateCommit' "$candidate_file")" == "$candidate_commit" ]] || {
  echo "candidate evidence does not bind the frozen candidate commit" >&2
  exit 1
}

for evidence_file in "$s7b002_file" "$multiseed_file" "$fork_file"; do
  [[ "$(jq -er '.source.commit' "$evidence_file")" == "$candidate_commit" ]] || {
    echo "$evidence_file does not bind the frozen candidate commit" >&2
    exit 1
  }
  [[ "$(jq -er '.source.treeState' "$evidence_file")" == "clean" ]] || {
    echo "$evidence_file was not generated from a clean candidate tree" >&2
    exit 1
  }
done

[[ "$(jq -er '.source.formalCandidateEligible' "$s7b002_file")" == "true" ]] || {
  echo "$s7b002_file is not formal candidate evidence" >&2
  exit 1
}

while IFS=$'\t' read -r source_path expected_hash; do
  actual_hash="0x$(git show "${candidate_commit}:${source_path}" | shasum -a 256 | awk '{print $1}')"
  [[ "$actual_hash" == "$expected_hash" ]] || {
    echo "S7B-002 candidate source hash mismatch: $source_path" >&2
    exit 1
  }
done < <(jq -r '.source.files[] | [.path, .sha256] | @tsv' "$s7b002_file")

jq -nc \
  --arg candidateTag "$candidate_tag" \
  --arg candidateCommit "$candidate_commit" \
  --arg candidateReportHash "$(jq -er '.integrity.reportHash' "$candidate_file")" \
  --arg s7b002ReportHash "$(jq -er '.integrity.reportHash' "$s7b002_file")" \
  --arg multiseedReportHash "$(jq -er '.integrity.reportHash' "$multiseed_file")" \
  --arg forkReportHash "$(jq -er '.integrity.reportHash' "$fork_file")" \
  '{status:"passed",candidateTag:$candidateTag,candidateCommit:$candidateCommit,
    reportHashes:{candidate:$candidateReportHash,s7b002:$s7b002ReportHash,multiseed:$multiseedReportHash,baseMainnetFork:$forkReportHash}}'
