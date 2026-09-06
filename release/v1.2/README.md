# Swaputer v1.2 Stage 7M candidate freeze

This directory freezes the network-independent `swaputer-v1.2-stage7m-rc3`
candidate. It does not authorize a mainnet deployment. The launch scope is
defined by `candidate-scope.json`; Market, sETH and Auction remain testnet or
evidence-only applications and are excluded from official mainnet entrypoints.

The local `swaputer-v1.2-stage7m-rc1` tag at commit `8df6ac9` is rejected and
must not be moved or used for release. Its post-tag verifier correctly found
that the recorded metadata-bearing artifact hashes came from a stale Foundry
cache created before recursive submodule remapping discovery.

The local `swaputer-v1.2-stage7m-rc2` tag at commit `6801d06` is also rejected
and must not be moved or used for release. rc2 reconstructed recursive
submodules from exact Git objects, but Foundry's automatic remapping discovery
still drifted between build contexts, so a clean source build did not reproduce
the recorded bytecode. rc3 disables automatic remapping discovery and freezes
the complete remapping set in `foundry.toml`. The retired rc1 and rc2 tags remain
immutable historical records; neither may be retargeted to a replacement
candidate.

The freeze uses two commits so final evidence cannot make its own source
commitment drift:

1. Integrate and stage every file intended for candidate commit C. Run
   `python3 script/release_candidate.py generate`, then
   `./script/verify-release-candidate.sh`. Re-run both after any candidate file
   changes. `candidate.json` must not be part of C.
2. Commit C and create the annotated tag `swaputer-v1.2-stage7m-rc3` pointing to
   C. A lightweight tag is rejected.
3. Run `python3 script/release_candidate.py finalize --ref
   swaputer-v1.2-stage7m-rc3`. This verifies the tag tree and writes the stable
   post-tag `candidate.json` evidence.
4. Commit `candidate.json` and the independent Stage 7M assurance evidence in a
   later evidence commit E. Verify from E with
   `./script/verify-stage7m-rc3-evidence.sh`. The unified verifier checks the
   candidate record, all three evidence integrity hashes, clean-tree markers,
   and their shared binding to the tag's peeled candidate commit.

The ref verifier reads source commitments from the tag's peeled commit/tree. It
does not require the current HEAD to equal C. `candidate.json`, the self-hashing
source list and the three independent assurance evidence JSON files are
explicitly excluded from the candidate source set so E cannot change it.

Before creating C, compare the staged tree with the verified working tree. New
files that were not yet tracked when `generate` ran become part of the exact
source set once staged, so the generator must be run again after staging them.
