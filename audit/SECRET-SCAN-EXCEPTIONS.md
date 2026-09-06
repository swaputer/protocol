# Secret-scan exact exceptions

The scanner suppresses only these exact `(rule, path)` pairs. It never prints matched content.

- `assigned-secret` — `test/invariant/SwapVMStage4Invariant.t.sol`: deterministic Foundry-only signing key
  used solely by the local invariant fixture; it is not a deployment or funded-network credential.
- `credentialed-url` — `tooling/indexer/test/cli.test.ts`: deliberately credential-shaped URL used to test CLI
  input handling; it is static test data and does not identify a service account.
- `assigned-secret` — `tooling/tinysol/src/errors.ts`: stable diagnostic/error vocabulary matched by the
  contextual keyword rule; it contains no credential value.

Any new match, even under the same directories, fails closed and requires a separate documented exact exception.
