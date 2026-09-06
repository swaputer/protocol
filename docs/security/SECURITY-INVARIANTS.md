# Stage 7B 可执行安全性质

状态：内部 hardening 证据，不是独立审计。`E` 表示自动测试，`M` 表示发布时人工/链上
重建检查。

## World / Factory

| 性质 | 证据 |
|---|---|
| worldId 最多 sealed 一次；config 永不变化 | E: `SwapVMStage7BSecurity`, Factory/Router invariants |
| configHash 可从全部状态精确重建 | E: Factory `_worldConfigHash` stateful invariant；TS golden vector |
| Manager 地址/EXTCODEHASH immutable，Factory 不部署/替换 Manager | E + M: bytecode/manifest observation |
| Token/P/K/H/Deployer 不可替换、权限位精确 | E: heterogeneous multi-world state machine varies holder/supply/price/fee/tick/byte price and checks bindings |
| 每个 Hook 只能永久绑定其指定的唯一 ETH/TOKEN PoolKey | E: `beforeInitialize` 在首次初始化持久化 `boundPoolId`；拒绝其他 token、fee、tick spacing、Hook、非原生 ETH 组合及任何二次绑定 |
| 任意 pre-seal 失败没有部分部署/config | E: salt、prediction、permission、Hook failure、existing target stateful tests |
| Deployer onlyFactory + one-shot；预测地址等于实际 | E: 7A1-P、7A2、7B |
| creation-code store payload/hash 精确 | E: Factory constructor、size/hash gate；M: manifest observation |

Pool 已初始化、worldId collision 和 initialize failure 在唯一新 Token/PoolKey 模型下分别由
PoolManager初始化状态、`WorldAlreadyExists` 及整个 `createWorld` 原子回滚处理。真实生产
PoolManager不向 Factory/Hook提供初始化重入入口；独立审计仍需复核该外部调用图。

## Router / PoolManager

| 性质 | 证据 |
|---|---|
| callback 仅 Manager、必须 active、data hash 必须完全相等 | E: direct callback、malicious recipient、Router code |
| 同交易/跨 World 重入不能覆盖 commitment | E: ETH recipient buy/sell/callback recursion |
| 每次 unlock 所有 transient delta 为零 | E: 每个单元测试 + stateful invariant |
| 每次调用只消费 payer 的 ETH/TOKEN预算 | E: multi-actor state machine |
| 历史强制 ETH 不退款；误转 TOKEN 不替 payer 卖出 | E: forced/accidental-balance tests + invariant |
| NOP 空 hookData；VM 只有原始 envelope；CALL 空 payload 合法 | E: Stage 2/7A2/7B |
| sell 空 hookData、零 VM/burn/log；exact-output buy无入口 | E + ABI人工检查 |
| 滑点/recipient revert 完整回滚 | E: min-output、malicious recipient、economic boundary |

## Kernel / VM

| 性质 | 证据 |
|---|---|
| 成功 buy 一条 Kernel Events；sell/revert 零条 | E: Stage 1–6E |
| height/nonce 仅成功提交 | E: Stage 2、7B replay、stateful invariant |
| supply 仅按 `executedBytes × byteGasPrice` 减少 | E: stateful asset-conservation invariant |
| net = gross - burn；burn ≤ maximum exposure | E: Stage 1/2、7B exact-boundary vectors |
| 失败不提交 storage/deploy/event/nonce/height/burn | E: Stage 2/6D3/7B |
| World storage/nonce/contractId/deployment隔离 | E: Stage 2–5 + 7B multi-world |
| simulator 与 Solidity逐字段一致 | E: 6D3 corpus + `security-regressions.json` threat index |

人工发布检查还包括：确认生产 PoolManager runtime hash、重建 final manifest、核对 compiler /
reference/tree/artifact commitments、复核 Slither triage，并由独立审计方重新运行全部入口。
