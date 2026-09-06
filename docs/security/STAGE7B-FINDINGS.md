# Stage 7B findings

本文件记录内部检查；不能称为独立审计。

## S7B-001 — duplicate JSON member ambiguity

- **Severity:** Medium
- **Affected:** deployment-manifest CLI trust boundary
- **Threat:** 同一 JSON object 放入重复字段，标准解析器实现可能采用 first/last/error，导致审阅内容与签名内容理解不一致。
- **Reproduction:** `{"world":1,"\\u0077orld":2}` 在原 CLI 的 `JSON.parse` 中静默采用最后值。
- **Impact:** 不改变链上协议，但可能使发布 manifest 审阅/签名流程产生歧义。
- **Fix:** 新增无依赖 `parseStrictJson`，在 escape 解码后检测重复 key，且拒绝 trailing/malformed JSON；CLI 的 manifest 和 observation 都使用它。
- **Regression:** `manifest.test.ts` duplicate/Unicode/number边界测试。
- **Status:** Fixed。
- **Remaining assumptions:** 调用公共 API 并直接传 object 的调用方已拥有结构化对象；签名前仍必须 `validateManifest`。

## S7B-002 — public salt ordering/griefing

- **Severity:** Medium（可用性）
- **Affected:** permissionless `createWorld` 发布流程
- **Threat:** mempool 中复制完整交易，或先消耗同一 bootstrap/token salt。
- **Impact:** 抢先复制完全相同的参数时，只能提前创建同一个 sealed World，`initialSupply` 仍全部发送到参数声明的 `initialHolder`。抢占 bootstrap/token salt 时，官方发布交易会回滚并损失 gas，发布延迟，旧草案必须作废；抢占者创建的未背书不可变 World 可能永久存在。
- **Disposition:** 接受 salt-recovery 策略，不增加 owner、allowlist 或可变 salt 映射，也不把私有/保护提交渠道设为正确性前提。处置流程见 `DEPLOYMENT-FAILURE-RUNBOOK.md`。
- **Regression:** `test/Stage7MSaltRecovery.t.sol` 独立覆盖 exact-copy、bootstrap collision 与 token collision；断言精确错误选择器/空 CREATE2 revert、失败调用原子性、供应归属、地址与 config 重算、代码/绑定、Pool 初始化和 `WorldSealed` 日志。执行 `./script/accept-s7b002.sh` 生成并严格校验 `security-results/stage7m-s7b002.json`。
- **Evidence boundary:** 当前机器证据是 chain id `31337` 的进程内 Foundry EVM 模拟；没有广播交易、顶层 receipt、公开 mempool 排序或实测运营响应时间，不得将其描述为链上演练或 15 分钟 SLA 证明。
- **Status:** Accepted/Open（Medium availability）；风险已明确接受但 finding 不标记为 Fixed/Closed，本项证据不授权主网发布。
- **Remaining assumptions:** 发布运营方必须监控最终确认、按决策树区分完全复制与两类 salt 碰撞，并在恢复时作废旧草案、重算全部派生地址与 manifest。剩余风险是失败交易 gas、发布延迟、草案作废和未背书 World 长期存在。

## S7B-003 — unfixed default fuzz seed made the gas gate nondeterministic

- **Severity:** Low（测试/发布工程）
- **Affected:** `forge snapshot --check`
- **Threat:** 默认512-run fuzz使用变化的seed，合法执行的mean/median gas会随样本变化，使相同源码偶发gas snapshot diff。
- **Reproduction:** 最终统一gate中Foundry 194/194通过，但Stage 2两个fuzz gas统计与前一次snapshot不同。
- **Impact:** 不影响链上语义或资金；会造成CI假失败，也可能诱使发布者错误接受一次漂移。
- **Fix:** `profile.default.fuzz.seed = "0x7b2026"`；security profile继续使用同一公开固定seed。
- **Regression:** 连续执行`forge snapshot`和`forge snapshot --check`，统一Stage 7B gate必须通过。
- **Status:** Fixed。
- **Remaining assumptions:** 额外随机seed仍应由外部审计/持续安全任务补充，固定release seed不是随机探索的替代品。

## Slither 0.11.4 triage

机器摘要见 `security-results/slither-summary.json`。124 条均分类为 intentional/false positive，
没有被忽略而不写理由：

- `arbitrary-send-erc20`: payer来自 Router public entry生成并由 transient commitment认证的 callback data；Router不能接受外部 callback data，专项测试证明误转 TOKEN 不会替 payer。
- `encode-packed-collision`: 每个拼接只有一个固定 hash/长度的 creation-code payload，后接固定 ABI tuple；不存在两个攻击者可控 dynamic 字段的边界重分配。
- `shadowing-state`: 两个库/合约各自的 secp256k1常量同值、不同作用域。
- `incorrect-equality`: ISA opcode dispatch、上限和标识比较必须精确相等。
- `reentrancy-*`: Kernel self-call由 only-self提交路径约束；Factory绑定真实 Manager且整个创建事务原子；Router有 transient commitment。仍列入外部审计重点。
- `uninitialized-local`: Solidity默认 `false`/empty bytes是明确构造模式和空 topics编码语义。
- `unused-return`: v4 settle/initialize及 tuple未使用项随后由delta、binding和Pool state检查；不是未检查ERC20返回值。
- `missing-zero-check`: Deployer只由已验证Factory创建；Factory对store读取后的精确payload hash失败关闭。
- informational assembly/complexity/low-level-call/dead-code/timestamp均属于冻结VM、精确refund或显式deadline；外部审计仍审阅。

当前未解决 Critical = 0，High = 0；开放 Medium = S7B-002（仅发布可用性，Accepted/Open，需通过
独立 salt-recovery 门禁；不等于 Fixed/Closed，也不授权主网发布）；Low S7B-003已修复。
