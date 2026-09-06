# Stage 7B economic / MEV analysis

这些是确定性本地压力测试，不选择主网参数，也不预测真实 builder 行为。

测试扫描/覆盖的轴包括流动性、ETH input、LP fee、price limit、byteGasPrice/limit、短路径与
高上限暴露。已有 Stage 5/6D3 corpus覆盖 storage/event/深调用的EVM放大；7B以真实v4路径
增加 ordering、sandwich 和 solvency 边界。

| 场景 | 实际参数/结果 | 结论 |
|---|---|---|
| attacker buy → victim buy → attacker sell | victim gross `996989065991182791`、net `996988065991182791`、burn `1e12`、相对isolated price impact `9 ppm`；attacker ETH PnL `-29946012474575323` | 本地固定排序中攻击者因LP/价格影响亏损；victim成功时净输出 ≥ min |
| 同块顺序/价格变化 | attacker输入 `5 ETH`、victim输入 `1 ETH`、LP fee `3000` | 改变gross；签名/普通minimum不满足则整笔回滚 |
| `gross == maximumExposure + minNet` | gross `996997017979937173`，limit `1000`，maximum `1e15`，actual STOP burn `1e12`，net `996996017979937173`，测试路径约 `175273` EVM gas | 成功；实际STOP burn远低于maximum exposure |
| required比gross多1单位 | `minNet = gross - maximumExposure + 1` | 完整revert，nonce/height/supply不变 |
| LP add → victim buy → LP remove | 真实 PoolManager、额外 `1e22` liquidity、同一position salt，victim 90% minimum | add/remove settlement delta归零，不能绕过victim minimum或burn |
| 高执行字节 | Stage 6D3 loops/deep calls/storage/event corpus | TOKEN burn线性，EVM gas非线性；受1,000,000 byte ceiling和区块gas约束 |

机器向量见 `security-results/economic-mev.json`。安全边界是二选一：成功交易满足
`actualBurn <= maximumExposure` 且 `net >= minNet`，否则全部回滚。没有观察到可盈利排序
能够让成功 victim 突破 minNet；这不是“无MEV”声明。不可接受区间包括：流动性低到常态
失败、byteGasPrice使小额交易max exposure吞没gross、接近byte ceiling路径的EVM gas超过
候选链安全预算。最终区间必须在 Stage 7D 对具体链/池重新测量并限额。
