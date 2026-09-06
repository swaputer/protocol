# Reproduce the audit candidate

Requirements and exact versions are recorded in `toolchain.json`. No public RPC is required or permitted.

```sh
git checkout swaputer-v1.1-stage7c-rc2
git submodule update --init
npm ci --prefix tooling/receipt-codec
npm ci --prefix tooling/indexer
npm ci --prefix tooling/tinysol
npm ci --prefix tooling/deployment-manifest
python3 -m venv .security-tools/slither
.security-tools/slither/bin/pip install -r requirements-security.txt
./script/verify-audit-snapshot.sh swaputer-v1.1-stage7c-rc2
./script/accept-stage7b.sh
```

The verifier checks the tag's exact file set and hashes, gitlinks, frozen manifests, production bytecode,
size gates and forbidden archive names. The acceptance command runs all Stage 7A2/7B checks, local Anvil E2E,
fuzz/invariants, npm audits, Slither triage and gas snapshot. Local databases, build output, broadcast output,
environment files and signing material are excluded and must not be copied into the review bundle.

If any value differs, fail closed. Do not update a dependency, regenerate a package or edit the rc2 tag to
make the check pass; create a new review candidate.
