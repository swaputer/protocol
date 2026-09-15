# Stage 7A2 production Router interface and implementation freeze

This document freezes the minimum Stage 7A2 Router API, implemented by `src/SwaputerAppRouter.sol`. It reuses `SwaputerKernel.VMEnvelope` directly and does not create a second representation of `VMAction`.

## 1. Public ABI

```solidity
interface ISwaputerAppRouter is IUnlockCallback {
    function buyNOPExactInput(
        bytes32 worldId,
        uint128 minTokenOut,
        uint160 sqrtPriceLimitX96,
        address recipient
    ) external payable returns (BalanceDelta delta);

    function buyVMExactInput(
        bytes32 worldId,
        uint160 sqrtPriceLimitX96,
        SwaputerKernel.VMEnvelope calldata envelope
    ) external payable returns (BalanceDelta delta);

    function sellExactInput(
        bytes32 worldId,
        uint128 exactTokenAmountIn,
        uint128 minEthAmountOut,
        uint160 sqrtPriceLimitX96,
        address recipient
    ) external returns (BalanceDelta delta);

    function unlockCallback(bytes calldata callbackData)
        external
        returns (bytes memory);
}
```

There is no exact-output buy ABI and no generic `swap`, arbitrary PoolKey, arbitrary hookData, or arbitrary callback entry.

## 2. No duplicate signed action

`VMEnvelope` contains the variable-length payload and signature plus the fields represented directly in the frozen v1.1 EIP-712 action. The remaining signed values are obtained from actual execution:

| Frozen VMAction field | Canonical source |
|---|---|
| `op`, `worldId`, `actor`, `targetOrCodeHash`, `payloadHash`, `byteGasLimit`, `minNetTokenOut`, `authorizedExecutor`, `nonce`, `deadline` | `envelope`, with `payloadHash = keccak256(envelope.payload)` inside Kernel |
| `exactEthAmountIn` | `msg.value`, actual negative exact-input `SwapParams.amountSpecified`, and Hook receipt |
| `sqrtPriceLimitX96` | `buyVMExactInput` argument and actual `SwapParams.sqrtPriceLimitX96` |
| `recipient` | `envelope.recipient` |
| `router` | `address(this)`, observed by Hook as callback `sender` |

The Router must not accept separate `payload`, `payloadHash`, `hookData`, `byteGasLimit`, `nonce`, `deadline`, `recipient`, or executor arguments for a VM buy. It canonicalizes hookData exactly once as `abi.encode(envelope)`.

## 3. Entry-point behavior

### `buyNOPExactInput`

- requires a Factory-recorded sealed `worldId` and its exact PoolKey;
- requires `msg.value > 0` and a nonzero recipient;
- submits an exact-input ETH→TOKEN swap (`zeroForOne = true`, negative `amountSpecified`);
- passes empty hookData, which is the only valid unsigned NOP representation;
- verifies the recipient's net TOKEN output is at least `minTokenOut` after the Hook delta/burn;
- cannot accept or manufacture a signed NOP envelope.

### `buyVMExactInput`

- requires a sealed World and `msg.value > 0`;
- requires `envelope.worldId == worldId`;
- requires `envelope.op` to be CALL or DEPLOY, never NOP;
- requires nonzero `envelope.actor` and `envelope.recipient`; consensus signature/nonce/deadline checks remain in Kernel;
- requires `envelope.authorizedExecutor == address(0)` for permissionless relay, or equality with external `msg.sender`;
- submits only exact-input ETH→TOKEN with actual input bounded by this call's `msg.value`;
- passes `abi.encode(envelope)` as the sole hookData;
- relies on Kernel's frozen typed-data digest to bind `msg.value`/actual input, price limit, recipient, this Router address, payload hash and envelope fields;
- uses the immutable Hook's `byteGasPrice()` for any preview or exposure display. The user cannot supply a price.

Because Kernel hashes the Hook-observed callback sender, `VMAction.router` is necessarily this Router address. Because the Router forwards the unchanged envelope and sends output only to `envelope.recipient`, the actual recipient equals the signed recipient.

