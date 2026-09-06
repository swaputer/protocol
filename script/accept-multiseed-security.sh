#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ "$#" -gt 1 ]]; then
  echo "usage: $0 [evidence-output.json]" >&2
  exit 2
fi

for command_name in forge jq node shasum; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "$command_name is required" >&2; exit 1; }
done

[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "multi-seed security acceptance requires a clean Git worktree" >&2
  exit 1
}

readonly seeds=(
  "0x7b2026"
  "0x98955c53cc5e0520c37e8dca375bfe7fb029aab60034d35a92c2224bc8c45e69"
  "0xdd1939302dff644f8ea811456724a65f06b6a7d31b1cfb1c7f0635772d33c7ad"
)
readonly fuzz_contract_pattern='^SwapVM(Stage1|Stage2|Stage4|Stage5|Stage7BSecurity)Test$'
readonly invariant_contract_pattern='^SwapVM(Stage1|Stage2|Stage4|Stage5|Stage7BRouter|Stage7BFactory|SETHVault|SRC20Market|Authorization|Resource)InvariantTest$'
readonly fuzz_runs=4096
readonly fuzz_properties=11
readonly invariant_runs=256
readonly invariant_depth=64
readonly invariants=22
readonly calls_per_invariant=16384

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/swaputer-multiseed.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
results_path="$work_dir/results.json"
draft_path="$work_dir/draft.json"
sealed_path="$work_dir/evidence.json"
printf '[]\n' >"$results_path"

hash_file() {
  printf '0x%s' "$(shasum -a 256 "$1" | awk '{print $1}')"
}

for seed in "${seeds[@]}"; do
  echo "[multi-seed] fuzz seed $seed" >&2
  fuzz_log="$work_dir/fuzz-${seed#0x}.log"
  started="$(date +%s)"
  if ! NO_COLOR=1 FOUNDRY_PROFILE=security FOUNDRY_FUZZ_SEED="$seed" \
    forge test \
      --match-contract "$fuzz_contract_pattern" \
      --match-test '^testFuzz_' \
      --fuzz-seed "$seed" >"$fuzz_log" 2>&1; then
    tail -n 120 "$fuzz_log" >&2
    echo "multi-seed fuzz campaign failed for seed $seed" >&2
    exit 1
  fi
  fuzz_duration=$(($(date +%s) - started))
  fuzz_passed="$(grep -Ec '^\[PASS\] testFuzz_' "$fuzz_log" || true)"
  fuzz_full_runs="$(grep -Ec '^\[PASS\] testFuzz_.*\(runs: 4096,' "$fuzz_log" || true)"
  [[ "$fuzz_passed" -eq "$fuzz_properties" && "$fuzz_full_runs" -eq "$fuzz_properties" ]] || {
    echo "seed $seed did not complete all $fuzz_properties fuzz properties at $fuzz_runs runs" >&2
    exit 1
  }

  echo "[multi-seed] invariants seed $seed" >&2
  invariant_log="$work_dir/invariant-${seed#0x}.log"
  started="$(date +%s)"
  if ! NO_COLOR=1 \
    FOUNDRY_PROFILE=security \
    FOUNDRY_FUZZ_SEED="$seed" \
    FOUNDRY_INVARIANT_FAIL_ON_REVERT=true \
    forge test \
      --match-contract "$invariant_contract_pattern" \
      --match-test '^invariant_' \
      --fuzz-seed "$seed" >"$invariant_log" 2>&1; then
    tail -n 120 "$invariant_log" >&2
    echo "multi-seed invariant campaign failed for seed $seed" >&2
    exit 1
  fi
  invariant_duration=$(($(date +%s) - started))
  invariant_passed="$(grep -Ec '^\[PASS\] invariant_' "$invariant_log" || true)"
  invariant_full_runs="$(grep -Ec '^\[PASS\] invariant_.*\(runs: 256, calls: 16384, reverts: 0\)' "$invariant_log" || true)"
  [[ "$invariant_passed" -eq "$invariants" && "$invariant_full_runs" -eq "$invariants" ]] || {
    echo "seed $seed did not complete all $invariants invariants at ${invariant_runs}x${invariant_depth} with zero reverts" >&2
    exit 1
  }

  result="$(jq -nc \
    --arg seed "$seed" \
    --arg fuzzHash "$(hash_file "$fuzz_log")" \
    --arg invariantHash "$(hash_file "$invariant_log")" \
    --argjson fuzzDuration "$fuzz_duration" \
    --argjson invariantDuration "$invariant_duration" \
    --argjson fuzzPassed "$fuzz_passed" \
    --argjson invariantPassed "$invariant_passed" \
    '{seed:$seed,status:"passed",
      fuzz:{passed:$fuzzPassed,runsPerProperty:4096,durationSeconds:$fuzzDuration,outputSha256:$fuzzHash},
      invariants:{passed:$invariantPassed,runsPerInvariant:256,depth:64,callsPerInvariant:16384,unexpectedReverts:0,durationSeconds:$invariantDuration,outputSha256:$invariantHash}}')"
  jq --argjson result "$result" '. + [$result]' "$results_path" >"$work_dir/results.next.json"
  mv "$work_dir/results.next.json" "$results_path"
