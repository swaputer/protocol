#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ "$#" -gt 1 ]]; then
  echo "usage: $0 [evidence-output.json]" >&2
  exit 2
fi

for command_name in cast forge git jq node rg shasum; do
  command -v "$command_name" >/dev/null 2>&1 || { echo "$command_name is required" >&2; exit 1; }
done

machine_stop() {
  local status="$1"
  local reason="$2"
  jq -nc \
    --arg status "$status" \
    --arg reason "$reason" \
    '{schemaVersion:"swaputer-base-mainnet-fork-rehearsal/1",status:$status,reason:$reason,rpcUrlRecorded:false}'
  exit 1
}

[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  machine_stop blocked SOURCE_TREE_NOT_CLEAN
}

readonly test_path="test/fork/SwapVMBaseMainnetFork.t.sol"
readonly public_rpc="https://mainnet.base.org"
readonly pool_manager="0x498581ff718922c3f8e6a244956af099b2652b2b"
readonly position_manager="0x7c5f5a4bbd8fd63184577525326123b519429bdc"
readonly permit2="0x000000000022d473030f116ddee9f6b43ac78ba3"
readonly universal_router="0xfdf682f51fe81aa4898f0ae2163d8a55c127fbc7"
readonly pool_manager_hash="0x83b2af6e9f3158defc2811cbcb0db71ecf8b2ba2abea39c39e370ac5c6f43eb6"
readonly position_manager_hash="0x243f9e091ddf11c7c04e28059fdbbf1bab82b72d414fafb8e096c097aaeb622a"
readonly permit2_hash="0xa67739abc3ede9dbdc0491636c67d6a14ac07fab9030c3f509b1eb7b11dff8ed"
readonly universal_router_hash="0x4436f45787722467059726381c27a999d0725a7a8b6ae2c4217223987275e3ef"

if [[ -n "${SVM_BASE_MAINNET_FORK_RPC_URL:-}" ]]; then
  rpc_url="$SVM_BASE_MAINNET_FORK_RPC_URL"
  provider_source="environment"
else
  rpc_url="$public_rpc"
  provider_source="official-public-fallback"
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/swaputer-base-mainnet-fork.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
rpc_error="$work_dir/rpc-error.log"
test_log="$work_dir/forge-test.log"
draft_path="$work_dir/draft.json"
sealed_path="$work_dir/evidence.json"

# Keep transient TLS/provider interruptions out of the result if a retry succeeds.
rpc_retry() {
  local attempt
  local output
  for attempt in 1 2 3 4 5; do
    if output="$("$@" 2>"$rpc_error")"; then
      printf '%s' "$output"
      return 0
    fi
    if [[ "$attempt" -lt 5 ]]; then
      sleep "$attempt"
    fi
  done
  return 1
}

