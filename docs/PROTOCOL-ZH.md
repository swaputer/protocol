# Swaputer：一台由 Swap 驱动的链上计算机

## 一句话介绍

完成后的 Swaputer 是一台由 Uniswap v4 Swap 驱动的链上微型计算机：用户买入真实 TOKEN 时，可以在同一笔交易中部署或调用一个迷你程序，并按程序实际执行的字节数燃烧一部分刚买到的 TOKEN。

它不是在交易池旁边附加几个固定功能，而是在 Hook 后面放置一台可编程、带持久化状态、支持合约组合和通用事件的 MiniVM。

```text
ETH -> TOKEN 买入
        |
        v
Uniswap v4 PoolManager
        |
        v
Swaputer Hook -> 验证买入方向和资金约束
        |
        v
SwapVM Kernel -> 验证签名并执行迷你程序
        |
        +-> 更新迷你程序状态
        +-> 生成一个聚合 Events
        +-> 按实际执行字节计算费用
        |
        v
燃烧部分 TOKEN，剩余 TOKEN 交给收款人
```

## 核心规则：必须是 Swap

Swaputer 的有状态执行只能由指定 ETH/TOKEN 池的买入交易触发。

- ETH -> TOKEN 买入：可以部署或调用迷你程序。
- TOKEN -> ETH 卖出：始终绕过 VM，按照普通 Uniswap v4 Swap 执行。
- 精确输出买入不承载 VM 执行；带 VM 的交易使用精确输入买入。
- 空 `hookData` 会执行规范化的一字节 NOP，不调用用户程序。

这意味着计算需求直接变成 TOKEN 的买入需求，而卖出出口不会被某个迷你程序阻断。用户代码不能安装卖出税、暂停卖出或修改真实 TOKEN 的转账行为。

## 两种完全不同的资产

Swaputer 必须区分真实 TOKEN 和 VM 内的迷你资产。

### 真实 TOKEN

真实 TOKEN 是 ETH/TOKEN Uniswap v4 池中的 ERC-20：

- 用户通过外层 Swap 买到；
- 用于支付 VM 执行费用；
- 执行费用会被真实销毁；
- 可以通过普通 Swap 卖回 ETH；
- 迷你程序不能控制它的余额或转账规则。

### 迷你资产

迷你代币、迷你 NFT 和迷你 AMM 都是运行在 MiniVM 里的程序和状态：

- 余额、所有权、授权和储备存在程序自己的状态空间；
- 铸造、转移、授权和交易由程序代码决定；
- 它们不是 Kernel 内置的特殊资产类型；
- 用户可以部署自己的实现；
- 协议同时提供经过固定代码哈希识别的参考实现。

因此，SRC-20、SRC-721、SRC-1155 不是 Kernel 的硬编码分支，而是普通的可部署迷你程序。新的资产机制、游戏物品、积分、拍卖和 AMM 也可以使用同一套 VM 能力实现。

## 按实际执行字节收费

每个 World 在创建时固定 `byteGasPrice`。用户签名时指定 `byteGasLimit`，用来限制本次执行最多可以消耗多少 VM 字节。

```text
最大 TOKEN 暴露 = byteGasLimit × byteGasPrice
实际燃烧 TOKEN = executedBytes × byteGasPrice
用户最终收到 TOKEN = Swap 毛输出 - 实际燃烧 TOKEN
```

Hook 会在执行前确认 Swap 输出足以覆盖最大费用，并在执行成功后只按照实际执行字节收费。循环中的指令会被重复计数；嵌套调用和构造函数共享同一个计数器，不会在子调用时重置。

这里存在两层资源边界：

1. 以太坊 Gas 保证整笔 EVM 交易不会无限执行，耗尽时整笔回滚；
2. Swaputer 的 `byteGasLimit` 控制用户愿意为 MiniVM 执行燃烧多少 TOKEN。

MiniVM 可以表达通用、图灵完备的计算，但任何单笔链上交易仍然必须在以太坊 Gas 和签名的字节上限内完成。

## 迷你程序能做什么

Swaputer VM 支持持久化存储、控制流、内存、哈希、签名恢复、程序部署以及程序之间的嵌套调用。由这些基础能力可以实现：

