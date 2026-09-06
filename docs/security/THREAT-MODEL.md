# Stage 7A2 threat model（v1.1 协议边界）

## Scope and assumptions

This model is for Stage 7A1-R (文档修订版)，聚焦在冻结语义不变的前提下，
评估生产部署前的威胁边界。  
共识与协议层面仍严格遵循 `docs/spec/SwapVM-v1.1-frozen-spec.md`、`docs/spec/SwapVM-ISA-v1.json`，本阶段不修改它们。

不评估的范围：

- v4 PoolManager 本身的基础协议漏洞；
- 公共链状态机共识漏洞；
- 纯 UI 表现层和钱包供应商实现（不含签名策略层）；
- 部署网络/节点可用性。

## 1. 普通交易者

- **前置条件**：提交 ETH→TOKEN or TOKEN→ETH 交易，通常带有 VM 指令（可选）。
- **攻击路径**：错误的 `byteGasLimit`、`deadline` 过紧、UI 误报导致低于预期滑点成交。
- **影响**：用户最终 TOKEN 与预期偏差、签名后体验失败。
- **当前防线**：
  - Hook 强制只允许 ETH→TOKEN exact-input（卖出无 VM）；
  - `grossTokenOut` 和 `byteGasLimit` 约束检查；
  - `minNetTokenOut` 与 `signed exactEthAmountIn` 在签名校验中绑定；
  - Canonical Router 将 `msg.value` 作为唯一 exact input，并由 Kernel 将实际 Hook receipt 绑定进签名。
- **建议测试**：边界 fuzz（`exactEthAmountIn`、`minNetTokenOut`、`grossTokenOut` 小额边界）；签名失配与过期测试。
- **是否阻止部署**：否（风险在用户 UX/工具提示，非共识安全缺陷）。

## 2. 恶意 mini-program 开发者

- **前置条件**：已签名 payload 能在 sealed world 中执行 NOP/CALL/DEPLOY。
- **攻击路径**：构造高成本循环、深层调用、`OutOfByteGas`、存储膨胀、event-shaped 误导。
- **影响**：
  - 对钱包/索引系统的“误分类”风险；
  - 运行时 DoS 级别压力（按交易方签名范围触发）。
- **当前防线**：
  - 费用为前置资源约束：`executedBytes * byteGasPrice`；
  - MiniVM/Journal + 回滚模型保证失败无提交；
  - 记录模型要求 `(worldId, emitter, codeHash)` 精确绑定，`Transfer-shaped` 必须 declared_unverified 除非 exact reference 验证通过；
  - 深度、内存、记录数上限按冻结 ceilings。
- **剩余风险**：经济层面可利用高 gas 预算发起“高成本失败”交易。
- **建议测试**：transfer-shaped 与普通事件对抗 fixture、最小/最大边界 `byteLimit`、嵌套失败回滚。
- **是否阻止部署**：否，但要求钱包/监控清晰标记 unverified。

## 3. 恶意 TinySol source / package 发布者

- **前置条件**：攻击者可影响 TinySol 编译输入链路（离线编译服务或 artifact 来源）。
- **攻击路径**：操控 package hash / ABI hash，制造估算与执行不一致。
- **影响**：用户在提交前的估算不可信，可能出现 revert 或 unexpected burn。
- **当前防线**：
  - 6D1/6D2/6D3 与参考包构建过程已记录固定来源与 hash；
  - 生产语义由 Kernel 共识决定，索引/估算仅作辅助。
- **建议测试**：离线 artifact 重放与 source-map 一致性对照、最小 seed 的 determinism 测试。
- **是否阻止部署**：否（但 tooling 必须纳入独立变更审查）。

## 4. 恶意流动性提供者

