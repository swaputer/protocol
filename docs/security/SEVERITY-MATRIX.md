# Security severity matrix

Severity is based on demonstrated impact, exploitability, affected value and required privileges.

| Severity | Examples |
|---|---|
| Critical | Unauthorized unlimited TOKEN mint; direct theft of arbitrary user/PoolManager funds; VM escape enabling arbitrary EVM execution or cross-World writes; systemic settlement delta leakage; signature/replay failure allowing arbitrary actors to spend or mutate state. |
| High | Repeatable material wrong burn or gross/net accounting that causes user loss; persistent cross-World state pollution; bypass of byteGasLimit/max exposure; Factory/Hook binding substitution; permanent inability for ordinary holders to sell caused by protocol code. |
| Medium | Bounded loss or griefing; S7B-002 salt抢占/liveness; reliable execution-height or canonical index corruption with operational impact; ABI/codeHash trust misclassification without direct fund loss; costly resource amplification within limits. |
| Low | Limited observability, non-exploitable validation drift, minor gas or availability issue, misleading error without unsafe continuation. |

Indexer/UI-only failures do not become fund-critical unless they cause signing, deployment or trust
decisions that violate the onchain safety boundary. Severity may be reduced when exploitation
requires a victim to ignore an explicit fail-closed warning.