- 部署和调用自定义迷你合约；
- 创建 SRC-20 同质化代币；
- 创建 SRC-721 NFT；
- 创建 SRC-1155 多资产；
- 铸造、转移、授权和查询资产；
- 部署恒定乘积迷你 AMM；
- 在迷你代币之间增加流动性和 Swap；
- 构建游戏、积分、拍卖、预测市场和链上实验；
- 由多个迷你程序在一次执行中组合完成复杂操作。

协议提供 SRC-20、SRC-721、SRC-1155 和恒定乘积 AMM 的规范参考程序。参考身份由完整 `ProgramPackageV1` 代码哈希、ABI 哈希和接口 ID 共同确定，仅仅伪造一个函数选择器或事件主题不会被视为可信标准实现。

## 程序部署与账户模型

用户通过买入 Swap 提交签名的 `DEPLOY` 或 `CALL` 操作。

- `DEPLOY` 注册不可变程序包，运行构造函数并产生确定性的迷你合约 ID；
- `CALL` 调用已部署程序并允许修改状态；
- `STATICCALL` 可公开读取状态，但禁止修改；
- 迷你合约可以继续调用或创建其他迷你合约；
- 子调用失败会让整个根执行回滚，不存在半成功状态。

VM 内部使用带类型标签的 32 字节 `AccountId`，区分 EOA 与迷你合约。迷你代币余额、NFT 所有者、授权方和 AMM 储备账户全部使用 `AccountId`，不会把 EVM 的 20 字节地址和迷你合约标识混在一起。

## 一条聚合 SVM 事件

每次成功的 VM 执行只产生一条 Ethereum 事件：

```solidity
event Events(
    bytes32 indexed worldId,
    uint64 indexed executionHeight,
    bytes payload
);
```

SRC 转账、NFT 铸造、迷你 AMM Swap、程序部署和应用自定义事件，都不会各自发出独立的 Ethereum event。它们会按照真实执行顺序被编码成 `payload` 内部的通用 `VMRecord`。

索引器只扫描注册 Kernel 发出的 `Events`，然后：

1. 严格解析版本化的 `VMReceipt`；
2. 按 `eventIndex` 展开内部记录；
3. 根据 `worldId + emitter + immutable codeHash` 确认程序身份；
4. 使用匹配的 ABI 解析 Transfer、Swap 或其他应用事件；
5. 处理区块确认和链重组；
6. 建立代币、NFT、账户和应用级查询视图。

程序可以发出外形类似 `Transfer` 的记录，但索引器不能只相信事件主题。只有 emitter 的不可变代码哈希与受信参考程序匹配时，才应标记为经过验证的 SRC 事件。

## 原子性

Swap、程序执行、状态更新、nonce、执行高度、TOKEN 燃烧和 `Events` 位于同一笔以太坊交易中。

只要任意一步失败，所有结果都会一起回滚，包括：

- Uniswap v4 Swap；
- 迷你程序的存储修改；
- 迷你代币和 NFT 状态；
- 迷你 AMM 储备；
- actor nonce；
- execution height；
- 真实 TOKEN 燃烧；
- 聚合 `Events`。

不会出现“Swap 已成功但程序失败”或“费用已燃烧但状态没有提交”的中间结果。

## v1.1 签名与权限

所有有状态 `CALL` 和 `DEPLOY` 都使用 EIP-712 签名。签名绑定：

- World；
- 明确的 actor；
- 操作类型和目标程序；
- payload 哈希；
- 字节上限；
- ETH 精确输入金额；
- 最小净 TOKEN 输出；
- 价格限制；
- recipient；
- router；
- 可选 executor；
- nonce 和 deadline。

Kernel 要求恢复出的签名者严格等于签名中的显式 `actor`，然后才读取该 actor 的 nonce。recipient、executor 和实际提交交易的 relayer 可以与 actor 不同，但不会因此获得 actor 的 VM 权限。

v1.1 故意不接受 v1.0 签名，避免旧签名被错误归类为另一个新 actor。

## World

一个 World 是一套被冻结的 Swaputer 运行环境，至少绑定：