- **前置条件**：可任意变更 ETH/TOKEN 池流动性与价差。
- **攻击路径**：短时池深度变化导致 gross output 或 `OutOfByteGas` 风险。
- **影响**：买入净额低于预期、maxExposure 估算失配。
- **当前防线**：
  - PoolManager swap 路径保留 LP 风险；  
  - Canonical Router 同时执行普通 output minimum 与 Kernel `minNetTokenOut`。
- **建议测试**：主网分叉下 LP 攻击 + 前向交易排序 fuzz。
- **是否阻止部署**：否（由参数与交易时风控缓解）。

## 5. MEV builder / searcher

- **前置条件**：可观察 mempool 并重排交易。
- **攻击路径**：夹击买入，抢跑改变手续费、滑点或使交易 revert。
- **影响**：用户失败率上升、净输出下降。
- **当前防线**：无新治理；通过签名前预估、`minNetTokenOut` 与 `byteGasLimit` 控制用户可验风险。
- **建议测试**：并发替换和同块重排模拟、失败/重试率跟踪。
- **是否阻止部署**：否。

## 6. 被攻击或落后 indexer

- **前置条件**：reorg 频率升高、RPC 回退、索引扫描延迟。
- **攻击路径**：重复扫描、遗漏 Events、派生事件重复或丢失。
- **影响**：`vm_records` 与 `raw receipt` 展示不一致。
- **当前防线**：
  - 6B 设计以 block-hash 级别重扫与 orphan 保留为基础；
  - raw payload 永不覆写。
- **剩余风险**：服务连续性影响，但不影响链上资金安全。
- **建议测试**：停机重启幂等、snapshot/revert reorg 再扫描收敛。
- **是否阻止部署**：否（SRE 与可用性边界）。

## 7. 恶意 ABI descriptor 发布者

- **前置条件**：提交不实 ABI descriptor。
- **攻击路径**：伪造 topic/abi，误导客户端“verified”显示。
- **影响**：非资金损失型解释偏差，可能造成风控误判。
- **当前防线**：
  - `verified_reference` 仅在 `codeHash + interfaceId + abiHash` 全匹配时成立；
  - unverified 必须保留 raw 记录且不得被覆盖。
- **建议测试**：descriptor 冲突、重复声明、错误 interfaceId 回归。
- **是否阻止部署**：否。

## 8. 泄露的部署密钥

- **前置条件**：部署私钥泄漏。
- **攻击路径**：伪造/重复部署、错误参数签名、不可见的 PoolManager 绑定。
- **影响**：发布错误 world 或恶意配置世界（经济参数、引用哈希、签字者）。
- **当前防线**：
  - `manifest` 与链上重建必须独立校验；
  - 生产阶段建议 offline signer 与双人确认（不变更协议语义）。
- **建议测试**：离线密钥泄漏演练、脚本校验失败注入。
- **是否阻止部署**：可能阻止（若无法建立可审计部署流程）。

## 9. 错误配置运营者

- **前置条件**：部署参数错误（poolManager、codeHash、fee、tickSpacing、池 key 不匹配）。
- **攻击路径**：遗漏 sealing、未初始化世界、worldId 与真实池不一致。
- **影响**：swap 失败、资金卡死或回滚面扩大。
- **当前防线**：
  - 7A1-R 将 sealing 与 world 绑定定义为必须条件；
  - Hook/Kernel 对世界参数做严格 `worldId` 与世界配置检查。
- **建议测试**：部署参数突变矩阵 + 自动 precheck checklist。
- **是否阻止部署**：是（直到 world 配置-签名流程稳定）。

### 9.1 Permissionless world creation salt抢占

- **前置条件**：攻击者观察到待确认的 `createWorld` 交易及公开
  `bootstrapSalt`。
- **攻击路径**：使用同一个 Factory/bootstrap salt 先创建 P。完整复制原
  参数只会提前创建同一个预期 World；使用另一组有效 World 参数则会消耗
  P 地址并使原交易因 collision 失败。
