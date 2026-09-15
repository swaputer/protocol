# Hook/Kernel 地址循环的可执行证明

直接用 Factory CREATE2 部署两个互相写入 constructor immutable 的合约会形成真循环：

```text
K = CREATE2(F, saltK, keccak256(KernelCreationCode || H || byteGasPrice))
H = CREATE2(F, saltH, keccak256(HookCreationCode || manager || K || token || ...))
```

调整计算顺序不能求解该固定点。`test/SwapVMStage7A1P.t.sol` 保存了单轮预测发散和
Hook constructor 双向绑定失败的最小复现。

生产实现使用 per-world `SwaputerWorldDeployer` 打破循环：Factory 先以固定 init-code
shape 和 `bootstrapSalt` CREATE2 得到 P；Kernel 是 P 的 nonce-1 CREATE 子地址；随后以
P、已知 K、精确 Hook init code 和离线挖出的 `hookSalt` CREATE2 得到 H。P 仅 Factory
可调用且 one-shot，任一步失败都会把 Token、P、K、H、pool initialization 和 config
写入一起回滚。Stage 7B 的 salt/collision、错误预测、permission bits、多 World 及回滚
测试继续锁定这条证明。

详见 `docs/STAGE7A1P.md` 与 `docs/security/WORLD-FACTORY-DESIGN.md`。
