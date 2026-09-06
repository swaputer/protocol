# Stage 7C 外部审计不实施与风险接受记录

状态：`unaudited experimental`。

Stage 7C 没有完成。
No independent auditor or audit report exists.

项目方最初决定暂时延后 Stage 7C，并于 2026-09-06 进一步决定当前发布路线不委托
外部独立审计。这不是 Stage 7C 通过或完成：目前没有独立审计人员、委托记录或审计
报告。内部测试、Slither 分类、开发代理及 AI 检查都不是独立审计，也不能被宣传为审计。

唯一冻结审计候选仍为：

- tag：`swaputer-v1.1-stage7c-rc2`
- commit：`afa54c2e02e7e91430b14b6884faff5e3f5867d9`

rc2 不得移动或重写。S7B-002（公开 salt 抢占导致的可用性风险）仍是开放 Medium。

## 当前发布决策

- Stage 7C 状态为 `not pursued / incomplete`，旧审计候选仅作为历史审阅材料保留。
- 当前目标改为 `unaudited experimental` 的限额主网实验发布，永远不得称为 audited、
  secure 或 production-ready。
- 不做外审只移除外审这一项要求，不自动授权主网，也不豁免已知风险、内部安全、
  经济参数、权限托管和链上发布门禁；主动省略的运维与安全响应措施必须如实记录风险。
- 在 `docs/STAGE7M-UNAUDITED-MAINNET.md` 的剩余条件完成前，只允许 local 或明确授权的
  零真实价值 testnet；现有主网 fail-closed 策略继续生效。
- 测试 TOKEN 不具有承诺价值，不宣传价格、收益或投资属性。
- 任何 Stage 7M artifact 必须明确记录未审计状态、官方资金上限和不可暂停/升级风险。

如果未来恢复外部审计，必须针对当时的最新候选重新冻结 commit/tag、重建审计范围并
完整重跑安全门。此前或此后任何未审计部署的状态都不会被追溯改变。