normalize_address() {
  tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

hash_file() {
  printf '0x%s' "$(shasum -a 256 "$1" | awk '{print $1}')"
}

# The rehearsal must remain a forge test. Broadcast cheatcodes, release secrets and
# mainnet deployment configuration are outside this gate by construction.
if rg -n --quiet 'vm\.(startBroadcast|broadcast)|--broadcast|env(Uint|Bytes32)\([^)]*PRIVATE_KEY' "$test_path"; then
  machine_stop failed FORK_TEST_CONTAINS_BROADCAST_OR_SECRET_INPUT
fi

chain_id="$(rpc_retry cast chain-id --rpc-url "$rpc_url")" || machine_stop blocked BASE_MAINNET_RPC_UNAVAILABLE
[[ "$chain_id" == "8453" ]] || machine_stop failed NOT_BASE_MAINNET_RPC

finalized_json="$(rpc_retry cast block finalized --rpc-url "$rpc_url" --json)" \
  || machine_stop blocked BASE_MAINNET_FINALIZED_BLOCK_UNAVAILABLE
block_number_hex="$(jq -er '.number' <<<"$finalized_json")" \
  || machine_stop blocked BASE_MAINNET_FINALIZED_BLOCK_INVALID
block_hash="$(jq -er '.hash | ascii_downcase' <<<"$finalized_json")" \
  || machine_stop blocked BASE_MAINNET_FINALIZED_BLOCK_INVALID
block_number="$(cast to-dec "$block_number_hex")"
[[ "$block_hash" =~ ^0x[0-9a-f]{64}$ && "$block_number" =~ ^[1-9][0-9]*$ ]] \
  || machine_stop blocked BASE_MAINNET_FINALIZED_BLOCK_INVALID

actual_pool_manager_hash="$(rpc_retry cast codehash "$pool_manager" --block "$block_number" --rpc-url "$rpc_url")" \
  || machine_stop blocked BASE_MAINNET_ARCHIVE_STATE_UNAVAILABLE
actual_position_manager_hash="$(rpc_retry cast codehash "$position_manager" --block "$block_number" --rpc-url "$rpc_url")" \
  || machine_stop blocked BASE_MAINNET_ARCHIVE_STATE_UNAVAILABLE
actual_permit2_hash="$(rpc_retry cast codehash "$permit2" --block "$block_number" --rpc-url "$rpc_url")" \
  || machine_stop blocked BASE_MAINNET_ARCHIVE_STATE_UNAVAILABLE
actual_universal_router_hash="$(rpc_retry cast codehash "$universal_router" --block "$block_number" --rpc-url "$rpc_url")" \
  || machine_stop blocked BASE_MAINNET_ARCHIVE_STATE_UNAVAILABLE

[[ "$(normalize_address <<<"$actual_pool_manager_hash")" == "$pool_manager_hash" ]] \
  || machine_stop failed POOL_MANAGER_CODE_HASH_DRIFT
[[ "$(normalize_address <<<"$actual_position_manager_hash")" == "$position_manager_hash" ]] \
  || machine_stop failed POSITION_MANAGER_CODE_HASH_DRIFT
[[ "$(normalize_address <<<"$actual_permit2_hash")" == "$permit2_hash" ]] \
  || machine_stop failed PERMIT2_CODE_HASH_DRIFT
[[ "$(normalize_address <<<"$actual_universal_router_hash")" == "$universal_router_hash" ]] \
  || machine_stop failed UNIVERSAL_ROUTER_CODE_HASH_DRIFT

router_pool_manager="$(
  rpc_retry cast call "$universal_router" 'poolManager()(address)' --block "$block_number" --rpc-url "$rpc_url"
)" || machine_stop blocked BASE_MAINNET_BINDING_READ_UNAVAILABLE
router_position_manager="$(
  rpc_retry cast call "$universal_router" 'V4_POSITION_MANAGER()(address)' --block "$block_number" --rpc-url "$rpc_url"
)" || machine_stop blocked BASE_MAINNET_BINDING_READ_UNAVAILABLE
position_pool_manager="$(
  rpc_retry cast call "$position_manager" 'poolManager()(address)' --block "$block_number" --rpc-url "$rpc_url"
)" || machine_stop blocked BASE_MAINNET_BINDING_READ_UNAVAILABLE
position_permit2="$(
  rpc_retry cast call "$position_manager" 'permit2()(address)' --block "$block_number" --rpc-url "$rpc_url"
)" || machine_stop blocked BASE_MAINNET_BINDING_READ_UNAVAILABLE

[[ "$(normalize_address <<<"$router_pool_manager")" == "$pool_manager" ]] \
  || machine_stop failed UNIVERSAL_ROUTER_POOL_MANAGER_BINDING_DRIFT
[[ "$(normalize_address <<<"$router_position_manager")" == "$position_manager" ]] \
  || machine_stop failed UNIVERSAL_ROUTER_POSITION_MANAGER_BINDING_DRIFT
[[ "$(normalize_address <<<"$position_pool_manager")" == "$pool_manager" ]] \
  || machine_stop failed POSITION_MANAGER_POOL_MANAGER_BINDING_DRIFT
[[ "$(normalize_address <<<"$position_permit2")" == "$permit2" ]] \
  || machine_stop failed POSITION_MANAGER_PERMIT2_BINDING_DRIFT

echo "[base-mainnet-fork] finalized block $block_number; running read-only rehearsal" >&2
started="$(date +%s)"
test_passed=false
for attempt in 1 2 3; do
  if NO_COLOR=1 forge test \
    --fork-url "$rpc_url" \
    --fork-block-number "$block_number" \
    --match-path "$test_path" \
    -vv >"$test_log" 2>&1; then
    test_passed=true
    break
  fi
  if [[ "$attempt" -lt 3 ]]; then
    sleep "$attempt"
  fi
done
duration=$(($(date +%s) - started))
if [[ "$test_passed" != true ]]; then
  # Forge provider errors may echo a credential-bearing URL, so the temporary log
  # is deliberately not printed. It is deleted by the EXIT trap.
  machine_stop failed BASE_MAINNET_FORK_TEST_FAILED
fi