- **影响**：发布交易的可用性/排序风险，不会把初始供应转给攻击者，也不
  能修改已 sealed World；运营方需选择新 salt、重新预测 K/H 并发布新交易。
- **当前防线**：所有地址与 initial holder/config 均由 Factory 重算并原子
  封存；碰撞绝不静默换 salt；失败没有部分状态。
- **剩余风险/7B 测试**：私有交易通道、commitment 策略与公开 mempool
  恢复演练需要在 Stage 7B 比较。本阶段不为解决 liveness 增加 owner 或
  allowlist。
- **是否阻止部署**：不阻止 7A2 代码候选，但阻止在没有发布运行手册与
  failure-injection 演练时直接公开部署。

## 10. 依赖与供应链攻击者

- **前置条件**：篡改 v4 依赖、npm 锁文件、manifest/编译器 artifact。
- **影响**：执行结果偏差、解析漂移、签名验证失败。
- **当前防线**：
  - 依赖版本/Commit 已锁；
  - manifest 哈希检查；
  - 两层验证（源码 + 部署码）可回归重建。
- **建议测试**：`npm audit`、`forge test`、离线重建 manifest + hash。
- **是否阻止部署**：是（直到供应链与哈希链路修复）。

## 11. 资产级威胁映射

| 资产 | 完整性风险 | 当前缓解 | 主要残余风险 |
|---|---|---|---|
| PoolManager settlement | 回滚/部分结算 | `unlock -> swap -> take/settle` 原子模型 | 调用方错误配置会导致交易失败 |
| GasToken supply/burn | 供应量少于应减小 | 仅 Hook 通过 pool take + kernel 算法触发 burn；burn 直接减小 totalSupply | 高 byte 预算交易导致更大 burn |
| user gross/net output | 不一致显示 | `gross` 与 `minNet` 在 Hook/Kernel 联合校验 | 市场波动与 LP 风险仍可影响 gross |
| byteGasLimit/exposure | 超限暴露 | `byteGasLimit * byteGasPrice` 先验上限，签名前估算 | 仍依赖正确上下文快照 |
| VM storage 隔离 | 跨 world 读取越权 | `storage key` 通过 `worldId` 命名空间 | 设计正确性依赖解释器实现冻结 |
| actor/nonce/replay | 签名重复执行 | v1.1 explicit `actor` + low-s + deadline + nonce | 交易广播层面需防止签名重放 |
| reference hash/codeHash | 冒充 reference | immutable reference registry + canonical codeHash 验证 | 仅限四个 canonical program 风险 |
| single Events integrity | 伪造日志 | Hook 每次成功仅 emit 一条 `(worldId, executionHeight, payload)` | 日志筛选器 bug 风险需在 indexer 规避 |
| sell safety | VM 误执行 | Hook zeroForOne 分支必须空数据并回零 | 依赖 `PoolKey` 一致性 |

## 12. 经济/MEV 设计注意（非实现改动）

- `byteGasPrice` 过高可能拒绝小额买入；过低可能鼓励异常调用放大。
- `maxByteGasLimit` 是边界防火墙，必须在 Factory/manifest 中明确承诺。
- 循环/重入失败只在同 tx 内承诺级别生效；失败必须全量回滚（no partial storage/deployment/log）。
- 首次可交易前必须满足流动性、sealed、签名字段合法。

## 13. Stage 7B 验证更新

内部对抗测试证明，在确定性本地真实v4路径中，夹击/排序只能使victim满足其minimum后成功，
或完整revert；没有成功交易越过maximum exposure。多actor状态机证明强制ETH、误转TOKEN、
recipient重入、滑点失败和direct callback不破坏资产/delta守恒。Manifest威胁模型新增duplicate
semantic key、high-s、错误block/tx/reorg observation和source/artifact/compiler/reference drift。
这些结果降低实现风险但不消除恶意LP、builder、候选链gas市场或运营密钥风险；Stage 7C/7D
仍为公开部署阻塞项。
