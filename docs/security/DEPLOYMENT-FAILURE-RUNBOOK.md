# 无管理员的发布失败恢复手册

本手册采用 S7B-002 的 `salt-recovery` 风险接受策略。恢复过程不依赖 owner、allowlist、pause、
sweep、可变 salt 映射或私有/保护提交渠道。

## 影响边界

公开 mempool 中完整复制 `createWorld` 只能提前创建相同不可变配置；抢占者支付自己的gas，
initialSupply仍发送到参数内的initialHolder。不同配置使用相同 token/bootstrap salt 会令原交易
collision/revert，但不能修改已 sealed World。专项测试证明复制者不能改写声明的供应接收者，且失败
调用不会留下候选 World 的部分配置；这不等于“资金影响必然为零”。发布者仍可能损失失败交易 gas、
延迟正式发布并作废旧草案，未获背书的不可变 World 也可能长期存在。

## 首先分类

1. **完全复制（exact-copy）**：链上已存在与草案参数逐字节一致的完整 sealed World。不要期待候选
   地址没有 code/config；停止继续发送原交易，核对 receipt、完整配置、供应归属、P/K/H、Pool 和
   codehash。即使状态完全一致，保守发布策略仍是将旧草案标记为无效并以新 salt 恢复；只有另行
   授权的发布流程才可背书该现存 World。
2. **bootstrap salt 碰撞**：同一 Factory 下预测的 WorldDeployer（P）已有 code，Factory 应以
   `WorldDeployerCollision(address)`（selector `0x69a0b302`）回滚。P/K 可能属于抢占者已经完成的
   World，因此不能要求它们为空；本次候选 Token、Hook、WorldConfig 与 Pool 初始化必须不存在。
3. **token salt 碰撞**：同一 Gas Token init code 与 token salt 的地址已有 code，CREATE2 以空
   revert data 回滚。既有 Token 的全部供应仍属于参数声明的 `initialHolder`；本次候选 P/K/H、
   WorldConfig 与 Pool 初始化必须不存在。

## 恢复步骤

1. 停止发布旧 manifest 草案并标记 `invalidated: salt collision/reorg`（不要重签）。
2. 依据上面的决策树确认 canonical receipt、Factory 状态和预期错误；只对相应分支验证应为空的
   code/config/Pool，避免把抢占者已经完成的 P/K 或完全复制的 World 误判成部分状态。
3. bootstrap 碰撞至少更换 `bootstrapSalt`；token 碰撞至少更换 `tokenSalt`；完全复制的保守恢复
   同时使用新的发布 salt。重新计算 Token、P、nonce-1 K、Hook 和 worldId，不能复用旧草案地址。
4. 以新 P 为 deployer 重新搜索满足精确 permission bits 的 Hook salt/H。
5. 离线复核 initialHolder、distribution commitment、price/fee/gas参数和creation store hashes。
6. 重新计算 configHash 和 manifest 草案 hash；确认新草案 hash 与已作废草案不同，再提交新交易。
7. 确认后从新World的receipt/state重建manifest；旧草案hash绝不能出现在新manifest。
8. 独立验证者检查blockHash/txHash、configHash、worldId、P/K/H、store payload和所有codehash。

若发生reorg，按同样流程以canonical block/receipt重建；publisher签名不能替代链上观察。不得为
恢复添加owner、allowlist、pause、sweep或可变salt映射。

## 独立接受门禁

在候选源码为干净 Git worktree 时运行：

```sh
./script/accept-s7b002.sh
```

门禁运行严格 JSON 负向测试和三个专项 Foundry 场景，并记录本次 Foundry JSON 输出的 SHA-256、生成
`security-results/stage7m-s7b002.json`。证据绑定当前 commit 及本门禁范围内文件的 SHA-256；未知字段、
重复 JSON member、篡改、场景缺失、错误 selector、虚构 receipt/mainnet 声明和超过 900 秒的模拟运行
都会失败。开发中的脏工作区只能显式使用 `--allow-dirty`，其证据会标记
`formalCandidateEligible: false`，不能作为正式候选证据。

该门禁只证明进程内 Foundry EVM 中的调用、日志和状态断言，不广播交易，不观察顶层 receipt、公开
mempool 排序或真实运营恢复时间。900 秒是专项模拟的运行上限，不是已实测的 15 分钟运营 SLA。
Hook permission mask 的命中概率约为每 `2^14` 个候选一次；这是期望值/告警参考，不是确定的最大
搜索次数。真实网络发布仍须以 canonical receipt/state 完成上面的运行手册。