- ETH/TOKEN Uniswap v4 Pool；
- PoolManager；
- Swaputer Hook；
- SwapVM Kernel；
- 真实 Gas Token；
- `byteGasPrice`；
- VM/Receipt/ISA 版本；
- Hook 与 Kernel 的代码身份。

World 不提供管理员热升级路径。需要改变共识语义、ISA 或安全边界时，应发布新版本并创建新的 World，而不是在用户不知情的情况下替换执行逻辑。

## 完成后的使用体验

### 对普通用户

用户不需要理解 VM 字节码。钱包或应用会展示：

- 本次买入使用多少 ETH；
- 预计获得多少真实 TOKEN；
- 程序预计执行多少字节；
- 最多可能燃烧多少 TOKEN；
- 预计实际燃烧和最终净到账；
- 将要执行的迷你程序和操作。

用户确认后只需签署一次动作并完成一次 Swap。买入、程序执行、迷你资产变化、费用燃烧和事件记录会在同一笔交易中原子完成。

### 对程序开发者

开发者可以使用 TinySol 编写迷你程序，通过编译器生成确定性的 MiniVM 字节码和 `ProgramPackageV1`，并在本地模拟：

- 返回值和状态变化；
- 实际执行路径；
- 执行字节数和 TOKEN 费用；
- 内部调用；
- 将要产生的虚拟事件；
- 失败和回滚原因。

程序部署后代码不可变，身份由代码哈希确定。开发者既可以使用官方参考资产程序，也可以创造完全不同的资产、市场、游戏或协议机制。

### 对钱包和应用

钱包、浏览器和应用通过索引器读取统一 `Events`，查看：

- 某个 World 的全部执行；
- 某个迷你程序的交易和事件；
- SRC-20 余额与转移历史；
- NFT 所有者和授权记录；
- 迷你 AMM 的流动性、储备和 Swap；
- 未知程序的原始事件数据；
- 经过代码哈希验证的标准程序身份。

索引器能够处理链重组，并保留原始 receipt。即使 ABI 或展示方式升级，历史数据仍可以重新解析，而不需要改变链上协议。

Stage 6C 的事件注册表不会因为某条记录长得像 `Transfer` 就赋予它可信身份。每次解析都必须先沿当前区块分支找到同一 `(chainId, Kernel, World, emitter)` 的不可变部署记录，再把其完整 package `codeHash` 与注册表精确匹配。仓库内四个参考包才可标记为 `verified_reference`；用户提交的相同 ABI 始终是 `declared_unverified`。未知、冲突或解码失败的记录继续保留原始 topics/data，且不会影响链上 receipt、扫描游标或其他事件。

索引器以区块哈希和父哈希维护规范链，而不是只相信 RPC 返回的 `removed` 标志。每个区块的 execution、内部 records、部署映射和扫描游标会在一个数据库事务中提交；遇到链重组时，旧分支保留为可诊断的 orphan 原始历史，规范部署映射和查询视图则回退到共同祖先后重新生成。畸形聚合事件、非法 receipt、执行高度断裂和部署哈希冲突会被完整隔离，不会留下半条 execution 或部分 records。

## 最终形态

Swaputer 最终不是“带几个代币功能的 Hook”，也不是另一套独立区块链。它是一层嵌入 Uniswap v4 买入过程的可编程执行环境：

```text
Swap 是启动计算机的开关
真实 TOKEN 是计算燃料
MiniVM 是执行环境
迷你程序是应用
SRC 资产和 AMM 是参考程序
Events 是统一事件总线
索引器是数据层
TinySol 是开发语言和工具链
```

每一次计算都会产生真实的 TOKEN 买入和燃烧；每一种迷你资产与应用都由程序定义；所有状态变化和事件与 Swap 原子结算；任何用户都能部署新程序，但可信身份始终绑定不可变代码哈希。

## 相关文档

- `docs/spec/SwapVM-v1.1-frozen-spec.md`：完整冻结规范；
- `docs/spec/SwapVM-ISA-v1.json`：冻结的 VM 指令集；
- `reference/README.md`：SRC 和 AMM 参考程序说明。
