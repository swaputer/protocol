// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {SwaputerKernel} from "../src/SwaputerKernel.sol";
import {SwaputerToken} from "../src/SwaputerToken.sol";
import {SwaputerAppRouter} from "../src/SwaputerAppRouter.sol";
import {SwaputerWorldFactory} from "../src/SwaputerWorldFactory.sol";
import {SwaputerWorldDeployer} from "../src/SwaputerWorldDeployer.sol";
import {SwapVMStage7A2Test} from "./SwapVMStage7A2.t.sol";

contract Stage7BForcedEther {
    constructor(address target) payable {
        selfdestruct(payable(target));
    }
}

contract Stage7BMaliciousRecipient {
    enum Mode {
        None,
        Buy,
        Sell,
        Callback,
        RevertAlways
    }

    SwaputerAppRouter public immutable router;
    bytes32 public immutable worldId;
    Mode public mode;
    bool public swallow;
    bool public attempted;
    bool public nestedSucceeded;

    constructor(SwaputerAppRouter router_, bytes32 worldId_) {
        router = router_;
        worldId = worldId_;
    }

    function arm(Mode mode_, bool swallow_) external {
        mode = mode_;
        swallow = swallow_;
        attempted = false;
        nestedSucceeded = false;
    }

    receive() external payable {
        attempted = true;
        if (mode == Mode.RevertAlways) revert("recipient rejected ETH");
        bool ok;
        if (mode == Mode.Buy) {
            (ok,) = address(router).call{value: 1}(
                abi.encodeCall(router.buyNOPExactInput, (worldId, 0, TickMath.MIN_SQRT_PRICE + 1, address(this)))
            );
        } else if (mode == Mode.Sell) {
            (ok,) = address(router)
                .call(
                    abi.encodeCall(
                        router.sellExactInput, (worldId, uint128(1), 0, TickMath.MAX_SQRT_PRICE - 1, address(this))
                    )
                );
        } else if (mode == Mode.Callback) {
            (ok,) = address(router).call(abi.encodeCall(router.unlockCallback, (bytes("mutated"))));
        } else {
            ok = true;
        }
        nestedSucceeded = ok;
        if (!swallow && !ok) revert("nested route rejected");
    }
}