test_count="$(grep -Ec '^\[PASS\] test_baseMainnet' "$test_log" || true)"
for test_name in \
  test_baseMainnetOfficialBindingsAndCodeHashes \
  test_baseMainnetFreshWorldOfficialUniversalRouterDeployAndCall \
  test_baseMainnetUniversalRouterAdversarialRollback; do
  grep -Eq "^\[PASS\] ${test_name}\(\)" "$test_log" || machine_stop failed BASE_MAINNET_FORK_TEST_SET_INCOMPLETE
done
[[ "$test_count" -eq 3 ]] || machine_stop failed BASE_MAINNET_FORK_TEST_SET_INCOMPLETE

source_commit="$(git rev-parse HEAD)"
forge_version="$(forge --version | awk 'NR == 1 { sub(/^forge Version: /, ""); print; exit }')"
forge_commit="$(forge --version | awk -F': ' '$1 == "Commit SHA" { print $2; exit }')"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --arg generatedAt "$generated_at" \
  --arg sourceCommit "$source_commit" \
  --arg forgeVersion "$forge_version" \
  --arg forgeCommit "$forge_commit" \
  --argjson blockNumber "$block_number" \
  --arg blockHash "$block_hash" \
  --arg providerSource "$provider_source" \
  --arg testOutputSha256 "$(hash_file "$test_log")" \
  --argjson durationSeconds "$duration" \
  '{schemaVersion:"swaputer-base-mainnet-fork-rehearsal/1",generatedAt:$generatedAt,status:"verified",
    source:{commit:$sourceCommit,treeState:"clean"},
    toolchain:{forgeVersion:$forgeVersion,forgeCommit:$forgeCommit},
    fork:{network:"Base Mainnet",chainId:8453,blockTag:"finalized",blockNumber:$blockNumber,blockHash:$blockHash,
      providerSource:$providerSource,rpcCredentialsPersisted:false,upstreamTransactionsBroadcast:false,
      externalPrivateKeyLoaded:false,walletTxtUsed:false,deterministicTestKeyUsed:true},
    upstream:{
      poolManager:{address:"0x498581ff718922c3f8e6a244956af099b2652b2b",codeHash:"0x83b2af6e9f3158defc2811cbcb0db71ecf8b2ba2abea39c39e370ac5c6f43eb6"},
      positionManager:{address:"0x7c5f5a4bbd8fd63184577525326123b519429bdc",codeHash:"0x243f9e091ddf11c7c04e28059fdbbf1bab82b72d414fafb8e096c097aaeb622a"},
      permit2:{address:"0x000000000022d473030f116ddee9f6b43ac78ba3",codeHash:"0xa67739abc3ede9dbdc0491636c67d6a14ac07fab9030c3f509b1eb7b11dff8ed"},
      universalRouter:{address:"0xfdf682f51fe81aa4898f0ae2163d8a55c127fbc7",codeHash:"0x4436f45787722467059726381c27a999d0725a7a8b6ae2c4217223987275e3ef",version:"2.1.1"},
      bindings:{universalRouterPoolManager:true,universalRouterPositionManager:true,positionManagerPoolManager:true,positionManagerPermit2:true}},
    rehearsal:{testPath:"test/fork/SwapVMBaseMainnetFork.t.sol",testCount:3,testOutputSha256:$testOutputSha256,durationSeconds:$durationSeconds,
      freshCore:true,liquidityProvider:"fork-local-test-router",officialPositionManagerLiquidityUsed:false,officialPositionManagerBindingsVerified:true,
      directOfficialUniversalRouter:true,v4Command:"0x10",v4Actions:"0x060c0f",deployExecuted:true,callExecuted:true,stateVerified:true,
      economicsVerified:true,adversarialCases:["mutated-envelope","replay","wrong-router-binding","out-of-byte-gas"],
      noBroadcast:true,deterministicTestSigningOnly:true,mainnetReleaseConfigCreated:false}}' >"$draft_path"

node script/stage7m-assurance-evidence.mjs seal-fork "$draft_path" "$sealed_path" >/dev/null
node script/stage7m-assurance-evidence.mjs validate-fork "$sealed_path" >/dev/null

if [[ "$#" -eq 1 ]]; then
  output_path="$1"
  [[ ! -e "$output_path" ]] || { echo "refusing to overwrite existing evidence: $output_path" >&2; exit 1; }
  mkdir -p "$(dirname "$output_path")"
  cp "$sealed_path" "$output_path"
fi

jq -c . "$sealed_path"
