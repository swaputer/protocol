# Explicit exclusions

- `wallet.txt` and any wallet, mnemonic, private key, keystore, PEM/P12/PFX or local signing material
- `.env` and environment-specific configuration
- `broadcast/`, public RPC access, network deployment records and signed transaction output
- `cache/`, `out/`, `node_modules/`, `dist/`, `.security-tools/`
- SQLite runtime databases and WAL/SHM files
- `.git/` object/database metadata
- submodule working-tree contents from the top-level SHA-256 list; their exact gitlinks remain in scope
- frontend/UI, hosting, monitoring, key custody and production infrastructure
- final chain-specific economic parameter selection and deployment operations

Excluded services may affect availability or presentation but must not become chain-consensus or fund-safety
authorities. No excluded local file may be placed in an audit archive.