contract SwapVMStage7BSecurityTest is SwapVMStage7A2Test {
    using TransientStateLibrary for PoolManager;

    function test_stage7B_duplicateSaltsCopiedTransactionAndCrossConfigRollback() public {
        SwaputerWorldFactory.WorldConfig memory first = factory.getWorldConfig(worldId);
        bytes32 configHash = first.configHash;
        SwaputerWorldFactory.CreateWorldParams memory copied = _worldParams(bytes32(uint256(1)), bytes32(uint256(2)));
        address copiedToken = factory.predictGasToken(copied.tokenSalt, copied.initialSupply, copied.initialHolder);

        vm.expectRevert();
        factory.createWorld(copied);
        assertEq(factory.getWorldConfig(worldId).configHash, configHash);
        assertEq(copiedToken, address(token));

        SwaputerWorldFactory.CreateWorldParams memory sameToken = copied;
        sameToken.bootstrapSalt = bytes32(uint256(9002));
        vm.expectRevert();
        factory.createWorld(sameToken);

        SwaputerWorldFactory.CreateWorldParams memory sameBootstrap = copied;
        sameBootstrap.tokenSalt = bytes32(uint256(9001));
        vm.expectRevert();
        factory.createWorld(sameBootstrap);
        assertEq(factory.predictGasToken(bytes32(uint256(9001)), INITIAL_SUPPLY, address(this)).code.length, 0);
        assertEq(factory.getWorldConfig(worldId).configHash, configHash);
    }

    function test_stage7B_wrongPredictionsPermissionBitsAndAllPreSealStateRollback() public {
        bytes32 tokenSalt = bytes32(uint256(3001));
        bytes32 bootstrapSalt = bytes32(uint256(3002));
        SwaputerWorldFactory.CreateWorldParams memory params = _worldParams(tokenSalt, bootstrapSalt);
        address predictedToken = factory.predictGasToken(tokenSalt, INITIAL_SUPPLY, address(this));
        address predictedDeployer = factory.predictWorldDeployer(bootstrapSalt);

        params.predictedKernel = address(uint160(params.predictedKernel) ^ 1);
        vm.expectPartialRevert(SwaputerWorldFactory.KernelPredictionMismatch.selector);
        factory.createWorld(params);
        assertEq(predictedToken.code.length, 0);
        assertEq(predictedDeployer.code.length, 0);

        params = _worldParams(tokenSalt, bootstrapSalt);
        params.hookSalt = bytes32(uint256(1));
        params.predictedHook = factory.predictHook(
            predictedDeployer,
            params.hookSalt,
            params.predictedKernel,
            SwaputerToken(predictedToken),
            params.byteGasPrice,
            params.poolFee,
            params.tickSpacing
        );
        if (
            uint160(params.predictedHook) & Hooks.ALL_HOOK_MASK
                == (Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                        | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG)
        ) params.hookSalt = bytes32(uint256(2));
        params.predictedHook = factory.predictHook(
            predictedDeployer,
            params.hookSalt,
            params.predictedKernel,
            SwaputerToken(predictedToken),
            params.byteGasPrice,
            params.poolFee,
            params.tickSpacing
        );
        vm.expectPartialRevert(SwaputerWorldFactory.InvalidHookPermissionBits.selector);
        factory.createWorld(params);
        assertEq(predictedToken.code.length, 0);
        assertEq(predictedDeployer.code.length, 0);
    }

    function test_stage7B_multipleWorldsRemainSealedAndCrossWorldIsolated() public {
        SwaputerWorldFactory.WorldConfig memory original = factory.getWorldConfig(worldId);
        SwaputerWorldFactory.CreateWorldParams memory params =
            _worldParams(bytes32(uint256(4101)), bytes32(uint256(4102)));
        params.distributionCommitment = keccak256("stage7b-world-two");
        (bytes32 worldTwo,, SwaputerKernel kernelTwo,) = factory.createWorld(params);
        assertTrue(worldTwo != worldId);
        assertEq(factory.getWorldConfig(worldId).configHash, original.configHash);
        assertEq(factory.getWorldConfig(worldTwo).distributionCommitment, params.distributionCommitment);
        assertEq(kernel.executionHeight(worldId), 0);
        assertEq(kernelTwo.executionHeight(worldTwo), 0);

        router.buyNOPExactInput{value: 1 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, address(this));
        assertEq(kernel.executionHeight(worldId), 1);
        assertEq(kernelTwo.executionHeight(worldTwo), 0);
    }

    function test_stage7B_forcedEthAndAccidentalTokenCannotFundAnotherPayer() public {
        address stranger = address(0xB0B);
        vm.deal(stranger, 2 ether);
        uint256 forced = 3 ether;
        new Stage7BForcedEther{value: forced}(address(router));
        token.transfer(address(router), 5 ether);
        uint256 routerTokens = token.balanceOf(address(router));

        vm.prank(stranger);
        router.buyNOPExactInput{value: 1 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, stranger);
        assertEq(address(router).balance, forced);
        assertEq(token.balanceOf(address(router)), routerTokens);

        vm.prank(stranger);
        vm.expectRevert();
        router.sellExactInput(worldId, 1 ether, 0, TickMath.MAX_SQRT_PRICE - 1, stranger);
        assertEq(token.balanceOf(address(router)), routerTokens);
        assertEq(address(router).balance, forced);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_stage7B_recursiveRecipientCannotOverwriteCommitment() public {
        router.buyNOPExactInput{value: 2 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, address(this));
        Stage7BMaliciousRecipient recipient = new Stage7BMaliciousRecipient(router, worldId);
        token.approve(address(router), type(uint256).max);
        uint256 supplyBefore = token.totalSupply();
        uint64 heightBefore = kernel.executionHeight(worldId);

        for (uint256 rawMode = 1; rawMode <= 3; rawMode++) {
            recipient.arm(Stage7BMaliciousRecipient.Mode(rawMode), true);
            router.sellExactInput(worldId, uint128(0.01 ether), 0, TickMath.MAX_SQRT_PRICE - 1, address(recipient));
            assertTrue(recipient.attempted());
            assertFalse(recipient.nestedSucceeded());
            assertEq(kernel.executionHeight(worldId), heightBefore);
            assertEq(token.totalSupply(), supplyBefore);
            assertEq(manager.getNonzeroDeltaCount(), 0);
        }
    }

    function test_stage7B_recipientRevertRollsBackSellAndBalances() public {
        router.buyNOPExactInput{value: 2 ether}(worldId, 1, TickMath.MIN_SQRT_PRICE + 1, address(this));
        Stage7BMaliciousRecipient recipient = new Stage7BMaliciousRecipient(router, worldId);
        recipient.arm(Stage7BMaliciousRecipient.Mode.RevertAlways, false);
        token.approve(address(router), type(uint256).max);
        uint256 balanceBefore = token.balanceOf(address(this));
        uint256 supplyBefore = token.totalSupply();
        uint64 heightBefore = kernel.executionHeight(worldId);
        vm.expectRevert();
        router.sellExactInput(worldId, uint128(0.01 ether), 0, TickMath.MAX_SQRT_PRICE - 1, address(recipient));
        assertEq(token.balanceOf(address(this)), balanceBefore);
        assertEq(token.totalSupply(), supplyBefore);
        assertEq(kernel.executionHeight(worldId), heightBefore);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_stage7B_signatureMutationAndReplayMatrix() public {
        bytes memory packageBytes = _package(0, 0, keccak256("Stage7B.Signature"), hex"00");
        bytes memory payload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes);
        SwaputerKernel.VMEnvelope memory valid = _signedAction(
            SwaputerKernel.RootOp.DEPLOY,
            keccak256(packageBytes),
            payload,
            10,
            0,
            0,
            actor,
            address(0),
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        SwaputerKernel.VMEnvelope memory changed = valid;
        changed.payload[changed.payload.length - 1] = 0x01;
        vm.expectRevert();
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, changed);
        valid.payload[valid.payload.length - 1] = 0x00;
        changed = valid;
        changed.recipient = address(0xCAFE);
        vm.expectRevert();
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, changed);
        vm.chainId(block.chainid + 1);
        vm.expectRevert();
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, valid);
        vm.chainId(block.chainid - 1);

        valid = _signedAction(
            SwaputerKernel.RootOp.DEPLOY,
            keccak256(packageBytes),
            payload,
            10,
            0,
            0,
            actor,
            address(0),
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );

        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, valid);
        vm.expectRevert();
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, valid);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 1);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }

    function test_stage7B_permissionlessRelayCannotChangeFundingRecipientOrBounds() public {
        bytes memory packageBytes = _package(0, 0, keccak256("Stage7B.Relay"), hex"00");
        bytes memory payload = abi.encodePacked(bytes4(uint32(packageBytes.length)), packageBytes);
        SwaputerKernel.VMEnvelope memory action = _signedAction(
            SwaputerKernel.RootOp.DEPLOY,
            keccak256(packageBytes),
            payload,
            10,
            1,
            0,
            actor,
            address(0),
            1 ether,
            TickMath.MIN_SQRT_PRICE + 1,
            address(router)
        );
        address searcher = address(0x515EA);
        vm.deal(searcher, 2 ether);
        uint256 actorBefore = token.balanceOf(actor);
        uint256 searcherEthBefore = searcher.balance;
        vm.prank(searcher);
        router.buyVMExactInput{value: 1 ether}(worldId, TickMath.MIN_SQRT_PRICE + 1, action);
        assertGt(token.balanceOf(actor), actorBefore);
        assertEq(token.balanceOf(searcher), 0);
        assertLt(searcher.balance, searcherEthBefore);
        assertEq(kernel.nonces(worldId, kernel.eoaAccountId(actor)), 1);
        assertEq(manager.getNonzeroDeltaCount(), 0);
    }
}