done

source_commit="$(git rev-parse HEAD)"
forge_version="$(forge --version | awk -F': ' 'NR == 1 { sub(/^forge Version: /, ""); print; exit }')"
forge_commit="$(forge --version | awk -F': ' '$1 == "Commit SHA" { print $2; exit }')"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg generatedAt "$generated_at" \
  --arg sourceCommit "$source_commit" \
  --arg forgeVersion "$forge_version" \
  --arg forgeCommit "$forge_commit" \
  --arg fuzzContractPattern "$fuzz_contract_pattern" \
  --arg invariantContractPattern "$invariant_contract_pattern" \
  --slurpfile seedResults "$results_path" \
  '{schemaVersion:"swaputer-multiseed-security/1",generatedAt:$generatedAt,status:"passed",
    source:{commit:$sourceCommit,treeState:"clean"},
    toolchain:{forgeVersion:$forgeVersion,forgeCommit:$forgeCommit},
    campaign:{profile:"security",releaseSeed:"0x7b2026",
      supplementalSeedDerivation:"keccak256(swaputer-v1.2-internal-assurance/seed/{0,1})",seedCount:3,
      seeds:["0x7b2026","0x98955c53cc5e0520c37e8dca375bfe7fb029aab60034d35a92c2224bc8c45e69","0xdd1939302dff644f8ea811456724a65f06b6a7d31b1cfb1c7f0635772d33c7ad"],
      fuzz:{runsPerProperty:4096,propertyCount:11,contractPattern:$fuzzContractPattern,testPattern:"^testFuzz_"},
      invariants:{runsPerInvariant:256,depth:64,invariantCount:22,callsPerInvariant:16384,failOnRevert:true,seedPolicy:"all-required-seeds",
        contracts:[
          {name:"SwapVMStage1InvariantTest",properties:2},
          {name:"SwapVMStage2InvariantTest",properties:2},
          {name:"SwapVMStage4InvariantTest",properties:2},
          {name:"SwapVMStage5InvariantTest",properties:2},
          {name:"SwapVMStage7BRouterInvariantTest",properties:2},
          {name:"SwapVMStage7BFactoryInvariantTest",properties:2},
          {name:"SwapVMSETHVaultInvariantTest",properties:3},
          {name:"SwapVMSRC20MarketInvariantTest",properties:3},
          {name:"SwapVMAuthorizationInvariantTest",properties:2},
          {name:"SwapVMResourceInvariantTest",properties:2}],
        contractPattern:$invariantContractPattern,testPattern:"^invariant_"}},
    results:$seedResults[0],
    totals:{fuzzExecutions:135168,invariantActionCalls:1081344,failures:0}}' >"$draft_path"

node script/stage7m-assurance-evidence.mjs seal-multiseed "$draft_path" "$sealed_path" >/dev/null
node script/stage7m-assurance-evidence.mjs validate-multiseed "$sealed_path" >/dev/null

if [[ "$#" -eq 1 ]]; then
  output_path="$1"
  [[ ! -e "$output_path" ]] || { echo "refusing to overwrite existing evidence: $output_path" >&2; exit 1; }
  mkdir -p "$(dirname "$output_path")"
  cp "$sealed_path" "$output_path"
fi

jq -c . "$sealed_path"
