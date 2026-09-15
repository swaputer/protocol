# Stage 7A2 独立审计边界（实现候选版）

本文定义 Stage 7A2 完成后必须交给外部独立审计方的准确范围。当前代码仍是
`release-candidate complete / unaudited`，本文不是审计结论。

## 1. Stage 7A1-R 审计范围

### 1.1 已有生产协商一致组件（当前实现状态）

- `src/SwaputerHook.sol`
- `src/SwaputerKernel.sol`
- `src/SwapVMMiniVM.sol`
- `src/SwaputerToken.sol`
- `src/SwaputerProgramRegistry.sol`

其中：

- 这些组件在 Stage 6 已完成功能级验证（包括 6A/6B/6C/6D/6E 证据链）；
- 当前仅记为 `release-candidate complete / unaudited`，未扩展为“无条件生产可发布”。

### 1.2 关键设计文档（本阶段新增/修订）

- `docs/STAGE7-PLAN.md`
- `docs/security/RELEASE-SURFACE-GAP.md`
- `docs/security/THREAT-MODEL.md`
- `docs/security/DEPLOYMENT-MANIFEST.md`
- `docs/security/ROUTER-INTERFACE.md`（新增）
- `docs/security/WORLD-FACTORY-DESIGN.md`（新增）

### 1.3 工具链与证据系统（与生产语义紧耦合）

- `tooling/receipt-codec`（仅用于 strict VM receipt 验证）
- `tooling/indexer`（重组扫描、raw/derived 双层）
- `tooling/abi-registry`（若已存在于仓库）
- `tooling/tinysol`（`compiler/simulator/manifest` 与生产字节码一致性）
- `docs/security/DEPLOYMENT-MANIFEST.md` 的二层 Manifest 验证规则

## 2. Stage 7A2 新增生产源码范围

- `src/SwaputerCreationCodeStore.sol`
- `src/SwaputerWorldDeployer.sol`
- `src/SwaputerWorldFactory.sol`
- `src/SwaputerAppRouter.sol`
- `src/interfaces/ISwaputerWorldFactory.sol`
- `script/Stage7A2Deploy.s.sol`
- `tooling/deployment-manifest/**`（锁文件、schema、canonicalization、hash/signature/observation verifier）
- `test/SwapVMStage7A1P.t.sol`、`test/WorldDeployerProbe.sol`、`test/SwapVMStage7A2.t.sol`

## 3. 不在本次 Stage 7A1-R 审计内

- `script/Stage6EE2E.s.sol`、`tooling/stage6e/*`、`Stage6ERouter`、`Stage6EFailureExecutor` 等测试/验收脚本；
- Stage6 以外的 UI、钱包、交易所中间件；
- 公开网络部署、钱包运营、SRE 运行手册的运营执行细节；
- 任何主网密钥管理与组织治理流程本身（应作为部署运营附录）。

## 4. 版本、依赖与固定哈希（必须固定）

- Solidity: `0.8.26`
- Foundry / Node 工具链版本按项目依赖锁记录；
- `v4-core` 与 `v4-periphery` 以 Stage 6 冻结提交为准；
- `docs/spec/SwapVM-v1.1-frozen-spec.md`、`docs/spec/SwapVM-ISA-v1.json` 的 manifest hash 校验；
- v1.0 历史清单仅保留兼容检查。

## 5. 测试入口（本阶段）

- `forge fmt --check`
- `forge test -vvv`（含 Stage6 全量）
- `forge snapshot --check`
- `npm run build / typecheck / test`（receipt-codec 与 tinysol）
- 现有 Stage 6 证据链脚本（不要求更改其代码）；
- `stage7e` 之前的重组/索引/验证 smoke 测试（设计文件一致）。

## 6. 审计边界说明（给 Stage 7A2 使用）

真正的生产审计应包含：

- 共识一致性：Hook/Kernel/PoolManager 回执路径；
- 费用和回滚一致性：成功/失败、无 partial commit；
- 签名、nonce、deadline、`actor` 一致性；
- 资产安全：POOL 池子可售性、GasToken totalSupply 减少、sell 无 burn；
- 现成部署信任边界：Manifest 与链上重建一致；
- 索引器/ABI 与 `raw receipt` 不可篡改链上语义。

## 7. 结论

- Stage 7A2 已形成可冻结 commit/artifact 后交付的完整审计范围；
- 先执行 Stage 7B 内部 hardening，再冻结独立审计 commit/hash；
- 只有 Stage 7C 外部审计与修复闭环后才可评估 production-complete。

## 8. Stage 7B 增量审计材料

独立审计 commit 还必须包含 `test/SwapVMStage7B*.t.sol`、
`test/invariant/SwapVMStage7B*Invariant.t.sol`、`script/accept-stage7b.sh`、
`requirements-security.txt`、`security-results/**`、deployment-manifest strict parser与新增观察字段、
以及 `docs/security/{SECURITY-INVARIANTS,STAGE7B-FINDINGS,ECONOMIC-MEV-ANALYSIS,DEPLOYMENT-FAILURE-RUNBOOK}.md`。
Slither triage和本开发代理的检查只是审计输入，不是独立审计结论。S7B-002 salt liveness、
PoolManager custom accounting、Router callback commitment、Factory外部调用原子性及Kernel
EIP-170低余量应列为外部审计重点。

## 9. Stage 7C0 冻结状态

状态仅为 `Stage 7C audit candidate frozen / awaiting independent audit`。精确文件范围、排除项、
子模块gitlink、工具链、production artifacts、known findings与source SHA-256清单位于`audit/`。
当前可交付候选为`swaputer-v1.1-stage7c-rc2`；rc1因tag后验证发现继承的`.gitattributes`未被
source allowlist分类而保留但废止。候选tag不可移动；任何修复必须生成新commit并全量重跑
Stage 7B，再由独立审计方复核并创建rc3或更高tag。当前候选不得描述为audited、secure、
production ready或deployment approved。

## 10. 2026-09-06 当前发布决策

项目方决定当前发布路线不委托外部独立审计。上述 v1.1 审计范围和冻结候选继续作为历史、
可复现的审阅材料保存，但不再是当前 Stage 7M 的计划门禁，也不覆盖当前 v1.2 实现。Stage 7C
仍未完成，任何内部或 AI 检查都不得称为审计。当前目标、剩余门禁和未审计声明以
`docs/STAGE7M-UNAUDITED-MAINNET.md` 为准；该决策本身不授权主网部署。
