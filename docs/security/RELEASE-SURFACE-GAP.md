# Stage 7A2 release-surface gap report

## 1. Required components and status（Section 26）

| Component | Status | 解释 |
|---|---|---|
| `SwaputerHook` | `release-candidate complete / unaudited` | V1.1 运行时语义稳定（v1 freeze），但未经过独立生产审计，不宣称 production-complete。 |
| `SwaputerKernel` | `release-candidate complete / unaudited` | 同上；核心共识与索引语义在 Stage 6E 中对齐并复现。 |
| `SwapVMMiniVM` | `release-candidate complete / unaudited` | 解释器在本地 simulator 与 Solidity 执行上已做严格差分验证，但仍不是生产可审计完成状态。 |
| `SwaputerToken` | `release-candidate complete / unaudited` | 18 decimals、固定供应、burn 会减少 `totalSupply`、仅销毁能力。 |
| `SwaputerProgramRegistry` | `release-candidate complete / unaudited` | 固定四个参考 program hash（SRC-20、SRC-721、SRC-1155、CPAMM）是刻意的不可变安全边界。 |
| `WorldFactory` | `release-candidate complete / unaudited` | `SwaputerWorldFactory` + one-shot `SwaputerWorldDeployer` 已实现；仍需 7B/7C。 |
| `MiniVMInterpreter` | `integrated into another component` | 解释器语义在 `SwaputerKernel / SwapVMMiniVM` 中内化。 |
| `MiniVMCodeStore` | `integrated into another component` | 通过 `SwaputerKernel` 的不可变映射与内存账本持有 codeHash，不独立部署。 |
| `StandardProgramRegistry` | `integrated into another component` | 不存在可变治理 registry；四项固定 `SwaputerProgramRegistry` 就是冻结边界。 |
| `ReferencePrograms` | `release-candidate complete / unaudited` | 固定离线 package + immutable exact codeHash registry；无管理员发布路径。 |
| `SwaputerAppRouter` | `release-candidate complete / unaudited` | 最小 exact-input Router 已位于 `src/`，无通用 swap/hookData/admin/custody 入口。 |
| `TinySol toolchain` | `integrated into another component` | 已有 `tooling/tinysol`，在 Stage 7A1-R 阶段仅做设计审查和部署边界对齐，不新增编译器功能。 |
| `VM event indexer` | `requires operational implementation` | `tooling/indexer` 支持重组扫描和事件解码，但未进入生产运维编排与 HA。 |

## 2. Stage 6E 组件为何仅为测试路径

- `Stage6ERouter`、`Stage6EFailureExecutor`、`Stage6BE2E.s.sol`、`Stage6D2E2E.s.sol`、`tooling/stage6e/stage6e-e2e.mjs` 为“验收工具”：
  - 只用于本地/CI 重放；
  - 不能包含升级入口、管理员、抽象提现、资产托管或可变策略；
  - 不应被上链部署或纳入生产发布边界。
- 这类工具在 Stage 7A2 中可能继续用于对照，但不会进入生产合约集合。

## 3. PoolManager 与 Factory 模型

- **`SwaputerWorldFactory` 不会部署 PoolManager。**
- Factory 仅绑定既有 PoolManager（或在构造时通过 codeHash 验证已确认地址）：
  - `poolManager` 地址与其 `codeHash` 记录在不可变配置；
  - worldId **不包含** PoolManager 地址，严格等于 `PoolId.unwrap(poolKey.toId())`；
  - `poolManager` 身份通过 Factory immutable 与 manifest/证据链独立承诺。
- 这意味着 PoolManager 的可靠性链上基础来自部署方与生态，而不是 Factory 可更改参数。

## 4. 工厂绑定模型：A/B 评估与采纳结论

Stage 7A1-R 明确采用以下之一，并给出最小攻击面解释：

### A. 每个支持的 PoolManager 一个 immutable Factory（推荐用于 7A2）
- 每个 Factory 绑定一个固定 PoolManager 与其 `codeHash`；
- 部署时不接受外部传入可更换 Manager；
- 代码路径最短、构造时状态固定、无需额外治理参数。

### B. 单 Factory 接受 PoolManager 参数并验证 codeHash
- 引入额外参数解析分支与部署前校验复杂度；
- 一旦部署脚本/参数错误，会形成更高的误操作面；
- 可见“支持更多 Manager”带来更大的配置攻击面。

**Stage 7A1-R 采用 A。**  
理由：最小化签名/校验分支、避免可替换绑定路径，符合“冻结边界优先”的协议风格。

## 5. Hook/Kernel 地址循环与已证明解法（不改构造语义）

- 不修改现有 Hook/Kernel 构造函数语义：
  - `SwaputerKernel(address hook, uint128 price)`
  - `SwaputerHook(IPoolManager manager, SwaputerKernel boundKernel, ..., uint128 price, ...)`，并内部要求 `boundKernel.hook() == address(this)`。
- 两个合约若都由 Factory 直接 CREATE2，存在真实固定点循环：
  - `K = CREATE2(factory, saltK, hash(KernelCreationCode || H || price))`；
  - `H = CREATE2(factory, saltH, hash(HookCreationCode || manager || K || token || ...))`。
- 调整离线计算顺序不能消除循环。Stage 7A1-P 使用 test-only Foundry proof 验证了这一点。
- 已证明的解法是：Factory 以 CREATE2 部署固定 init code 的一次性 per-world deployer P；K 是 P 的 nonce-1 普通 CREATE 子地址；H 再由 P 以 CREATE2 部署。Hook salt mining 使用 P（不是 Factory 或 Foundry deployer）作为 deployer。
- P 具有 immutable Factory、`onlyFactory`、one-shot guard，且无任意部署、提币或升级入口。
- 错误预测、错误 salt、已有代码、重复调用和绑定不一致都会失败；单事务创建时 P/K/H 与 Factory 状态原子回滚。
- 完整公式、部署顺序和测试证据见 `docs/security/WORLD-FACTORY-DESIGN.md` 与 `docs/STAGE7A1P.md`。

## 6. Sealing 与 `SwaputerProgramRegistry` 的边界定位

- `SwaputerProgramRegistry` 的四个 hard-coded hash 不是缺陷，而是“不可变安全边界”：
  - 不支持运行时管理员替换；
  - 不支持 mutable governance update；
  - 不提供 rate-limit / pause / upgrade / owner；
  - 这些缺失是冻结设计要求，不视为缺陷。
- 生产级可扩展应通过“manifest 声明 + offchain 签名与复核”而非可变链上 registry 覆盖。

## 7. Stage 7A2 已落地的生产边界项

- `SwaputerWorldFactory`、`SwaputerWorldDeployer` 与不可变 creation-code stores；
- `SwaputerAppRouter`（无管理员、无代理、最小无状态）；
- WorldConfig 一次写入、PoolManager pool 初始化与 sealed discovery；
- RPC-free canonical manifest finalize/hash/signature/observation validation；
- 真实 v4 exact-input NOP、签名 DEPLOY/CALL 与 sell 回归。

剩余工作属于 Stage 7B 内部 hardening、7C 外部独立审计与 7D 受限发布，
不能把本阶段实现称为已审计的 production-complete。

## 8. 不能视为生产缺陷的项目

- “缺少 rate limit / pause / upgrade / admin”；
- “不允许生产立即 hot-fix”；
- “indexer/offchain 中断即影响链上资金安全”。

These are deliberate protocol properties under v1.1 frozen assumptions.