### `sellExactInput`

- requires a sealed World, nonzero input and recipient;
- submits TOKEN→ETH exact input (`zeroForOne = false`, negative `amountSpecified`);
- always passes empty hookData;
- pulls at most `exactTokenAmountIn` from the current payer for this call and creates no long-lived allowance;
- sends actual ETH output directly to `recipient` and enforces `minEthAmountOut`;
- cannot carry a VM payload and cannot execute or burn VM bytes.

Exact-output TOKEN→ETH may remain available through noncanonical integrations under frozen Hook semantics, but is intentionally outside this minimum canonical Router ABI. Exact-output ETH→TOKEN is rejected by the Hook and must also be rejected by the Router's internal route validation.

## 4. Internal callback data

Callback data is generated internally by the public entry points; callers never supply it as a parallel action representation.

```solidity
enum RouteKind { BuyNOPExactInput, BuyVMExactInput, SellExactInput }

struct UnlockData {
    RouteKind kind;
    bytes32 worldId;
    address payer;
    address recipient;
    uint128 exactAmount;
    uint128 minimumAmountOut;
    uint160 sqrtPriceLimitX96;
    bytes hookData; // empty except abi.encode(envelope) for BuyVMExactInput
}
```

The implementation may use a more gas-efficient equivalent, but it must have one canonical encoding and preserve these bindings. The Router records an active callback commitment for the current invocation (preferably transient under the v4 execution environment). `unlockCallback` requires:

- `msg.sender == immutable poolManager`;
- an active Router-initiated unlock;
- callback data hash equal to the active commitment;
- Factory lookup of the exact sealed PoolKey for `worldId`;
- route direction and negative exact-input amount matching `kind`;
- VM hookData empty/nonempty exactly as specified above.

Nested or replayed callbacks fail. Any callback failure reverts the complete PoolManager unlock.

## 5. Settlement and refund invariants

- Native input debt is settled only from this call's `msg.value` budget.
- If a price limit leaves exact-input ETH unused, only `msg.value - actualEthSettled` is refunded, and only to this call's payer.
- Refund logic must never transfer the Router's whole balance; ETH forced into the Router before the call is excluded from the refundable budget.
- TOKEN input for a sell is collected from this call's payer only for the actual settlement amount, without permanent Router allowance or custody.
- TOKEN/ETH output is taken directly to the selected recipient where v4 settlement permits.
- On success, the accounting attributable to the current call is zero and all PoolManager transient deltas are zero.
- Router has no owner, administrator, proxy, pause, governance, arbitrary call, arbitrary token approval, sweep or withdrawal method.

## 6. Required custom errors

```solidity
error OnlyPoolManager(address caller);
error CallbackNotActive();
error CallbackDataMismatch();
error ReentrantUnlock();
error WorldNotSealed(bytes32 worldId);
error WorldPoolKeyMismatch(bytes32 worldId);
error InvalidRecipient(address recipient);
error InvalidExactInput(uint256 amount);
error EnvelopeWorldMismatch(bytes32 expected, bytes32 supplied);
error SignedNOPForbidden();
error InvalidVMOperation(SwaputerKernel.RootOp op);
error UnauthorizedExecutor(address expected, address actual);
error ExactOutputBuyUnsupported();
error SellInstructionsForbidden();
error MinimumOutputNotMet(uint256 actual, uint256 minimum);
error SettlementNotCleared();
error RefundAccountingMismatch();
```

Implementations may add narrowly scoped arithmetic or token-transfer errors, but must not weaken or duplicate the input model above.

## 7. Frozen semantics preserved

The Router does not change `VMEnvelope`, `VM_ACTION_TYPEHASH`, signed fields, Hook encoding, Kernel authentication, burn calculation or sell bypass. `byteGasPrice` is read from the World's bound immutable Hook (and cross-checked with Kernel/Factory configuration), never accepted from the user. This interface is ready for Stage 7A2 implementation after the per-world deployer is promoted from test proof to separately reviewed production code.
