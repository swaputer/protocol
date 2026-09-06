// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwapVMStage6D2Harness} from "./SwapVMStage6D2.t.sol";

contract SwapVMMintableSRC20Harness is SwapVMStage6D2Harness {
    function seedStorage(bytes32 target, bytes32 slot, bytes32 value) external {
        _programStorage[WORLD][target][slot] = value;
    }
}

contract SwapVMMintableSRC20Test is Test {
    uint256 internal constant TOKEN_UNIT = 1e18;
    uint256 internal constant MINT_AMOUNT = 1_000 * TOKEN_UNIT;
    uint256 internal constant SUPPLY_CAP = 10_000_000 * TOKEN_UNIT;
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(bytes32,bytes32,uint256)");
    bytes32 internal constant APPROVAL_TOPIC = keccak256("Approval(bytes32,bytes32,uint256)");

    SwapVMMintableSRC20Harness internal harness;
    bytes32 internal minter = bytes32(uint256(uint160(address(0xA11CE))));
    bytes32 internal otherMinter = bytes32(uint256(uint160(address(0xB0B))));
    bytes32 internal recipient = bytes32(uint256(uint160(address(0xBEEF))));

    function setUp() public {
        harness = new SwapVMMintableSRC20Harness();
    }

    function test_mintableSRC20_anyActorMintsFixedAmountToArbitraryAccount() public {
        bytes32 target = _deploy();

        (bytes memory output, uint32 used, bytes memory records, uint16 count) =
            _executeAs(target, minter, "mint(bytes32)", abi.encode(recipient));
        assertEq(abi.decode(output, (uint256)), MINT_AMOUNT);
        assertEq(used, 278);
        assertEq(count, 1);
        assertEq(_word(records, 4), target);
        assertEq(uint8(records[36]), 3);
        assertEq(_word(records, 37), TRANSFER_TOPIC);
        assertEq(_word(records, 69), bytes32(0));
        assertEq(_word(records, 101), recipient);
        assertEq(uint32(bytes4(_slice(records, 133, 4))), 32);
        assertEq(_word(records, 137), bytes32(MINT_AMOUNT));

        _executeAs(target, otherMinter, "mint(bytes32)", abi.encode(recipient));
        assertEq(_read(target, "totalSupply()", bytes("")), abi.encode(2 * MINT_AMOUNT));
        assertEq(_read(target, "balanceOf(bytes32)", abi.encode(recipient)), abi.encode(2 * MINT_AMOUNT));
    }

    function test_mintableSRC20_transferPreservesSupply() public {
        bytes32 target = _deploy();
        _executeAs(target, otherMinter, "mint(bytes32)", abi.encode(recipient));

        uint256 amount = 250 * TOKEN_UNIT;
        (bytes memory output, uint32 used, bytes memory records, uint16 count) =
            _executeAs(target, recipient, "transfer(bytes32,uint256)", abi.encode(minter, amount));
        assertTrue(abi.decode(output, (bool)));
        assertEq(used, 396);
        assertEq(count, 1);
        assertEq(_word(records, 69), recipient);
        assertEq(_word(records, 101), minter);
        assertEq(_word(records, 137), bytes32(amount));
        assertEq(_read(target, "balanceOf(bytes32)", abi.encode(recipient)), abi.encode(MINT_AMOUNT - amount));
        assertEq(_read(target, "balanceOf(bytes32)", abi.encode(minter)), abi.encode(amount));
        assertEq(_read(target, "totalSupply()", bytes("")), abi.encode(MINT_AMOUNT));
    }

    function test_mintableSRC20_approveTransferFromAndFailedSpendRollback() public {
        bytes32 target = _deploy();
        _executeAs(target, minter, "mint(bytes32)", abi.encode(recipient));

        uint256 approvedAmount = 400 * TOKEN_UNIT;
        (bytes memory output,, bytes memory records, uint16 count) =
            _executeAs(target, recipient, "approve(bytes32,uint256)", abi.encode(otherMinter, approvedAmount));
        assertTrue(abi.decode(output, (bool)));
        assertEq(count, 1);
        assertEq(_word(records, 37), APPROVAL_TOPIC);
        assertEq(_word(records, 69), recipient);
        assertEq(_word(records, 101), otherMinter);
        assertEq(_word(records, 137), bytes32(approvedAmount));
        assertEq(
            _read(target, "allowance(bytes32,bytes32)", abi.encode(recipient, otherMinter)), abi.encode(approvedAmount)
        );

        uint256 amount = 250 * TOKEN_UNIT;
        (output,, records, count) = _executeAs(
            target, otherMinter, "transferFrom(bytes32,bytes32,uint256)", abi.encode(recipient, minter, amount)
        );
        assertTrue(abi.decode(output, (bool)));
        assertEq(count, 1);
        assertEq(_word(records, 37), TRANSFER_TOPIC);
        assertEq(_word(records, 69), recipient);
        assertEq(_word(records, 101), minter);
        assertEq(_word(records, 137), bytes32(amount));
        assertEq(
            _read(target, "allowance(bytes32,bytes32)", abi.encode(recipient, otherMinter)),
            abi.encode(approvedAmount - amount)
        );
        assertEq(_read(target, "balanceOf(bytes32)", abi.encode(recipient)), abi.encode(MINT_AMOUNT - amount));
        assertEq(_read(target, "balanceOf(bytes32)", abi.encode(minter)), abi.encode(amount));

        bytes memory unauthorized = abi.encodePacked(
            bytes4(keccak256("transferFrom(bytes32,bytes32,uint256)")), abi.encode(recipient, minter, uint256(1))
        );
        (bool success,) =
            address(harness).call(abi.encodeCall(SwapVMStage6D2Harness.execute, (target, unauthorized, minter)));
        assertFalse(success);
        assertEq(
            _read(target, "allowance(bytes32,bytes32)", abi.encode(recipient, otherMinter)),
            abi.encode(approvedAmount - amount)
        );
        assertEq(_read(target, "balanceOf(bytes32)", abi.encode(recipient)), abi.encode(MINT_AMOUNT - amount));
        assertEq(_read(target, "balanceOf(bytes32)", abi.encode(minter)), abi.encode(amount));
    }

    function test_mintableSRC20_capAndZeroRecipientFailuresRollback() public {
        bytes32 target = _deploy();
        harness.seedStorage(target, bytes32(0), bytes32(SUPPLY_CAP - MINT_AMOUNT));
        _executeAs(target, minter, "mint(bytes32)", abi.encode(recipient));
        assertEq(_read(target, "totalSupply()", bytes("")), abi.encode(SUPPLY_CAP));
        assertEq(_read(target, "balanceOf(bytes32)", abi.encode(recipient)), abi.encode(MINT_AMOUNT));

        (bool success,) = address(harness)
            .call(
                abi.encodeCall(
                    SwapVMStage6D2Harness.execute,
                    (target, abi.encodePacked(bytes4(keccak256("mint(bytes32)")), abi.encode(recipient)), minter)
                )
            );
        assertFalse(success);
        assertEq(_read(target, "totalSupply()", bytes("")), abi.encode(SUPPLY_CAP));
        assertEq(_read(target, "balanceOf(bytes32)", abi.encode(recipient)), abi.encode(MINT_AMOUNT));

        target = _deploy();
        (success,) = address(harness)
            .call(
                abi.encodeCall(
                    SwapVMStage6D2Harness.execute,
                    (target, abi.encodePacked(bytes4(keccak256("mint(bytes32)")), abi.encode(bytes32(0))), minter)
                )
            );
        assertFalse(success);
        assertEq(_read(target, "totalSupply()", bytes("")), abi.encode(uint256(0)));
    }

    function test_mintableSRC20_metadataAndLimits() public {
        bytes32 target = _deploy();
        assertEq(_read(target, "mintAmount()", bytes("")), abi.encode(MINT_AMOUNT));
        assertEq(_read(target, "cap()", bytes("")), abi.encode(SUPPLY_CAP));
        assertEq(_read(target, "decimals()", bytes("")), abi.encode(uint256(18)));
        assertEq(_read(target, "name()", bytes("")), abi.encode(bytes32("Mintable SRC20")));
        assertEq(_read(target, "symbol()", bytes("")), abi.encode(bytes32("mSRC20")));
    }

    function _deploy() private returns (bytes32 target) {
        (target,,,,) = harness.deploy(
            vm.readFileBinary("tooling/tinysol/programs/mintable-src20/MintableSRC20.svm"), bytes(""), minter
        );
    }

    function _executeAs(bytes32 target, bytes32 actor, string memory signature, bytes memory arguments)
        private
        returns (bytes memory output, uint32 used, bytes memory records, uint16 count)
    {
        return harness.execute(target, abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments), actor);
    }

    function _read(bytes32 target, string memory signature, bytes memory arguments)
        private
        view
        returns (bytes memory output)
    {
        (output,,,) =
            harness.executeStatic(target, abi.encodePacked(bytes4(keccak256(bytes(signature))), arguments), minter);
    }

    function _word(bytes memory data, uint256 offset) private pure returns (bytes32 value) {
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    function _slice(bytes memory data, uint256 offset, uint256 length) private pure returns (bytes memory result) {
        result = new bytes(length);
        for (uint256 i; i < length; ++i) {
            result[i] = data[offset + i];
        }
    }
}
